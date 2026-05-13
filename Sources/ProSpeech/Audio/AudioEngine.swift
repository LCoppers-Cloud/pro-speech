@preconcurrency import AVFoundation
import Foundation
import os

/// Owns the `AVAudioEngine`, the audio session, and the input-buffer tap.
///
/// NOT @MainActor: the buffer-tap callback fires on a render thread, so any
/// state the callback touches has to be accessible without main-actor
/// isolation. The properties read from the render thread are marked
/// `nonisolated(unsafe)` — they're Bool / closure references and Swift's
/// memory model is enough to make those reads safe in practice.
///
/// Session config: `.playAndRecord` + `.voiceChat` engages the voice-processing
/// I/O unit, which gives us system-level AEC — critical so the TTS prompt
/// playing into the AirPods does not get picked up by the AirPods mic and
/// fed back to the transcriber.
final class AudioEngine: @unchecked Sendable {
    enum AudioEngineError: Error, LocalizedError {
        case sessionConfig(Error)
        case engineStart(Error)
        case microphonePermissionDenied

        var errorDescription: String? {
            switch self {
            case .sessionConfig(let e):
                return "AVAudioSession config failed: \(e.localizedDescription)"
            case .engineStart(let e):
                return "AVAudioEngine.start failed: \(e.localizedDescription)"
            case .microphonePermissionDenied:
                return "Microphone permission denied. Enable it in Settings → ProSpeech → Microphone."
            }
        }
    }

    let engine = AVAudioEngine()

    /// Read from the render thread; written from anywhere.
    nonisolated(unsafe) private(set) var isRunning = false
    nonisolated(unsafe) var isMuted: Bool = false
    nonisolated(unsafe) var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    private let log = Logger(subsystem: "cloud.lcoppers.prospeech", category: "AudioEngine")

    func configureSession() async throws {
        let session = AVAudioSession.sharedInstance()

        // Microphone permission probe (iOS 17+ API).
        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            log.error("microphone permission denied")
            throw AudioEngineError.microphonePermissionDenied
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted {
                throw AudioEngineError.microphonePermissionDenied
            }
        case .granted:
            break
        @unknown default:
            break
        }

        do {
            // .measurement mode is Apple's recommendation for speech recognition:
            // no signal processing, no AGC, no voice-processing AU. We were
            // using .voiceChat + setVoiceProcessingEnabled to get AEC (so TTS
            // doesn't bleed back into the mic), but vpio AU was throwing
            // render err -1 on iOS 26. AEC will be re-introduced as a follow-up
            // once we confirm the basic loop works.
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .duckOthers]
            )
            try session.setActive(true, options: [.notifyOthersOnDeactivation])
            log.info("audio session active: sr=\(session.sampleRate, privacy: .public) ch=\(session.inputNumberOfChannels, privacy: .public)")
        } catch {
            log.error("session config failed: \(error.localizedDescription, privacy: .public)")
            throw AudioEngineError.sessionConfig(error)
        }

        // Voice processing intentionally NOT enabled — see comment above.
    }

    func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        log.info("installTap format: \(String(describing: format), privacy: .public)")
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            // Render-thread context — no actor hops, no allocations beyond what's needed.
            guard let self else { return }
            if self.isMuted { return }
            self.onBuffer?(buffer, time)
        }
        engine.prepare()
        do {
            try engine.start()
            isRunning = true
            log.info("engine started")
        } catch {
            log.error("engine start failed: \(error.localizedDescription, privacy: .public)")
            throw AudioEngineError.engineStart(error)
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        log.info("engine stopped")
    }
}
