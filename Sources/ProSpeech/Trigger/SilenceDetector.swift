import Foundation

/// Detects when the speaker has stopped for `gap` seconds. The brain uses this
/// to freeze the rate tracker, dim the on-screen highlight, and stop TTS over
/// silence. It does NOT fire the next Claude request — that is purely the
/// buffer-policy's job.
final class SilenceDetector {
    var gap: TimeInterval

    private var lastWordTime: TimeInterval?
    private(set) var isSilent: Bool = false

    var onSilenceBegan: (() -> Void)?
    var onSilenceEnded: (() -> Void)?

    init(gap: TimeInterval = 1.5) { self.gap = gap }

    func noteWord(at time: TimeInterval) {
        lastWordTime = time
        if isSilent {
            isSilent = false
            onSilenceEnded?()
        }
    }

    /// Called from a periodic tick (e.g., 4 Hz timer).
    func tick(now: TimeInterval) {
        guard let last = lastWordTime else { return }
        let elapsed = now - last
        if elapsed >= gap && !isSilent {
            isSilent = true
            onSilenceBegan?()
        }
    }
}
