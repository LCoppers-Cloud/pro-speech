import Foundation

/// Dual-timescale EWMA over syllables-per-second.
///
/// `fast` (τ ≈ 2s) drives live pacing decisions. `slow` (τ ≈ 15s) is what we
/// persist to the speaker profile across sessions. We track syllables/sec
/// internally because per-word rate has huge variance ("a" vs "responsibility")
/// — syllable rate is far more stable.
public final class RateTracker {
    public struct Estimate {
        public let syllablesPerSecond: Double
        public let wordsPerMinute: Double
        public let meanSyllablesPerWord: Double
    }

    private let tauFast: Double
    private let tauSlow: Double
    private let clipLow: Double
    private let clipHigh: Double

    private var sFast: Double
    private var sSlow: Double
    private var meanSylPerWord: Double = 1.4
    private var meanSylPerWordCount: Int = 0

    private var lastWordEndTime: TimeInterval?

    public init(
        priorSyllablesPerSecond: Double = 140.0 * 1.4 / 60.0,  // 140 WPM default
        tauFast: TimeInterval = 2.0,
        tauSlow: TimeInterval = 15.0,
        clipLow: Double = 0.3,
        clipHigh: Double = 1.7
    ) {
        self.sFast = priorSyllablesPerSecond
        self.sSlow = priorSyllablesPerSecond
        self.tauFast = tauFast
        self.tauSlow = tauSlow
        self.clipLow = clipLow
        self.clipHigh = clipHigh
    }

    /// Feed one spoken word and its end-timestamp in seconds (relative to any
    /// fixed origin, only differences matter).
    public func observe(word: String, endTime: TimeInterval) {
        defer { lastWordEndTime = endTime }
        guard let last = lastWordEndTime else { return }
        let dt = endTime - last
        guard dt > 0.05, dt < 5.0 else {
            // Sub-50ms: same word duplicate / artifact. >5s: a pause, not a pace signal.
            return
        }

        let syllables = Double(SyllableCounter.count(word))
        let instantaneous = syllables / dt
        let clipped = max(clipLow * sSlow, min(clipHigh * sSlow, instantaneous))

        let alphaFast = 1.0 - exp(-dt / tauFast)
        let alphaSlow = 1.0 - exp(-dt / tauSlow)
        sFast = alphaFast * clipped + (1 - alphaFast) * sFast
        sSlow = alphaSlow * clipped + (1 - alphaSlow) * sSlow

        meanSylPerWordCount += 1
        let n = Double(meanSylPerWordCount)
        meanSylPerWord = ((n - 1) * meanSylPerWord + syllables) / n
    }

    /// Hint that the speaker paused; do not update the rate, but reset the
    /// timing origin so the post-pause first word doesn't see a huge `dt`.
    public func notePause(at time: TimeInterval) {
        lastWordEndTime = time
    }

    public var estimate: Estimate {
        let sps = sFast
        let spw = max(0.5, meanSylPerWord)
        let wpm = (sps / spw) * 60.0
        return Estimate(syllablesPerSecond: sps, wordsPerMinute: wpm, meanSyllablesPerWord: spw)
    }

    public var slowEstimate: Estimate {
        let spw = max(0.5, meanSylPerWord)
        let wpm = (sSlow / spw) * 60.0
        return Estimate(syllablesPerSecond: sSlow, wordsPerMinute: wpm, meanSyllablesPerWord: spw)
    }
}
