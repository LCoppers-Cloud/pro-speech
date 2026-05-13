@preconcurrency import AVFoundation
import Foundation
import os

/// User-selectable audio output preference.
enum AudioRoute: String, CaseIterable, Identifiable, Sendable {
    case auto       // System chooses; falls back to speaker if no Bluetooth.
    case speaker    // Force iPhone speaker even if AirPods are connected.
    case bluetooth  // Prefer connected Bluetooth audio (AirPods etc.).

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .speaker: return "iPhone Speaker"
        case .bluetooth: return "Bluetooth / AirPods"
        }
    }
}

/// Owns the `AVAudioEngine`, the audio session, and the input-buffer tap.
///
/// NOT @MainActor: the buffer-tap callback fires on a render thread, so any
/// state the callback touches must be accessible without main-actor isolation.
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

    nonisolated(unsafe) private(set) var isRunning = false
    nonisolated(unsafe) var isMuted: Bool = false
    nonisolated(unsafe) var onBuffer: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    nonisolated(unsafe) private var bufferCount: Int = 0

    private let log = Logger(subsystem: "cloud.lcoppers.prospeech", category: "AudioEngine")

    func configureSession(route: AudioRoute = .auto) async throws {
        let session = AVAudioSession.sharedInstance()

        switch AVAudioApplication.shared.recordPermission {
        case .denied:
            log.error("microphone permission denied")
            throw AudioEngineError.microphonePermissionDenied
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted { throw AudioEngineError.microphonePermissionDenied }
        case .granted:
            break
        @unknown default:
            break
        }

        // Build category options based on user preference. We use .measurement
        // mode so SpeechAnalyzer gets clean unprocessed audio. .allowBluetoothA2DP
        // is enough for OUTPUT routing to AirPods (no mic-on-AirPod here since
        // voice processing isn't enabled).
        var options: AVAudioSession.CategoryOptions = [.duckOthers]
        switch route {
        case .auto:
            options.insert(.defaultToSpeaker)
            options.insert(.allowBluetoothA2DP)
        case .speaker:
            options.insert(.defaultToSpeaker)
        case .bluetooth:
            options.insert(.allowBluetoothA2DP)
        }

        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: options)
            try session.setActive(true, options: [.notifyOthersOnDeactivation])
            log.info("audio session active route=\(route.rawValue, privacy: .public) sr=\(session.sampleRate, privacy: .public) ch=\(session.inputNumberOfChannels, privacy: .public) outputs=\(String(describing: session.currentRoute.outputs.map { $0.portName }), privacy: .public)")
        } catch {
            log.error("session config failed: \(error.localizedDescription, privacy: .public)")
            throw AudioEngineError.sessionConfig(error)
        }
    }

    func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        log.info("installTap format: \(String(describing: format), privacy: .public)")
        input.removeTap(onBus: 0)
        bufferCount = 0
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            guard let self else { return }
            self.bufferCount &+= 1
            if self.bufferCount == 1 {
                self.log.info("first mic buffer received (frames=\(buffer.frameLength, privacy: .public))")
            } else if self.bufferCount % 60 == 0 {
                self.log.info("\(self.bufferCount, privacy: .public) mic buffers delivered")
            }
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
        log.info("stop() called; total buffers delivered=\(self.bufferCount, privacy: .public)")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        log.info("engine stopped")
    }
}
