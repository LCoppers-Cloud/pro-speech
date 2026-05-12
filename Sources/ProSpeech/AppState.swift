import Foundation
import ProSpeechBrain
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case countdown(secondsLeft: Int)
        case running
        case paused(reason: String)
        case finished
    }

    // MARK: - Published UI state

    @Published var phase: Phase = .idle
    @Published var notes: String = ""
    @Published var persona: Persona = .natural
    @Published var apiKey: String = "" {
        didSet { if oldValue != apiKey { KeychainStore.set(apiKey, key: "anthropic_api_key") } }
    }
    @Published var liveTranscript: String = ""
    @Published var volatileTail: String = ""
    @Published var bufferWords: [String] = []
    @Published var highlightIndex: Int = 0
    @Published var liveWPM: Double = 140
    @Published var statusMessage: String = ""

    // MARK: - Engine

    private let audio = AudioEngine()
    private let transcriber = LiveTranscriber()
    private let tts = TTSPlayer()
    private let rateTracker = RateTracker()
    private let aligner = Aligner()
    private let bufferPolicy = BufferPolicy()
    private let promptBuffer = PromptBuffer()
    private let silence = SilenceDetector()
    private var profile = SpeakerProfile.defaultProfile
    private var stream: ClaudeStream?

    private var requestInFlight = false
    private var keepaliveTask: Task<Void, Never>?
    private var silenceTimer: Task<Void, Never>?
    private var ttsQueueCursor: Int = 0

    init() {
        apiKey = KeychainStore.get("anthropic_api_key") ?? ""
        loadProfile()
        wireCallbacks()
    }

    // MARK: - Lifecycle

    func beginCountdown() {
        guard !apiKey.isEmpty else {
            statusMessage = "Set your Anthropic API key in Settings first."
            return
        }
        Task {
            phase = .preparing
            do {
                try audio.configureSession()
                try await transcriber.prepare()
                phase = .countdown(secondsLeft: 3)
                for n in stride(from: 3, through: 1, by: -1) {
                    phase = .countdown(secondsLeft: n)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                try await startSession()
            } catch {
                statusMessage = "Could not start: \(error.localizedDescription)"
                phase = .idle
            }
        }
    }

    func stop() {
        Task { await stopSession() }
    }

    private func startSession() async throws {
        promptBuffer.reset()
        aligner.setBuffer([])
        bufferWords = []
        highlightIndex = 0
        liveTranscript = ""
        volatileTail = ""
        ttsQueueCursor = 0

        stream = ClaudeStream(config: .init(apiKey: apiKey))

        try await transcriber.start()
        try audio.start()
        startKeepalive()
        startSilenceTimer()
        // Seed an initial chunk so the buffer is not empty when the speaker starts.
        Task { await requestMoreWords(initial: true) }
        phase = .running
    }

    private func stopSession() async {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        silenceTimer?.cancel()
        silenceTimer = nil
        audio.stop()
        await transcriber.finish()
        tts.cancelAll()
        finalizeProfileFromSession()
        phase = .finished
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        audio.onBuffer = { [weak self] buffer, _ in
            self?.transcriber.ingest(buffer: buffer)
        }

        transcriber.onEvent = { [weak self] event in
            guard let self else { return }
            if event.isFinalized {
                self.handleFinalizedWord(event.text, endTime: event.endTime)
            } else {
                self.volatileTail = event.text
            }
        }

        tts.onStart = { [weak self] in self?.audio.isMuted = true }
        tts.onFinish = { [weak self] in
            // Brief tail to let the AEC settle.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                self?.audio.isMuted = false
            }
        }

        silence.onSilenceBegan = { [weak self] in
            self?.statusMessage = "Listening…"
        }
        silence.onSilenceEnded = { [weak self] in
            self?.statusMessage = ""
        }
    }

    // MARK: - Brain loop

    private func handleFinalizedWord(_ word: String, endTime: TimeInterval) {
        liveTranscript += (liveTranscript.isEmpty ? "" : " ") + word
        rateTracker.observe(word: word, endTime: endTime)
        silence.noteWord(at: endTime)

        let result = aligner.observe(spoken: word)
        switch result {
        case .advance(let i):
            promptBuffer.advance(to: i)
            highlightIndex = promptBuffer.highlightIndex
        case .offScript:
            // Discard buffer and regenerate based on the new direction.
            promptBuffer.reset()
            aligner.setBuffer([])
            bufferWords = []
            highlightIndex = 0
            ttsQueueCursor = 0
            tts.cancelAll()
            aligner.resetMisses()
            Task { await requestMoreWords(initial: false) }
            return
        case .noChange:
            break
        }

        let est = rateTracker.estimate
        liveWPM = est.wordsPerMinute
        tts.userWPM = est.wordsPerMinute

        if bufferPolicy.shouldRequestMore(
            wordsRemaining: promptBuffer.remainingWords,
            wpm: est.wordsPerMinute,
            requestInFlight: requestInFlight
        ) {
            Task { await requestMoreWords(initial: false) }
        }
    }

    // MARK: - Claude streaming

    private func requestMoreWords(initial: Bool) async {
        guard !requestInFlight, let stream else { return }
        requestInFlight = true
        defer { requestInFlight = false }

        let system = SystemPromptBuilder.build(persona: persona, notes: notes)
        let recent = String(liveTranscript.suffix(800))
        let buffered = promptBuffer.unspoken.joined(separator: " ")
        let chunk = bufferPolicy.chunkSize(wpm: liveWPM)

        var accumulated = ""
        do {
            for try await fragment in stream.stream(
                systemPrompt: system,
                recentTranscript: recent,
                alreadyBuffered: buffered,
                chunkWords: chunk
            ) {
                accumulated += fragment
                let (committed, remainder) = AppState.splitOnLastWhitespace(accumulated)
                if !committed.isEmpty {
                    let newTokens = committed
                        .split(whereSeparator: { $0.isWhitespace })
                        .map(String.init)
                    appendNewTokens(newTokens)
                    accumulated = remainder
                }
            }
            if !accumulated.isEmpty {
                let final = accumulated.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                appendNewTokens(final)
            }
        } catch {
            statusMessage = "Claude error: \(error.localizedDescription)"
        }
    }

    private func appendNewTokens(_ tokens: [String]) {
        guard !tokens.isEmpty else { return }
        promptBuffer.append(contentsOf: tokens)
        aligner.appendToBuffer(tokens)
        bufferWords = promptBuffer.words
        let toSpeak = Array(promptBuffer.newWords(since: ttsQueueCursor))
        ttsQueueCursor = promptBuffer.words.count
        tts.enqueue(words: toSpeak)
    }

    private static func splitOnLastWhitespace(_ s: String) -> (committed: String, remainder: String) {
        guard let lastSpace = s.lastIndex(where: { $0.isWhitespace }) else {
            return ("", s)
        }
        let committed = String(s[..<lastSpace])
        let remainder = String(s[s.index(after: lastSpace)...])
        return (committed, remainder)
    }

    // MARK: - Keepalive

    private func startKeepalive() {
        keepaliveTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                guard let stream = self.stream else { return }
                let system = SystemPromptBuilder.build(persona: self.persona, notes: self.notes)
                try? await stream.keepCacheAlive(systemPrompt: system)
            }
        }
    }

    private func startSilenceTimer() {
        silenceTimer = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                self.silence.tick(now: CFAbsoluteTimeGetCurrent())
            }
        }
    }

    // MARK: - Profile

    private func loadProfile() {
        if let data = UserDefaults.standard.data(forKey: "speakerProfile"),
           let decoded = try? JSONDecoder().decode(SpeakerProfile.self, from: data) {
            profile = decoded
            // Warm-start with persisted mean so the first chunk is sized right.
            liveWPM = profile.meanWPM
        }
    }

    private func finalizeProfileFromSession() {
        let est = rateTracker.slowEstimate
        guard est.wordsPerMinute > 60 else { return }  // didn't actually run long enough
        profile.record(
            sessionMeanWPM: est.wordsPerMinute,
            sessionSigmaWPM: max(15, abs(est.wordsPerMinute - profile.meanWPM)),
            sessionSyllablesPerWord: est.meanSyllablesPerWord
        )
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: "speakerProfile")
        }
    }
}
