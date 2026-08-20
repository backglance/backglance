import BackglanceCore
@testable import BackglanceSearch
import BackglanceTestSupport
import XCTest

/// Exercises `FTSIndex` against a real in-memory archive rather than mocks: the
/// behavior under test — `bm25()` weighting, `snippet()` marker placement, the
/// soft-delete predicate — only exists once SQLite's FTS5 extension is actually
/// running the query, so there is no meaningful way to fake it.
///
/// See docs/features/SEARCH.md#fts-ranking-and-highlighting.
final class FTSIndexTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        archive = try Archive(inMemory: true)
        index = FTSIndex(archive: archive)
        appID = try XCTUnwrap(archive.upsertApp(bundleID: Stubs.BundleID.slack, now: Stubs.epoch).id)
    }

    /// A term in the title outranks the same term appearing only in a body: the
    /// whole point of weighting title (3.0) above body (1.0) in
    /// `bm25(notifications_fts, 3.0, 1.5, 1.0, 2.0)`.
    func testTitleOutranksBody() throws {
        let titleHitID = try insert(title: "Fixture deploy finished", body: "Nothing notable here.")
        let bodyHitID = try insert(title: "Fixture unrelated subject", body: "Fixture deploy finished today.")

        let hits = try index.search(match: "\"deploy\" \"finished\"")

        XCTAssertEqual(hits.map(\.notificationID), [titleHitID, bodyHitID])
        // bm25 is a cost: lower is better, so the title hit's score must be smaller.
        XCTAssertLessThan(hits[0].score, hits[1].score)
    }

    /// `prefix = '2 3'` in the FTS5 table makes `"invoi"*` find "invoice" without a
    /// full token.
    func testPrefixMatching() throws {
        let id = try insert(title: "Fixture invoice ready", body: "Fixture message 000042")

        let hits = try index.search(match: "\"invoi\"*")

        XCTAssertEqual(hits.map(\.notificationID), [id])
    }

    /// A quoted phrase only matches the words in that order.
    func testPhraseQuery() throws {
        let matching = try insert(title: "Fixture", body: "the invoice is ready for review")
        _ = try insert(title: "Fixture", body: "ready for review, the invoice arrived late")

        let hits = try index.search(match: "\"invoice is ready\"")

        XCTAssertEqual(hits.map(\.notificationID), [matching])
    }

    /// Restricting to `appIDs` excludes notifications from every other app.
    func testAppFilter() throws {
        let otherAppID = try XCTUnwrap(try archive.upsertApp(bundleID: Stubs.BundleID.mail, now: Stubs.epoch).id)
        let wanted = try insert(title: "Fixture message 000042", body: "Deploy finished", appID: appID)
        _ = try insert(title: "Fixture message 000042", body: "Deploy finished", appID: otherAppID)

        let hits = try index.search(match: "\"deploy\"", appIDs: [appID])

        XCTAssertEqual(hits.map(\.notificationID), [wanted])
    }

    /// A soft-deleted row (`is_deleted = 1`) stays in the FTS index by design
    /// (docs/features/SEARCH.md#the-three-sync-triggers) but every query filters it
    /// out at the SQL layer.
    func testDeletedRowsNeverReturned() throws {
        _ = try insert(title: "Fixture deploy finished", body: "Fixture message 000042", isDeleted: true)

        let hits = try index.search(match: "\"deploy\"")

        XCTAssertTrue(hits.isEmpty)
    }

    /// The snippet carries `FTSIndex.markerOpen`/`markerClose` around the match,
    /// which `MatchHighlighter` later turns into emphasis ranges.
    func testSnippetCarriesMatchMarkers() throws {
        _ = try insert(title: "Fixture", body: "Deploy finished for the fixture pipeline")

        let hits = try index.search(match: "\"deploy\"")

        let snippet = try XCTUnwrap(hits.first?.snippet)
        XCTAssertTrue(snippet.contains(FTSIndex.markerOpen + "Deploy" + FTSIndex.markerClose))
    }

    /// `limit` bounds the rows SQL returns, not just what the caller reads back.
    func testLimitIsRespected() throws {
        for i in 0 ..< 10 {
            _ = try insert(title: "Fixture deploy finished \(i)", body: "Fixture message 000042")
        }

        let hits = try index.search(match: "\"deploy\"", limit: 3)

        XCTAssertEqual(hits.count, 3)
    }

    /// A term present in no row's indexed columns returns no hits, not an error.
    func testUnmatchedTermReturnsNothing() throws {
        _ = try insert(title: "Fixture deploy finished", body: "Fixture message 000042")

        let hits = try index.search(match: "\"nonexistentterm\"")

        XCTAssertTrue(hits.isEmpty)
    }

    /// If `notifications_fts` is ever missing (only reachable mid-migration),
    /// `search` reports it as `SearchError.indexUnavailable` rather than letting a
    /// raw "no such table" `DatabaseError` reach the UI.
    func testMissingIndexThrowsIndexUnavailable() throws {
        _ = try insert(title: "Fixture deploy finished", body: "Fixture message 000042")
        try archive.pool.write { db in
            try db.execute(sql: "DROP TABLE notifications_fts")
        }

        XCTAssertThrowsError(try index.search(match: "\"deploy\"")) { error in
            XCTAssertEqual(error as? SearchError, .indexUnavailable)
        }
    }

    // MARK: Private

    private var archive: Archive!
    private var index: FTSIndex!
    private var appID: Int64!

    @discardableResult
    private func insert(
        title: String,
        body: String,
        appID: Int64? = nil,
        isDeleted: Bool = false
    ) throws -> Int64 {
        let notification = ArchivedNotification(
            uuid: UUID().uuidString,
            appId: appID ?? self.appID,
            title: title,
            body: body,
            deliveredAt: UnixDate(Stubs.date(minutesAgo: 5)),
            capturedAt: UnixDate(Stubs.date(minutesAgo: 5)),
            isDeleted: isDeleted
        )
        let stored = try archive.insert(notification)
        return try XCTUnwrap(stored.id)
    }
}
