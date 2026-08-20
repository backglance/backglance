@testable import BackglanceUI
import XCTest

/// `SearchFilter.removing(_:from:)` is the pure function behind "tapping a
/// chip rewrites the query text" (docs/features/SEARCH.md#ui-components).
/// These tests cover it without a view, using synthetic query text only.
final class SearchFilterTests: XCTestCase {
    func testRemovingAFilterFromTheMiddleOfTheQuery() {
        let filter = SearchFilter(id: "from", label: "from: Slack", token: "from:slack")
        let text = "from:slack invoice over"

        XCTAssertEqual(SearchFilter.removing(filter, from: text), "invoice over")
    }

    func testRemovingAFilterFromTheStartOfTheQuery() {
        let filter = SearchFilter(id: "missed", label: "is: missed", token: "is:missed")
        let text = "is:missed invoice"

        XCTAssertEqual(SearchFilter.removing(filter, from: text), "invoice")
    }

    func testRemovingAFilterFromTheEndOfTheQuery() {
        let filter = SearchFilter(id: "link", label: "has: link", token: "has:link")
        let text = "invoice has:link"

        XCTAssertEqual(SearchFilter.removing(filter, from: text), "invoice")
    }

    /// Deleting a token from the middle of the text leaves the two
    /// neighbouring spaces adjacent; the leftover double space must collapse
    /// to one rather than surviving in the rewritten query.
    func testRemovingAFilterCollapsesTheLeftoverDoubleSpace() {
        let filter = SearchFilter(id: "after", label: "after: 7 days", token: "after:-7d")
        let text = "invoice after:-7d over"

        XCTAssertEqual(SearchFilter.removing(filter, from: text), "invoice over")
    }

    func testRemovingATokenThatIsNotPresentLeavesTheTextUnchanged() {
        let filter = SearchFilter(id: "vip", label: "is: vip", token: "is:vip")
        let text = "invoice over"

        XCTAssertEqual(SearchFilter.removing(filter, from: text), "invoice over")
    }

    /// A quoted `sender:` token contains characters (`"`, non-ASCII) that
    /// must not confuse a naive tokenizer — this must still be an exact
    /// substring removal, whitespace-trimmed at the edges.
    func testRemovingAQuotedSenderToken() {
        let filter = SearchFilter(id: "sender", label: "sender: Ayşe", token: "sender:\"Ayşe\"")
        let text = "sender:\"Ayşe\" invoice"

        XCTAssertEqual(SearchFilter.removing(filter, from: text), "invoice")
    }
}
