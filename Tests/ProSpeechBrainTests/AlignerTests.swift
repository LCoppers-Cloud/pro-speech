import Testing
@testable import ProSpeechBrain

@Suite("Aligner")
struct AlignerTests {
    @Test func exactMatchAdvances() {
        let a = Aligner()
        a.setBuffer(["we", "need", "to", "invest", "in", "renewable", "energy"])
        #expect(a.observe(spoken: "we") == .advance(toBufferIndex: 1))
        #expect(a.observe(spoken: "need") == .advance(toBufferIndex: 2))
        #expect(a.observe(spoken: "to") == .advance(toBufferIndex: 3))
        #expect(a.wordsRemaining == 4)
    }

    @Test func skipsAheadOnMinorParaphrase() {
        let a = Aligner(maxSkip: 2)
        a.setBuffer(["we", "should", "also", "consider", "the", "cost"])
        #expect(a.observe(spoken: "we") == .advance(toBufferIndex: 1))
        // Speaker skipped "should also" and went straight to "consider"
        #expect(a.observe(spoken: "consider") == .advance(toBufferIndex: 4))
    }

    @Test func offScriptAfterRepeatedMisses() {
        let a = Aligner(maxSkip: 1, offScriptThreshold: 3)
        a.setBuffer(["the", "sky", "is", "blue"])
        _ = a.observe(spoken: "completely")
        _ = a.observe(spoken: "different")
        let result = a.observe(spoken: "topic")
        #expect(result == .offScript)
    }

    @Test func ignoresImmediateRepetition() {
        let a = Aligner()
        a.setBuffer(["very", "important", "point"])
        #expect(a.observe(spoken: "very") == .advance(toBufferIndex: 1))
        #expect(a.observe(spoken: "very") == .noChange, "should not double-advance on 'very, very'")
        #expect(a.observe(spoken: "important") == .advance(toBufferIndex: 2))
    }

    @Test func punctuationAndCaseAreNormalized() {
        let a = Aligner()
        a.setBuffer(["Hello", "world"])
        #expect(a.observe(spoken: "HELLO!") == .advance(toBufferIndex: 1))
        #expect(a.observe(spoken: "world.") == .advance(toBufferIndex: 2))
    }

    @Test func appendBufferKeepsCursor() {
        let a = Aligner()
        a.setBuffer(["one", "two"])
        _ = a.observe(spoken: "one")
        a.appendToBuffer(["three", "four"])
        #expect(a.observe(spoken: "two") == .advance(toBufferIndex: 2))
        #expect(a.wordsRemaining == 2)
    }
}
