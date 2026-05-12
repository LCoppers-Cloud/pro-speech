import Foundation

/// Fuzzy alignment of what the speaker just said to the buffered prompt.
///
/// v1 uses normalized-token-equality + a small skip-ahead window. Real-world
/// speakers paraphrase ("we need to invest in renewable energy" → "we have to
/// put money into green power"), so we tolerate misses up to `maxSkip` words
/// before declaring the speaker has gone off-script.
///
/// v2 should swap the equality check for Double Metaphone phonetic hashing +
/// a windowed DTW. The public interface stays the same.
public final class Aligner {
    public enum Result: Equatable {
        case advance(toBufferIndex: Int)
        case noChange
        case offScript
    }

    private let maxSkip: Int
    private let offScriptThreshold: Int
    private var consecutiveMisses: Int = 0

    /// Tokens already laid down by the buffer, lowercased + stripped.
    public private(set) var buffer: [String] = []
    public private(set) var cursor: Int = 0  // next-unspoken index

    public init(maxSkip: Int = 2, offScriptThreshold: Int = 3) {
        self.maxSkip = maxSkip
        self.offScriptThreshold = offScriptThreshold
    }

    public func setBuffer(_ tokens: [String]) {
        buffer = tokens.map(Aligner.normalize)
        cursor = 0
        consecutiveMisses = 0
    }

    /// Append more buffered tokens without resetting the cursor.
    public func appendToBuffer(_ tokens: [String]) {
        buffer.append(contentsOf: tokens.map(Aligner.normalize))
    }

    /// Feed the next spoken word. Returns whether to advance the highlight.
    public func observe(spoken: String) -> Result {
        let token = Aligner.normalize(spoken)
        guard !token.isEmpty else { return .noChange }
        guard cursor < buffer.count else { return .noChange }

        // Repetition guard ("very, very important"): if we just advanced past
        // this same token, don't advance again.
        if cursor > 0, buffer[cursor - 1] == token {
            return .noChange
        }

        let lookEnd = min(cursor + maxSkip + 1, buffer.count)
        for i in cursor..<lookEnd {
            if buffer[i] == token {
                cursor = i + 1
                consecutiveMisses = 0
                return .advance(toBufferIndex: cursor)
            }
        }

        consecutiveMisses += 1
        if consecutiveMisses >= offScriptThreshold {
            return .offScript
        }
        return .noChange
    }

    public func resetMisses() { consecutiveMisses = 0 }

    public var wordsRemaining: Int { max(0, buffer.count - cursor) }

    static func normalize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s.lowercased() where ch.isLetter || ch.isNumber {
            out.append(ch)
        }
        return out
    }
}
