import Testing
@testable import ProSpeechBrain

@Suite("BufferPolicy")
struct BufferPolicyTests {
    @Test func minBufferScalesWithWPM() {
        let policy = BufferPolicy()
        let slow = policy.minBufferWords(wpm: 100)
        let fast = policy.minBufferWords(wpm: 200)
        #expect(fast > slow)
        // At default L=1.05s, k_σ ≈ 1.192, 150 WPM → 2.5/s * 1.05 * 1.192 ≈ 3.13 → 4
        let medium = policy.minBufferWords(wpm: 150)
        #expect(medium >= 3 && medium <= 5)
    }

    @Test func chunkSizeIsClippedToBounds() {
        let policy = BufferPolicy(chunkLowerBound: 8, chunkUpperBound: 15)
        #expect(policy.chunkSize(wpm: 60) == 8)
        #expect(policy.chunkSize(wpm: 300) == 15)
    }

    @Test func triggersWhenLowOnWords() {
        let policy = BufferPolicy()
        let threshold = policy.triggerThreshold(wpm: 150)
        #expect(policy.shouldRequestMore(wordsRemaining: threshold - 1, wpm: 150, requestInFlight: false))
        #expect(!policy.shouldRequestMore(wordsRemaining: threshold + 5, wpm: 150, requestInFlight: false))
    }

    @Test func doesNotTriggerWhenAlreadyInFlight() {
        let policy = BufferPolicy()
        #expect(!policy.shouldRequestMore(wordsRemaining: 0, wpm: 150, requestInFlight: true))
    }

    @Test func lookaheadMatchesComponents() {
        let policy = BufferPolicy(latencyClaude: 0.4, latencyTTS: 0.1, safetyMargin: 0.2)
        #expect(policy.lookahead == 0.7)
    }
}
