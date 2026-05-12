import Testing
@testable import ProSpeechBrain

@Suite("RateTracker")
struct RateTrackerTests {
    @Test func convergesToSteadyRate() {
        let tracker = RateTracker(priorSyllablesPerSecond: 140 * 1.4 / 60)
        // Feed 30 single-syllable words at exactly 150 WPM = 2.5 wps = 2.5 sps (since 1 syl/word)
        // Word duration = 0.4s.
        var t: TimeInterval = 0
        for _ in 0..<30 {
            t += 0.4
            tracker.observe(word: "cat", endTime: t)
        }
        let wpm = tracker.estimate.wordsPerMinute
        #expect(wpm > 140 && wpm < 160, "expected ~150 WPM, got \(wpm)")
    }

    @Test func adaptsWithinFiveSecondsToStepChange() {
        let tracker = RateTracker(priorSyllablesPerSecond: 2.5)
        var t: TimeInterval = 0
        // 5 seconds at 120 WPM (1 syl/word, 0.5s each) — settle
        for _ in 0..<10 {
            t += 0.5
            tracker.observe(word: "cat", endTime: t)
        }
        let before = tracker.estimate.wordsPerMinute
        // Now accelerate to 220 WPM (0.27s/word) for 5 seconds
        for _ in 0..<18 {
            t += 0.27
            tracker.observe(word: "cat", endTime: t)
        }
        let after = tracker.estimate.wordsPerMinute
        #expect(after > before + 40, "expected meaningful acceleration; before=\(before) after=\(after)")
    }

    @Test func rejectsOutlierSingleWord() {
        let tracker = RateTracker(priorSyllablesPerSecond: 2.5)
        var t: TimeInterval = 0
        for _ in 0..<10 {
            t += 0.4
            tracker.observe(word: "cat", endTime: t)
        }
        let before = tracker.estimate.wordsPerMinute
        // One absurdly long word (paused mid-sentence): dt=3s
        t += 3.0
        tracker.observe(word: "uhhh", endTime: t)
        let after = tracker.estimate.wordsPerMinute
        let drop = before - after
        #expect(drop < 30, "single outlier should not crash the estimate; before=\(before) after=\(after)")
    }

    @Test func pauseDoesNotPoisonNextWord() {
        let tracker = RateTracker(priorSyllablesPerSecond: 2.5)
        tracker.observe(word: "the", endTime: 1.0)
        tracker.notePause(at: 5.0)
        tracker.observe(word: "speaker", endTime: 5.4)
        let wpm = tracker.estimate.wordsPerMinute
        #expect(wpm > 100, "pause should not crash WPM; got \(wpm)")
    }
}
