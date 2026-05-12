import AVFoundation
import Foundation

/// Owns the `AVAudioEngine`, the audio session, and the input-buffer tap.
///
/// Session config: `.playAndRecord` + `.voiceChat` engages the voice-processing
/// I/O unit, which gives us system-level AEC — critical so the TTS prompt
/// playing into the AirPods does not get picked up by the AirPods mic and
/// fed back to the transcriber.
@MainActor
final class AudioEngine {
    enum AudioEngineError: Error {
        case sessionConfig(Error)
        case engineStart(Error)
    }

    let engine = AVAudioEngine()
    private(set) var isRunning = false

    /// Set to true while TTS is speaking. The transcriber should discard buffers
    /// during this window (AEC is good but not perfect against synthetic voice).
    var isMuted: Bool = false

    /// Closure invoked on the audio thread for each input buffer. Keep it cheap.
    var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?

    func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers]
            )
            try session.setActive(true, options: [.notifyOthersOnDeactivation])
        } catch {
            throw AudioEngineError.sessionConfig(error)
        }

        // Voice-processing AEC on the input node (iOS 13+).
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
        } catch {
            // Not fatal — AEC will be degraded, but the app still works.
        }
    }

    func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            guard let self else { return }
            if self.isMuted { return }
            self.onBuffer?(buffer, time)
        }
        engine.prepare()
        do {
            try engine.start()
            isRunning = true
        } catch {
            throw AudioEngineError.engineStart(error)
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
