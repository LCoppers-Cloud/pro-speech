import AVFoundation
import Foundation

/// Wraps `AVSpeechSynthesizer` with a serial queue of word chunks and a
/// WPM-based rate. Notifies the coordinator when speech starts/ends so the
/// transcriber can be gated during playback.
@MainActor
final class TTSPlayer: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var voice: AVSpeechSynthesisVoice?
    private var pendingTexts: [String] = []
    private var currentText: String?

    var onStart: (() -> Void)?
    var onFinish: (() -> Void)?

    /// User's live WPM. TTS speaks slightly faster so the prompt lands ahead.
    var userWPM: Double = 140

    override init() {
        super.init()
        synthesizer.delegate = self
        // Prefer a Premium / Enhanced voice if available; system picks otherwise.
        voice = AVSpeechSynthesisVoice(language: "en-US")
    }

    func setVoice(language: String) {
        voice = AVSpeechSynthesisVoice(language: language)
    }

    func enqueue(words: [String]) {
        guard !words.isEmpty else { return }
        let text = words.joined(separator: " ")
        pendingTexts.append(text)
        pumpIfIdle()
    }

    func cancelAll() {
        pendingTexts.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        currentText = nil
    }

    private func pumpIfIdle() {
        guard currentText == nil, !pendingTexts.isEmpty else { return }
        let next = pendingTexts.removeFirst()
        currentText = next
        let utterance = AVSpeechUtterance(string: next)
        utterance.voice = voice
        utterance.rate = TTSPlayer.rate(forWPM: userWPM * 1.10)
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        synthesizer.speak(utterance)
    }

    /// Empirical linear mapping centered on `AVSpeechUtteranceDefaultSpeechRate`
    /// (≈ 0.5) corresponding to ~175 WPM. Clamped to a sane range.
    static func rate(forWPM wpm: Double) -> Float {
        let target = max(80.0, min(230.0, wpm))
        let raw = 0.5 * target / 175.0
        return Float(max(0.30, min(0.65, raw)))
    }
}

extension TTSPlayer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onStart?() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.currentText = nil
            self.onFinish?()
            self.pumpIfIdle()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.currentText = nil
            self.onFinish?()
            self.pumpIfIdle()
        }
    }
}
