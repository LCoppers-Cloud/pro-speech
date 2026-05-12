import Foundation

public enum SyllableCounter {
    public static func count(_ word: String) -> Int {
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        let lower = word.lowercased()
        var letters: [Character] = []
        letters.reserveCapacity(lower.count)
        for ch in lower where ch.isLetter { letters.append(ch) }
        guard !letters.isEmpty else { return 1 }

        var groups = 0
        var prevWasVowel = false
        for ch in letters {
            let isVowel = vowels.contains(ch)
            if isVowel && !prevWasVowel { groups += 1 }
            prevWasVowel = isVowel
        }

        if letters.count > 2,
           letters.last == "e",
           !vowels.contains(letters[letters.count - 2]) {
            groups -= 1
        }
        if letters.suffix(2) == ["l", "e"] && letters.count > 2 {
            groups += 1
        }
        return max(1, groups)
    }

    public static func count(words: [String]) -> Int {
        words.reduce(0) { $0 + count($1) }
    }
}
