@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os
@preconcurrency import Speech

/// Thin wrapper around iOS 26 `SpeechAnalyzer` + `SpeechTranscriber` that emits
/// a flat stream of (word, end-time, isFinalized) events for the brain.
///
/// Volatile (partial) results are re-emitted as they revise; the brain only
/// updates the rate tracker and aligner from `isFinalized == true` words so
/// late revisions don't poison the cursor.
@MainActor
final class LiveTranscriber {
    struct WordEvent {
        let text: String
        let endTime: TimeInterval
        let isFinalized: Bool
    }

    enum LiveTranscriberError: LocalizedError {
        case unsupportedLocale(String, available: [String])
        case assetUnavailable(underlying: Error?)
        case formatUnavailable

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale(let req, let avail):
                let shown = avail.prefix(6).joined(separator: ", ")
                let more = avail.count > 6 ? "\u{2026} (+\(avail.count - 6) more)" : ""
                return "Locale '\(req)' not supported by SpeechTranscriber. Available: \(shown)\(more)"
            case .assetUnavailable(let e):
                return "Speech model unavailable: \(e?.localizedDescription ?? "unknown")"
            case .formatUnavailable:
                return "No compatible audio format for SpeechAnalyzer on this device."
            }
        }
    }

    private let locale: Locale
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    private var inputStream: AsyncStream<AnalyzerInput>?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?

    private var resultsTask: Task<Void, Never>?

    /// Total length (in characters) of the most recent finalized transcript.
    /// Used to detect newly finalized tokens between emissions.
    private var lastFinalizedCharCount: Int = 0
    private var lastFinalizedWordCount: Int = 0
    private var bufferIngestCount: Int = 0
    private var resultCount: Int = 0

    private let log = Logger(subsystem: "cloud.lcoppers.prospeech", category: "LiveTranscriber")

    var onEvent: ((WordEvent) -> Void)?

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    func prepare() async throws {
        log.info("prepare() start, requested locale=\(self.locale.identifier, privacy: .public)")

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        let supported = await SpeechTranscriber.supportedLocales
        log.info("supportedLocales count=\(supported.count, privacy: .public): \(supported.map { $0.identifier(.bcp47) }.joined(separator: ","), privacy: .public)")

        // Install the on-device model. If the locale is genuinely unsupported,
        // assetInstallationRequest will throw — that's our authoritative check.
        // No more string-comparison guess.
        do {
            if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                log.info("downloading speech model…")
                try await downloader.downloadAndInstall()
                log.info("speech model installed")
            } else {
                log.info("speech model already installed")
            }
        } catch {
            log.error("asset install failed: \(error.localizedDescription, privacy: .public)")
            throw LiveTranscriberError.assetUnavailable(underlying: error)
        }

        try await AssetInventory.reserve(locale: locale)
        log.info("locale reserved")

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            log.error("no compatible audio format")
            throw LiveTranscriberError.formatUnavailable
        }
        self.analyzerFormat = format
        log.info("analyzer format: \(String(describing: format), privacy: .public)")

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputStream = stream
        self.inputContinuation = continuation
    }

    func start() async throws {
        guard let analyzer, let inputStream, let transcriber else { return }
        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    await self.handleResult(result)
                }
            } catch {
                // Stream ended; nothing more to do.
            }
        }
        try await analyzer.start(inputSequence: inputStream)
    }

    func finish() async {
        inputContinuation?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
        await AssetInventory.release(reservedLocale: locale)
    }

    /// Push one mic buffer in. Called from the audio engine tap.
    nonisolated func ingest(buffer: AVAudioPCMBuffer) {
        Task { @MainActor in
            await self.ingestOnMain(buffer)
        }
    }

    @MainActor
    private func ingestOnMain(_ buffer: AVAudioPCMBuffer) async {
        guard let target = analyzerFormat else { return }
        let converted: AVAudioPCMBuffer
        if buffer.format == target {
            converted = buffer
        } else {
            if converter == nil || converter?.outputFormat != target {
                converter = AVAudioConverter(from: buffer.format, to: target)
                converter?.primeMethod = .none
            }
            guard let converter else { return }
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var error: NSError?
            let state = ConverterInputState(buffer: buffer)
            converter.convert(to: out, error: &error) { _, status in
                if state.supplied { status.pointee = .endOfStream; return nil }
                state.supplied = true
                status.pointee = .haveData
                return state.buffer
            }
            if error != nil { return }
            converted = out
        }
        inputContinuation?.yield(AnalyzerInput(buffer: converted))
        bufferIngestCount &+= 1
        if bufferIngestCount == 1 {
            log.info("first buffer yielded to analyzer")
        } else if bufferIngestCount % 60 == 0 {
            log.info("\(self.bufferIngestCount, privacy: .public) buffers yielded to analyzer")
        }
    }

    // MARK: - Result handling

    private func handleResult(_ result: SpeechTranscriber.Result) async {
        let attributed = result.text
        let plain = String(attributed.characters)
        // Tokenize on whitespace. Punctuation is stripped by Aligner.normalize
        // downstream, so leaving it here is harmless.
        let allWords = plain
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        if result.isFinal {
            // Emit only the suffix that's new vs. previous final.
            let newWords = Array(allWords.dropFirst(lastFinalizedWordCount))
            let baseTime = approximateEndTime(of: result) ?? CFAbsoluteTimeGetCurrent()
            let step = newWords.isEmpty ? 0 : 1.0 / Double(max(1, newWords.count))
            for (i, w) in newWords.enumerated() {
                let t = baseTime + Double(i) * step * 0.3  // small spread if no per-word time
                let timed = perWordTime(attributed: attributed, wordIndex: lastFinalizedWordCount + i) ?? t
                onEvent?(.init(text: w, endTime: timed, isFinalized: true))
            }
            lastFinalizedCharCount = plain.count
            lastFinalizedWordCount = allWords.count
        } else {
            // Volatile preview — useful for UI shadow, but don't feed the brain.
            // We emit ONE non-final event with the entire tail so the UI can show it.
            let tail = allWords.dropFirst(lastFinalizedWordCount).joined(separator: " ")
            if !tail.isEmpty {
                onEvent?(.init(text: tail, endTime: CFAbsoluteTimeGetCurrent(), isFinalized: false))
            }
        }
    }

    /// Look up the per-word `audioTimeRange` attribute on the `AttributedString`.
    /// Defensive: if the attribute scope key doesn't compile in your SDK, this
    /// returns nil and we fall back to a coarse synthetic timestamp.
    private func perWordTime(attributed: AttributedString, wordIndex: Int) -> TimeInterval? {
        var idx = 0
        for run in attributed.runs {
            let slice = attributed[run.range]
            let runText = String(slice.characters)
            let runWords = runText.split(whereSeparator: { $0.isWhitespace }).count
            if runWords == 0 { continue }
            if wordIndex >= idx && wordIndex < idx + runWords {
                if let range = audioTimeRange(of: run) {
                    let end = range.start.seconds + range.duration.seconds
                    return end
                }
                return nil
            }
            idx += runWords
        }
        return nil
    }

    private func approximateEndTime(of result: SpeechTranscriber.Result) -> TimeInterval? {
        // Last run's audio range, if available.
        let runs = result.text.runs
        guard let last = runs.reversed().first else { return nil }
        guard let r = audioTimeRange(of: last) else { return nil }
        return r.start.seconds + r.duration.seconds
    }

    /// Extract a CMTimeRange from a run via the SpeechTranscriber attribute scope.
    /// Falls back to nil if the attribute is absent.
    private func audioTimeRange(of run: AttributedString.Runs.Run) -> CMTimeRange? {
        // The SpeechTranscriber attribute scope exposes audioTimeRange via dynamic
        // member lookup on Runs.Run. If your SDK exposes it differently, change
        // the line below to the documented form.
        return run.audioTimeRange
    }
}

/// Holder for the AVAudioConverter input-block's per-call state.
///
/// AVAudioConverter's input block is typed `@Sendable`, but it's actually invoked
/// synchronously from inside `convert(...)` before that function returns — so
/// mutable state captured by the block is safe in practice but unprovable to
/// Swift 6 strict concurrency. Wrapping the state in an `@unchecked Sendable`
/// class is the standard workaround.
private final class ConverterInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var supplied: Bool = false
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}
