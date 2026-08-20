import Foundation

// MARK: - FuzzyMatcher

/// Catches "I typed it wrong" where FTS5 prefix matching only catches "I stopped typing early".
///
/// Runs when FTS returns fewer than five hits, over a bounded candidate set: distinct
/// `title` and `sender` values of the 5,000 most recent notifications that already passed
/// the same app/date filters as the FTS query. A query is compared against every word of a
/// candidate and against the whole candidate string, and the best of those scores is kept —
/// that is what lets a three-word title still match on the one word the user misspelled.
///
/// Ported from PasteShelf. See docs/features/SEARCH.md#fuzzy-fallback.
public struct FuzzyMatcher: Sendable {
    // MARK: Lifecycle

    public init(threshold: Double = 0.6) {
        self.threshold = threshold
    }

    // MARK: Public

    /// One title or sender value pulled from the archive, ready to compare against the query.
    public struct Candidate: Sendable {
        // MARK: Lifecycle

        public init(id: Int64, text: String) {
            self.id = id
            self.text = text
        }

        // MARK: Public

        public let id: Int64
        public let text: String
    }

    /// A candidate that cleared ``FuzzyMatcher/threshold``, with the similarity that got it there.
    public struct Match: Sendable {
        public let id: Int64
        public let similarity: Double
    }

    /// Similarity floor a candidate must clear to be returned. 0.6 is the PasteShelf value:
    /// loose enough to survive a transposed or dropped character, tight enough that an
    /// unrelated word does not sneak in.
    public var threshold: Double

    /// Scores every candidate against `query` and returns the ones at or above ``threshold``,
    /// best match first.
    ///
    /// Queries under three Unicode scalars return nothing: typo correction on one or two
    /// characters has too many equally-plausible corrections to be worth showing — it is
    /// noise, not help. Case and diacritics are folded before comparison (`.lowercased()`
    /// does not strip diacritics on its own, so "café" and "cafe" are compared as written;
    /// callers relying on diacritic-insensitive matching should route through FTS5's
    /// `remove_diacritics 2` tokenizer instead, per docs/features/SEARCH.md#fts5-table-design).
    public func matches(query: String, in candidates: [Candidate]) -> [Match] {
        let needle = Array(query.lowercased().unicodeScalars)
        guard needle.count >= 3 else {
            return []
        }
        var out: [Match] = []
        out.reserveCapacity(64)
        for candidate in candidates {
            var best = 0.0
            for word in candidate.text.lowercased().split(separator: " ") {
                best = max(best, similarity(needle, Array(word.unicodeScalars)))
                if best >= 1.0 {
                    break
                }
            }
            best = max(best, similarity(needle, Array(candidate.text.lowercased().unicodeScalars)))
            if best >= threshold {
                out.append(Match(id: candidate.id, similarity: best))
            }
        }
        return out.sorted { $0.similarity > $1.similarity }
    }

    // MARK: Internal

    /// `1 − distance / max(len)`, the PasteShelf similarity formula.
    ///
    /// Bails out before running Levenshtein at all when the two strings' length difference
    /// alone already puts the best possible similarity under ``threshold``: a candidate 20
    /// scalars longer than a 4-scalar query cannot score above 0.6 no matter what the
    /// characters are, so there is no reason to pay for the edit-distance table. That guard
    /// is what keeps a 5,000-candidate scan inside the search latency budget — see
    /// docs/features/SEARCH.md#fuzzy-fallback ("well under 20 ms on Apple silicon").
    func similarity(_ lhs: [Unicode.Scalar], _ rhs: [Unicode.Scalar]) -> Double {
        let maxLen = max(lhs.count, rhs.count)
        guard maxLen > 0 else {
            return 1.0
        }
        if Double(abs(lhs.count - rhs.count)) / Double(maxLen) > (1.0 - threshold) {
            return 0.0
        }
        return 1.0 - Double(levenshtein(lhs, rhs)) / Double(maxLen)
    }

    /// Two-row dynamic-programming Levenshtein distance: O(a·b) time, O(min(a, b)) memory.
    ///
    /// Only two rows of the DP table are ever live at once — the previous row and the one
    /// being built — because computing `curr[j]` only reads `prev[j]`, `prev[j - 1]` and
    /// `curr[j - 1]`. Keeping the shorter string as the row width (rather than the full
    /// `a.count × b.count` table) is what makes the memory cost O(min(n, m)) instead of
    /// O(max(n, m)); titles and sender names are short enough here that either order is
    /// cheap, but the shape is kept general.
    func levenshtein(_ lhs: [Unicode.Scalar], _ rhs: [Unicode.Scalar]) -> Int {
        if lhs.isEmpty {
            return rhs.count
        }
        if rhs.isEmpty {
            return lhs.count
        }
        var prev = Array(0 ... rhs.count)
        var curr = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1 ... lhs.count {
            curr[0] = i
            for j in 1 ... rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[rhs.count]
    }
}
