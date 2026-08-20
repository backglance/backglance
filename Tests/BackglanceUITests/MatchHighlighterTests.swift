@testable import BackglanceUI
import Foundation
import XCTest

/// `MatchHighlighter` turns the FTS5 U+E000/U+E001 match markers into an
/// `AttributedString` with the matched runs bold
/// (docs/features/SEARCH.md#fts-ranking-and-highlighting). All snippets here
/// are synthetic text, not real notification content.
final class MatchHighlighterTests: XCTestCase {
    // MARK: Internal

    func testSnippetWithOneMatch() {
        let attributed = MatchHighlighter.attributed("an \u{E000}invoice\u{E001} is due")

        XCTAssertEqual(String(attributed.characters), "an invoice is due")
        XCTAssertEqual(emphasizedSubstrings(attributed), ["invoice"])
    }

    func testSnippetWithSeveralMatches() {
        let attributed = MatchHighlighter.attributed(
            "the \u{E000}invoice\u{E001} for \u{E000}Slack\u{E001} is due"
        )

        XCTAssertEqual(String(attributed.characters), "the invoice for Slack is due")
        XCTAssertEqual(emphasizedSubstrings(attributed), ["invoice", "Slack"])
    }

    func testSnippetWithNoMatchesComesBackAsPlainText() {
        let attributed = MatchHighlighter.attributed("nothing matched here")

        XCTAssertEqual(String(attributed.characters), "nothing matched here")
        XCTAssertTrue(emphasizedSubstrings(attributed).isEmpty)
    }

    /// An open marker with no matching close (a truncated snippet) must not
    /// crash or lose the text after it — it stays emphasized to the end,
    /// same as the rest of search "degrades, never drops" on a surprise.
    func testUnclosedMarkerStaysEmphasizedRatherThanCrashing() {
        let attributed = MatchHighlighter.attributed("an \u{E000}invoice is due")

        XCTAssertEqual(String(attributed.characters), "an invoice is due")
        XCTAssertEqual(emphasizedSubstrings(attributed), ["invoice is due"])
    }

    func testEmptyStringReturnsEmptyAttributedString() {
        let attributed = MatchHighlighter.attributed("")

        XCTAssertTrue(attributed.characters.isEmpty)
        XCTAssertTrue(emphasizedSubstrings(attributed).isEmpty)
    }

    // MARK: Private

    /// The plain text of every run whose `inlinePresentationIntent` marks it
    /// as a match, in order — the shape both the "which characters" and the
    /// "markers gone" assertions above are checking.
    private func emphasizedSubstrings(_ attributed: AttributedString) -> [String] {
        attributed.runs
            .filter { $0.inlinePresentationIntent == .stronglyEmphasized }
            .map { String(attributed[$0.range].characters) }
    }
}
