import BackglanceCore
@testable import BackglanceUI
import Foundation
import XCTest

// MARK: - SearchViewModelTests

@MainActor
final class SearchViewModelTests: XCTestCase {
    // MARK: - Debounce

    /// One query per pause, not one per keystroke. A search box that queries
    /// the archive on every character is how a menu bar app ends up with a
    /// spinning fan.
    func testTypingQuicklyRunsOneSearch() async throws {
        let engine = StubSearch()
        let model = SearchViewModel(search: engine, debounce: .milliseconds(30))

        model.text = "i"
        model.text = "in"
        model.text = "inv"
        model.text = "invoice"
        try await Task.sleep(for: .milliseconds(200))

        let queries = await engine.queries
        XCTAssertEqual(queries, ["invoice"])
    }

    func testTheLastTextTypedIsTheOneSearched() async throws {
        let engine = StubSearch()
        engine.result = [SearchHit(notificationID: 1, score: 1, sources: [.fts])]
        let model = SearchViewModel(search: engine, debounce: .milliseconds(20))

        model.text = "deploy"
        try await Task.sleep(for: .milliseconds(100))
        model.text = "invoice"
        try await Task.sleep(for: .milliseconds(100))

        let queries = await engine.queries
        XCTAssertEqual(queries, ["deploy", "invoice"])
        XCTAssertEqual(model.hits.count, 1)
    }

    func testSearchingNowSkipsTheWait() async {
        let engine = StubSearch()
        let model = SearchViewModel(search: engine, debounce: .seconds(10))
        model.text = "invoice"

        await model.searchNow()

        let queries = await engine.queries
        XCTAssertEqual(queries, ["invoice"])
    }

    // MARK: - Emptiness

    func testAnEmptyFieldSearchesNothingAndShowsTheHint() async throws {
        let engine = StubSearch()
        let model = SearchViewModel(search: engine, debounce: .milliseconds(10))

        model.text = "   "
        try await Task.sleep(for: .milliseconds(100))

        let queries = await engine.queries
        XCTAssertTrue(queries.isEmpty)
        XCTAssertEqual(model.emptyStateKind, .noQuery)
        XCTAssertFalse(model.isSearching)
    }

    func testClearingResetsEverything() async throws {
        let engine = StubSearch()
        engine.result = [SearchHit(notificationID: 1, score: 1, sources: [.fts])]
        let model = SearchViewModel(search: engine, debounce: .milliseconds(10))
        model.text = "invoice"
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.hits.isEmpty)

        model.clear()

        XCTAssertTrue(model.text.isEmpty)
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertNil(model.inlineError)
        XCTAssertFalse(model.isSearching)
    }

    // MARK: - Empty states

    /// The semantic hint only makes sense for a query that reads like a
    /// sentence; on `from:slack invoice` it would be nonsense.
    func testASentenceWithSemanticOffExplainsItself() async throws {
        let engine = StubSearch()
        let model = SearchViewModel(search: engine, semanticEnabled: { false }, debounce: .milliseconds(10))

        model.text = "the message about the invoice"
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(model.emptyStateKind, .semanticOff)
    }

    func testAGrammarQueryWithNoResultsJustSaysSo() async throws {
        let engine = StubSearch()
        let model = SearchViewModel(search: engine, semanticEnabled: { false }, debounce: .milliseconds(10))

        model.text = "from:slack invoice"
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(model.emptyStateKind, .noResults)
    }

    func testWithSemanticOnThereIsNothingToExplain() async throws {
        let engine = StubSearch()
        let model = SearchViewModel(search: engine, semanticEnabled: { true }, debounce: .milliseconds(10))

        model.text = "the message about the invoice"
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(model.emptyStateKind, .noResults)
        let flags = await engine.semanticFlags
        XCTAssertEqual(flags, [true], "the toggle is read per call, not captured once")
    }

    // MARK: - Errors

    /// The one thing a search refuses is an unreadable date — and it says so
    /// under the field, without repeating what was typed.
    func testAnInvalidQueryBecomesAnInlineMessage() async throws {
        let engine = StubSearch()
        engine.error = SearchError.invalidQuery("before: expects a date like 2026-08-01, or -7d")
        let model = SearchViewModel(search: engine, debounce: .milliseconds(10))

        model.text = "before:soon"
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertEqual(model.inlineError, "before: expects a date like 2026-08-01, or -7d")
        XCTAssertFalse(model.isSearching)
    }

    /// A cancelled search is not a failure the user should ever read about.
    func testACancelledSearchLeavesNoErrorBehind() async throws {
        let engine = StubSearch()
        engine.error = SearchError.cancelled
        let model = SearchViewModel(search: engine, debounce: .milliseconds(10))

        model.text = "invoice"
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertNil(model.inlineError)
    }

    func testAnUnexpectedFailureSaysSomethingPlain() async throws {
        let engine = StubSearch()
        engine.error = StubError.boom
        let model = SearchViewModel(search: engine, debounce: .milliseconds(10))

        model.text = "invoice"
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertNotNil(model.inlineError)
        XCTAssertFalse(model.inlineError?.contains("invoice") ?? true, "the message never echoes the query")
    }
}

// MARK: - StubSearch

/// Records what it was asked, answers what it was told to. The whole reason
/// `SearchViewModel` depends on a protocol rather than on the engine.
private final class StubSearch: SearchRunning, @unchecked Sendable {
    var result: [SearchHit] = []
    var error: Error?

    private(set) var queries: [String] = []
    private(set) var semanticFlags: [Bool] = []

    func search(_ query: SearchQuery, semanticEnabled: Bool) async throws -> [SearchHit] {
        queries.append(query.text)
        semanticFlags.append(semanticEnabled)
        if let error {
            throw error
        }
        return result
    }
}

// MARK: - StubError

private enum StubError: Error {
    case boom
}
