@testable import BackglanceSearch
import XCTest

final class FuzzyMatcherTests: XCTestCase {
    // MARK: - Scoring

    func testAnExactMatchScoresOne() {
        let matcher = FuzzyMatcher()
        let matches = matcher.matches(
            query: "invoice",
            in: [.init(id: 1, text: "invoice")]
        )

        XCTAssertEqual(matches.first?.similarity, 1.0)
    }

    func testAOneCharacterTypoOverAShortWordClearsTheThreshold() {
        let matcher = FuzzyMatcher()
        // "invoics" vs "invoice": one substitution out of 7 scalars → similarity 6/7 ≈ 0.857.
        let matches = matcher.matches(
            query: "invoics",
            in: [.init(id: 1, text: "invoice")]
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertGreaterThanOrEqual(matches[0].similarity, 0.6)
    }

    func testAnUnrelatedWordDoesNotClearTheThreshold() {
        let matcher = FuzzyMatcher()
        let matches = matcher.matches(
            query: "invoice",
            in: [.init(id: 1, text: "banana")]
        )

        XCTAssertTrue(matches.isEmpty)
    }

    func testATwoCharacterQueryReturnsNothing() {
        let matcher = FuzzyMatcher()
        let matches = matcher.matches(
            query: "in",
            in: [.init(id: 1, text: "invoice")]
        )

        XCTAssertTrue(matches.isEmpty, "typo correction on two characters is noise, not help")
    }

    func testWordLevelMatchingFindsATermInsideALongerString() {
        let matcher = FuzzyMatcher()
        let matches = matcher.matches(
            query: "invoice",
            in: [.init(id: 1, text: "Your March invoice is ready")]
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.similarity, 1.0, "the word 'invoice' inside the string is an exact match")
    }

    func testResultsComeBackSortedBestFirst() {
        let matcher = FuzzyMatcher()
        let matches = matcher.matches(
            query: "invoice",
            in: [
                .init(id: 1, text: "invoicex"), // one extra char
                .init(id: 2, text: "invoice"), // exact
                .init(id: 3, text: "invoicexy"), // two extra chars
            ]
        )

        XCTAssertEqual(matches.map(\.id), [2, 1, 3])
        for i in 1 ..< matches.count {
            XCTAssertGreaterThanOrEqual(matches[i - 1].similarity, matches[i].similarity)
        }
    }

    /// The implementation lowercases before comparing but does not strip diacritics —
    /// that job belongs to FTS5's `remove_diacritics 2` tokenizer, not this fallback.
    func testCaseIsFoldedButDiacriticsAreNotStripped() {
        let matcher = FuzzyMatcher()

        let caseFolded = matcher.matches(query: "INVOICE", in: [.init(id: 1, text: "invoice")])
        XCTAssertEqual(caseFolded.first?.similarity, 1.0, "case is folded before comparison")

        let diacritic = matcher.matches(query: "cafe", in: [.init(id: 1, text: "café")])
        XCTAssertNotEqual(
            diacritic.first?.similarity,
            1.0,
            "diacritics are compared as written, not stripped, by this matcher"
        )
    }

    // MARK: - Levenshtein internals

    func testLevenshteinEarlyExitOnLengthDifferenceAlone() {
        let matcher = FuzzyMatcher(threshold: 0.9)
        // "a" (1 scalar) vs "abcdefghij" (10 scalars): length-difference ratio is 9/10 = 0.9,
        // which already exceeds (1 - threshold) = 0.1, so similarity() returns 0 without
        // ever calling levenshtein().
        let score = matcher.similarity(Array("a".unicodeScalars), Array("abcdefghij".unicodeScalars))

        XCTAssertEqual(score, 0.0)
    }
}
