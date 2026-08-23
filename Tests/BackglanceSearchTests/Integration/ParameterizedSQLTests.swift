import BackglanceCore
@testable import BackglanceSearch
import BackglanceTestSupport
import Foundation
import GRDB
import XCTest

/// BACKGLANCE-217: proves the parameterized-SQL audit's central claim from the
/// outside — that no value derived from a search field can ever reach SQL as
/// text instead of a bound argument, all the way from `QueryParser` through
/// `FTSIndex` and `HybridSearch+Filters`.
///
/// Every string below is a textbook SQL or FTS5 injection payload, never real
/// search input. A payload matching nothing is the whole test: if `MATCH`,
/// `LIKE`, or an `IN (...)` list were ever built by splicing text into SQL
/// instead of binding it, one of these would either take `notifications` with
/// it or surface as a raw SQLite syntax error the UI has no sentence for.
/// Neither happens, because docs/security/SECURITY.md#parameterized-sql-only
/// is a property GRDB enforces at the call site, not a promise kept by hand.
final class ParameterizedSQLTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    /// The textbook payload, run as free text through the whole hybrid engine.
    /// Had it ever reached SQL unbound, `notifications` would not exist by the
    /// time this method returns.
    func testAClassicInjectionPayloadAsFreeTextMatchesNothingAndLeavesTheSchemaIntact() async throws {
        let archive = try XCTUnwrap(archive)
        _ = try seed(title: "Invoice 2231 paid")

        let hits = try await HybridSearch(archive: archive).search(
            SearchQuery(text: "'; DROP TABLE notifications; --")
        )

        XCTAssertTrue(hits.isEmpty)
        try assertNotificationsTableSurvived(archive, expectedRowCount: 1)
    }

    /// The same payload, this time as the value of `sender:` — the `LIKE`
    /// path, not the `MATCH` path. `AppResolver.escapingWildcards` and the `?`
    /// binding in `HybridSearch+Filters.appendCommonFilters` are what stand
    /// between this and a spliced `WHERE sender_key LIKE '%...%'`.
    func testAnInjectionPayloadAsASenderFilterMatchesNothingAndLeavesTheSchemaIntact() async throws {
        let archive = try XCTUnwrap(archive)
        _ = try seed(title: "Invoice 2231 paid", sender: "Ayşe")

        let hits = try await HybridSearch(archive: archive).search(
            SearchQuery(text: "sender:\"'; DROP TABLE notifications; --\"")
        )

        XCTAssertTrue(hits.isEmpty)
        try assertNotificationsTableSurvived(archive, expectedRowCount: 1)
    }

    /// The `from:` filter goes through `AppResolver`'s own `LIKE` query
    /// (`apps.display_name_key` / `apps.bundle_id`) rather than
    /// `HybridSearch+Filters`'s. Same payload, different statement.
    func testAnInjectionPayloadAsAnAppFilterMatchesNothingAndLeavesTheSchemaIntact() throws {
        let archive = try XCTUnwrap(archive)
        _ = try seed(title: "Invoice 2231 paid")

        let resolved = try AppResolver(archive: archive).resolve(
            QueryParser.parse("from:\"'; DROP TABLE apps; --\"", now: Self.epoch, calendar: .current)
        )

        XCTAssertTrue(resolved.isEmpty)
        try assertNotificationsTableSurvived(archive, expectedRowCount: 1)
    }

    /// FTS5's own metacharacters — quotes, `*`, `:`, `AND`/`OR`/`NOT`, bare
    /// parentheses — are query *syntax*, not SQL, but a user who types them
    /// still has to get a well-formed search back rather than a database
    /// error. `QueryParser.ftsQuote` wraps every free-text token in an
    /// escaped phrase for exactly this reason, which is what turns each of
    /// these into a literal, unmatchable phrase instead of an operator.
    func testFTS5MetacharactersInFreeTextNeverThrowAndNeverMatchAnUnrelatedRow() async throws {
        let archive = try XCTUnwrap(archive)
        _ = try seed(title: "Deploy finished")

        let payloads = [
            "\" OR \"\"=\"",
            "*:AND:OR:NOT*",
            "deploy)) UNION SELECT((",
        ]
        for payload in payloads {
            let hits = try await HybridSearch(archive: archive).search(SearchQuery(text: payload))
            XCTAssertTrue(hits.isEmpty, payload)
        }
        try assertNotificationsTableSurvived(archive, expectedRowCount: 1)
    }

    /// The layer below `QueryParser`: `FTSIndex.search` binds `match` as a
    /// `?` argument no matter what it contains. Even a payload that skips
    /// `QueryParser`'s escaping entirely — the shape a future caller could in
    /// principle hand it directly — can only ever be interpreted as an FTS5
    /// query *string*, never spliced into the surrounding SQL. FTS5 itself
    /// rejects the stray `'` as invalid query syntax, which is the point:
    /// even an unescaped payload only ever reaches SQLite as a bound value to
    /// parse, and the failure mode is an ordinary ``GRDB/DatabaseError`` —
    /// never a statement that runs.
    func testFTSIndexBindsAnUnescapedMatchStringRatherThanSplicingIt() throws {
        let archive = try XCTUnwrap(archive)
        _ = try seed(title: "Deploy finished")

        XCTAssertThrowsError(
            try FTSIndex(archive: archive).search(match: "'; DROP TABLE notifications; --")
        ) { error in
            XCTAssertTrue(error is DatabaseError, "expected an FTS5 query-syntax error, got \(error)")
        }
        try assertNotificationsTableSurvived(archive, expectedRowCount: 1)
    }

    // MARK: Private

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private var archive: Archive?

    @discardableResult
    private func seed(title: String, sender: String? = nil) throws -> Int64 {
        let archive = try XCTUnwrap(archive)
        let app = try archive.upsertApp(bundleID: Stubs.BundleID.slack, now: Self.epoch)
        let stored = try archive.insert(ArchivedNotification(
            uuid: UUID().uuidString,
            appId: XCTUnwrap(app.id),
            title: title,
            sender: sender,
            deliveredAt: UnixDate(Self.epoch),
            capturedAt: UnixDate(Self.epoch)
        ))
        return try XCTUnwrap(stored.id)
    }

    /// Confirms a payload above did nothing but fail to match: `notifications`
    /// is still there, under its own name, holding exactly the rows this test
    /// seeded — not zero (dropped), not more (some other statement ran).
    private func assertNotificationsTableSurvived(_ archive: Archive, expectedRowCount: Int) throws {
        try archive.pool.read { db in
            XCTAssertTrue(try db.tableExists("notifications"))
            XCTAssertTrue(try db.tableExists("apps"))
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notifications") ?? -1
            XCTAssertEqual(count, expectedRowCount)
        }
    }
}
