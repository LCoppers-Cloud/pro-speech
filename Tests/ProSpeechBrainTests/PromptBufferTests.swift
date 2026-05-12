import Testing
@testable import ProSpeechBrain

@Suite("PromptBuffer")
struct PromptBufferTests {
    @Test func appendsAndCountsRemaining() {
        let buf = PromptBuffer()
        buf.append(contentsOf: ["one", "two", "three"])
        #expect(buf.remainingWords == 3)
        buf.advance(to: 2)
        #expect(buf.remainingWords == 1)
        #expect(Array(buf.unspoken) == ["three"])
    }

    @Test func advanceClampsToBounds() {
        let buf = PromptBuffer()
        buf.append(contentsOf: ["a", "b"])
        buf.advance(to: 100)
        #expect(buf.remainingWords == 0)
    }

    @Test func advanceNeverMovesBackwards() {
        let buf = PromptBuffer()
        buf.append(contentsOf: ["a", "b", "c"])
        buf.advance(to: 2)
        buf.advance(to: 1)
        #expect(buf.highlightIndex == 2)
    }

    @Test func newWordsSinceIndex() {
        let buf = PromptBuffer()
        buf.append(contentsOf: ["a", "b", "c"])
        #expect(Array(buf.newWords(since: 1)) == ["b", "c"])
        buf.append("d")
        #expect(Array(buf.newWords(since: 3)) == ["d"])
    }
}
