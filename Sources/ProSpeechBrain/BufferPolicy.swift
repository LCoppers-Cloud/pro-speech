import Foundation

/// Decides *when* to ask Claude for more words and *how many* to ask for.
///
/// Equations (see PACING.md):
///   L            = latencyClaude + latencyTTS + safetyMargin     [seconds]
///   k_σ          = 1 + z · (σ_WPM / WPM)                          [p90 ≈ 1.19]
///   N_min        = ⌈ WPM/60 · L · k_σ ⌉
///   N_chunk      = clip( 2·N_min + ⌈WPM/60 · 2⌉, lowerBound=8, upperBound=15 )
///   trigger when wordsRemaining ≤ N_min + ⌈WPM/60 · ℓ_claude⌉
public struct BufferPolicy {
    public var latencyClaude: TimeInterval
    public var latencyTTS: TimeInterval
    public var safetyMargin: TimeInterval
    public var sigmaOverMu: Double
    public var zScore: Double
    public var chunkLowerBound: Int
    public var chunkUpperBound: Int

    public init(
        latencyClaude: TimeInterval = 0.60,
        latencyTTS: TimeInterval = 0.15,
        safetyMargin: TimeInterval = 0.30,
        sigmaOverMu: Double = 0.15,
        zScore: Double = 1.28,
        chunkLowerBound: Int = 8,
        chunkUpperBound: Int = 15
    ) {
        self.latencyClaude = latencyClaude
        self.latencyTTS = latencyTTS
        self.safetyMargin = safetyMargin
        self.sigmaOverMu = sigmaOverMu
        self.zScore = zScore
        self.chunkLowerBound = chunkLowerBound
        self.chunkUpperBound = chunkUpperBound
    }

    public var lookahead: TimeInterval {
        latencyClaude + latencyTTS + safetyMargin
    }

    public func minBufferWords(wpm: Double) -> Int {
        let kSigma = 1.0 + zScore * sigmaOverMu
        let raw = wpm / 60.0 * lookahead * kSigma
        return max(1, Int(raw.rounded(.up)))
    }

    public func chunkSize(wpm: Double) -> Int {
        let nMin = minBufferWords(wpm: wpm)
        let claudeWords = Int((wpm / 60.0 * 2.0).rounded(.up))
        let raw = 2 * nMin + claudeWords
        return max(chunkLowerBound, min(chunkUpperBound, raw))
    }

    /// Number of words below which we should fire the next request, accounting
    /// for the latency of the request itself (the speaker will continue eating
    /// the buffer while Claude is generating).
    public func triggerThreshold(wpm: Double) -> Int {
        let nMin = minBufferWords(wpm: wpm)
        let inFlightWords = Int((wpm / 60.0 * latencyClaude).rounded(.up))
        return nMin + inFlightWords
    }

    public func shouldRequestMore(wordsRemaining: Int, wpm: Double, requestInFlight: Bool) -> Bool {
        guard !requestInFlight else { return false }
        return wordsRemaining <= triggerThreshold(wpm: wpm)
    }
}
