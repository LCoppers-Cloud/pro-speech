import Testing
@testable import ProSpeechBrain

@Suite("SyllableCounter")
struct SyllableCounterTests {
    @Test func monosyllables() {
        #expect(SyllableCounter.count("a") == 1)
        #expect(SyllableCounter.count("cat") == 1)
        #expect(SyllableCounter.count("strength") == 1)
    }

    @Test func polysyllables() {
        #expect(SyllableCounter.count("hello") == 2)
        #expect(SyllableCounter.count("responsibility") >= 5)
        #expect(SyllableCounter.count("table") == 2)
        #expect(SyllableCounter.count("invisible") == 4)
    }

    @Test func silentE() {
        #expect(SyllableCounter.count("make") == 1)
        #expect(SyllableCounter.count("rate") == 1)
        #expect(SyllableCounter.count("strike") == 1)
    }

    @Test func punctuationIgnored() {
        #expect(SyllableCounter.count("hello!") == SyllableCounter.count("hello"))
        #expect(SyllableCounter.count("don't") == SyllableCounter.count("dont"))
    }

    @Test func empty() {
        #expect(SyllableCounter.count("") == 1)
    }
}
