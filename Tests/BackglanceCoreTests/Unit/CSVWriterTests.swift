@testable import BackglanceCore
import XCTest

/// Covers `CSVWriter`: RFC 4180 quoting, doubling, line endings, the formula-injection
/// guard and the optional BOM. See docs/features/EXPORT_AUTOMATION.md#csv-rfc-4180.
final class CSVWriterTests: XCTestCase {
    // MARK: - row(_:) / escape(_:) quoting

    /// A comma inside a field forces quoting; the delimiter itself must survive
    /// intact inside the quotes, not be stripped or escaped as if it were the quote
    /// character.
    func testFieldContainingACommaIsQuoted() {
        let writer = CSVWriter()

        XCTAssertEqual(writer.escape("Alice, Bob"), "\"Alice, Bob\"")
    }

    /// A literal `"` inside a field is doubled per RFC 4180, and the whole field is
    /// then wrapped in quotes so a reader can tell the doubled quote from the
    /// field's own closing quote.
    func testEmbeddedQuoteIsDoubledAndFieldIsQuoted() {
        let writer = CSVWriter()

        XCTAssertEqual(writer.escape(#"She said "hi""#), "\"She said \"\"hi\"\"\"")
    }

    /// `\r\n` inside a field (a body copied from an app that used CRLF internally)
    /// must be quoted whole, not split into two fields or two rows.
    func testCRLFInsideAFieldIsQuoted() {
        let writer = CSVWriter()

        XCTAssertEqual(writer.escape("line one\r\nline two"), "\"line one\r\nline two\"")
    }

    /// A bare `\n` alone (no `\r`) is also a quoting trigger — RFC 4180 lists both.
    func testBareNewlineInsideAFieldIsQuoted() {
        let writer = CSVWriter()

        XCTAssertEqual(writer.escape("line one\nline two"), "\"line one\nline two\"")
    }

    /// A field with none of the four trigger characters is written back verbatim —
    /// quoting everything would still be valid CSV, but it would make every export
    /// harder to read for no reason.
    func testPlainFieldIsNotQuoted() {
        let writer = CSVWriter()

        XCTAssertEqual(writer.escape("Build finished"), "Build finished")
    }

    // MARK: - row(_:) shape

    /// Every row — including a caller's header row, since `row(_:)` does not treat
    /// the header specially — ends in `\r\n`, and fields are comma-joined.
    func testRowJoinsFieldsWithCommasAndEndsInCRLF() {
        let writer = CSVWriter()

        XCTAssertEqual(writer.row(["uuid", "title", "body"]), "uuid,title,body\r\n")
    }

    /// A `nil` field becomes an empty string, not the literal text "nil" or a
    /// dropped column — the row must keep its column count.
    func testNilFieldBecomesEmptyString() {
        let writer = CSVWriter()

        XCTAssertEqual(writer.row(["a", nil, "c"]), "a,,c\r\n")
    }

    // MARK: - protectFormulas

    /// Every character the CSV-injection guard watches for — `=`, `+`, `-`, `@`, a
    /// leading tab, a leading CR — gets an apostrophe prefix when it starts a field,
    /// so a spreadsheet never evaluates notification text as a formula.
    func testEveryFormulaInjectionPrefixIsGuarded() {
        let writer = CSVWriter(protectFormulas: true)

        for prefix in ["=", "+", "-", "@", "\t", "\r"] {
            let field = "\(prefix)SUM(A1:A9)"
            let escaped = writer.escape(field)
            XCTAssertTrue(
                escaped.contains("'\(prefix)SUM(A1:A9)"),
                "expected an apostrophe before \(prefix.debugDescription), got \(escaped.debugDescription)"
            )
        }
    }

    /// A field that merely *contains* one of the trigger characters, without
    /// starting with it, is left alone — only a field beginning with one of them can
    /// be interpreted as a formula by a spreadsheet.
    func testFormulaGuardOnlyLooksAtTheFirstCharacter() {
        let writer = CSVWriter(protectFormulas: true)

        XCTAssertEqual(writer.escape("Total = 12"), "Total = 12")
    }

    /// Turning the guard off leaves a formula-looking field exactly as given — the
    /// "Raw values" toggle docs/features/EXPORT_AUTOMATION.md's edge-case table
    /// mentions.
    func testProtectFormulasFalseLeavesTheFieldAlone() {
        let writer = CSVWriter(protectFormulas: false)

        XCTAssertEqual(writer.escape("=SUM(A1:A9)"), "=SUM(A1:A9)")
    }

    // MARK: - byteOrderMark

    /// The default writer emits no preamble at all.
    func testPreambleIsEmptyByDefault() {
        let writer = CSVWriter()

        XCTAssertEqual(writer.preamble, "")
    }

    /// Asking for a BOM is the only thing that produces one — nothing else about
    /// `row(_:)` changes.
    func testPreambleIsTheBOMOnlyWhenRequested() {
        let writer = CSVWriter(byteOrderMark: true)

        XCTAssertEqual(writer.preamble, "\u{FEFF}")
    }
}
