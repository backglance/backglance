import BackglanceCore
@testable import BackglanceSearch
import BackglanceTestSupport
import Foundation
import GRDB
import XCTest

final class HybridSearchTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - Fusion

    /// Rank fusion, not score fusion: bm25 is negative and unbounded, cosine is
    /// 0…1, similarity is 0…1 with another distribution again. Only positions
    /// are comparable, and this is the arithmetic that says so.
    func testEachBranchContributesItsWeightOverItsRank() {
        let fused = HybridSearch.fuse(
            fts: [FTSHit(notificationID: 1, score: -3, snippet: "snip")],
            fuzzy: [],
            semantic: []
        )

        XCTAssertEqual(fused.count, 1)
        XCTAssertEqual(fused.first?.score ?? 0, 0.4 / 61.0, accuracy: 1e-9)
        XCTAssertEqual(fused.first?.sources, [.fts])
        XCTAssertEqual(fused.first?.snippet, "snip")
    }

    /// A notification two branches agree on outranks one that only a
    /// higher-weighted branch found — agreement is the signal fusion exists for.
    func testAgreementBetweenBranchesLiftsAHitAboveASingleStrongOne() {
        let fused = HybridSearch.fuse(
            fts: [FTSHit(notificationID: 10, score: -1, snippet: "")],
            fuzzy: [FuzzyMatcher.Match(id: 10, similarity: 0.9)],
            semantic: [SemanticHit(notificationID: 20, similarity: 0.99)]
        )

        XCTAssertEqual(fused.map(\.notificationID), [10, 20])
        XCTAssertEqual(fused.first?.sources, [.fts, .fuzzy])
        XCTAssertEqual(fused.last?.sources, [.semantic])
    }

    func testTheSnippetComesFromTheBranchThatHasOne() {
        let fused = HybridSearch.fuse(
            fts: [FTSHit(notificationID: 5, score: -1, snippet: "")],
            fuzzy: [FuzzyMatcher.Match(id: 5, similarity: 0.8)],
            semantic: []
        )

        XCTAssertNil(fused.first?.snippet, "an empty snippet is not a snippet")
    }

    func testTiesBreakOnIDSoTheOrderIsStable() {
        let fused = HybridSearch.fuse(
            fts: [FTSHit(notificationID: 1, score: 0, snippet: "")],
            fuzzy: [FuzzyMatcher.Match(id: 2, similarity: 1)],
            semantic: []
        )

        XCTAssertEqual(fused.count, 2)
        XCTAssertEqual(Set(fused.map(\.notificationID)), [1, 2])
    }

    func testNothingInNothingOut() {
        XCTAssertTrue(HybridSearch.fuse(fts: [], fuzzy: [], semantic: []).isEmpty)
    }

    // MARK: - Searching

    func testAFreeTermFindsTheNotificationThatContainsIt() async throws {
        let archive = try XCTUnwrap(archive)
        let wanted = try seed(title: "Invoice 2231 paid")
        _ = try seed(title: "Deploy finished")

        let hits = try await HybridSearch(archive: archive).search(SearchQuery(text: "invoice"))

        XCTAssertEqual(hits.map(\.notificationID), [wanted])
        // Fuzzy runs alongside full text on a thin result set, and an exact
        // term is also its own best fuzzy match — so both branches claim it.
        XCTAssertTrue(hits.first?.sources.contains(.fts) ?? false)
    }

    func testAFilterOnlyQueryReturnsTheRowsThatMatchTheFilter() async throws {
        let archive = try XCTUnwrap(archive)
        let pinned = try seed(title: "Deploy finished", isPinned: true)
        _ = try seed(title: "Fixture message 000001")

        let hits = try await HybridSearch(archive: archive).search(SearchQuery(text: "is:pinned"))

        XCTAssertEqual(hits.map(\.notificationID), [pinned])
    }

    /// FTS5 has no unary NOT, so this only works if the caller inverts the
    /// match rather than binding it.
    func testANegationOnlyQueryReturnsEverythingElse() async throws {
        let archive = try XCTUnwrap(archive)
        _ = try seed(title: "Draft saved")
        let kept = try seed(title: "Deploy finished")

        let hits = try await HybridSearch(archive: archive).search(SearchQuery(text: "-draft"))

        XCTAssertEqual(hits.map(\.notificationID), [kept])
    }

    /// A `from:` that matches no app means no results — not "ignore the filter
    /// and show everything", which is how a search box loses its user's trust.
    func testAnAppFilterThatMatchesNothingReturnsNothing() async throws {
        let archive = try XCTUnwrap(archive)
        _ = try seed(title: "Invoice 2231 paid")

        let hits = try await HybridSearch(archive: archive).search(SearchQuery(text: "from:nosuchapp invoice"))

        XCTAssertTrue(hits.isEmpty)
    }

    func testAnAppFilterNarrowsToThatApp() async throws {
        let archive = try XCTUnwrap(archive)
        let slack = try seed(title: "Invoice 2231 paid", bundleID: Stubs.BundleID.slack, appName: "Slack")
        _ = try seed(title: "Invoice 2231 paid", bundleID: Stubs.BundleID.mail, appName: "Mail")

        let hits = try await HybridSearch(archive: archive).search(SearchQuery(text: "from:slack invoice"))

        XCTAssertEqual(hits.map(\.notificationID), [slack])
    }

    /// The structured filters have to survive the full-text branch, or
    /// `after:` would quietly do nothing whenever a term was typed with it.
    func testADateFilterStillAppliesWhenThereIsAlsoAFreeTerm() async throws {
        let archive = try XCTUnwrap(archive)
        let recent = try seed(title: "Invoice 2231 paid", deliveredAt: Stubs.epoch)
        _ = try seed(title: "Invoice 2230 paid", deliveredAt: Stubs.epoch.addingTimeInterval(-90 * 86_400))

        let query = SearchQuery(text: "invoice after:2025-12-30")
        let hits = try await HybridSearch(archive: archive).search(query)

        XCTAssertEqual(hits.map(\.notificationID), [recent])
    }

    func testAnEmptyQueryIsNotASearch() async throws {
        let archive = try XCTUnwrap(archive)
        _ = try seed(title: "Deploy finished")

        let hits = try await HybridSearch(archive: archive).search(SearchQuery(text: "   "))

        XCTAssertTrue(hits.isEmpty)
    }

    func testAnUnreadableDateIsTheOneThingASearchRefuses() async throws {
        let archive = try XCTUnwrap(archive)
        let search = HybridSearch(archive: archive)

        do {
            _ = try await search.search(SearchQuery(text: "before:soon"))
            XCTFail("an unparseable date has to be reported")
        } catch let error as SearchError {
            guard case let .invalidQuery(reason) = error else {
                return XCTFail("expected invalidQuery, got \(error)")
            }
            XCTAssertFalse(reason.contains("soon"), "the message must not echo what was typed")
        }
    }

    /// Typing it wrong is what fuzzy is for, and it only runs when full text
    /// came back thin.
    func testAMisspelledTermStillFindsTheNotification() async throws {
        let archive = try XCTUnwrap(archive)
        let wanted = try seed(title: "Invoice 2231 paid")

        let hits = try await HybridSearch(archive: archive).search(SearchQuery(text: "invoyce"))

        XCTAssertEqual(hits.map(\.notificationID), [wanted])
        XCTAssertEqual(hits.first?.sources, [.fuzzy])
    }

    /// `is:vip` before the rules engine ships: the user's own pins, which is a
    /// smaller answer than the grammar promises but a true one.
    func testVIPFiltersToPinnedUntilTheRulesEngineShips() async throws {
        let archive = try XCTUnwrap(archive)
        let pinned = try seed(title: "Invoice 2231 paid", isPinned: true)
        _ = try seed(title: "Invoice 2230 paid")

        let hits = try await HybridSearch(archive: archive).search(SearchQuery(text: "invoice is:vip"))

        XCTAssertEqual(hits.map(\.notificationID), [pinned])
    }

    func testTheLimitBoundsTheResult() async throws {
        let archive = try XCTUnwrap(archive)
        for index in 0 ..< 5 {
            _ = try seed(title: "Invoice 22\(index) paid")
        }

        let hits = try await HybridSearch(archive: archive).search(SearchQuery(text: "invoice", limit: 2))

        XCTAssertEqual(hits.count, 2)
    }

    // MARK: - Full text only

    func testFTSOnlySkipsTheOtherBranchesEntirely() throws {
        let archive = try XCTUnwrap(archive)
        let wanted = try seed(title: "Invoice 2231 paid")

        let hits = try HybridSearch(archive: archive).ftsOnly(SearchQuery(text: "invoice"))

        XCTAssertEqual(hits.map(\.notificationID), [wanted])
        XCTAssertEqual(hits.first?.sources, [.fts])
    }

    func testFTSOnlyFindsNothingForAMisspelling() throws {
        let archive = try XCTUnwrap(archive)
        _ = try seed(title: "Invoice 2231 paid")

        XCTAssertTrue(try HybridSearch(archive: archive).ftsOnly(SearchQuery(text: "invoyce")).isEmpty)
    }

    // MARK: Private

    private var archive: Archive?

    @discardableResult
    private func seed(
        title: String,
        bundleID: String = Stubs.BundleID.slack,
        appName: String = "Slack",
        isPinned: Bool = false,
        deliveredAt: Date = Stubs.epoch
    ) throws -> Int64 {
        let archive = try XCTUnwrap(archive)
        var app = try archive.upsertApp(bundleID: bundleID, now: deliveredAt)
        if app.displayName != appName {
            app.displayName = appName
            try archive.pool.write { db in try app.update(db) }
        }
        let stored = try archive.insert(ArchivedNotification(
            uuid: UUID().uuidString,
            appId: XCTUnwrap(app.id),
            title: title,
            deliveredAt: UnixDate(deliveredAt),
            capturedAt: UnixDate(deliveredAt),
            isPinned: isPinned
        ))
        return try XCTUnwrap(stored.id)
    }
}
