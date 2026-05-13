import Foundation

/// Per-speaker stats persisted across sessions.
public struct SpeakerProfile: Codable, Equatable, Sendable {
    public var meanWPM: Double
    public var sigmaWPM: Double
    public var meanSyllablesPerWord: Double
    public var sessions: Int

    public static let defaultProfile = SpeakerProfile(
        meanWPM: 140,
        sigmaWPM: 25,
        meanSyllablesPerWord: 1.4,
        sessions: 0
    )

    public init(meanWPM: Double, sigmaWPM: Double, meanSyllablesPerWord: Double, sessions: Int) {
        self.meanWPM = meanWPM
        self.sigmaWPM = sigmaWPM
        self.meanSyllablesPerWord = meanSyllablesPerWord
        self.sessions = sessions
    }

    /// EWMA update with τ = 5 sessions (α ≈ 0.18).
    public mutating func record(sessionMeanWPM: Double, sessionSigmaWPM: Double, sessionSyllablesPerWord: Double) {
        let alpha = 1.0 - exp(-1.0 / 5.0)
        meanWPM = alpha * sessionMeanWPM + (1 - alpha) * meanWPM
        sigmaWPM = alpha * sessionSigmaWPM + (1 - alpha) * sigmaWPM
        meanSyllablesPerWord = alpha * sessionSyllablesPerWord + (1 - alpha) * meanSyllablesPerWord
        sessions += 1
    }
}
