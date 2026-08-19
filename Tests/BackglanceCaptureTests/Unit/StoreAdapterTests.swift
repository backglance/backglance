@testable import BackglanceCapture
import Foundation
import GRDB
import XCTest

// MARK: - StoreAdapterTests

/// The protocol itself has no behaviour to test, so these tests do the next most useful
/// thing: they conform to it the way a real adapter will — against a miniature store
/// built in memory — and pin down the parts that are easy to get wrong later. That the
/// static requirements are reachable through an `any StoreAdapter` is what the registry
/// depends on; that a raw record refuses to print its payload is a privacy invariant.
final class StoreAdapterTests: XCTestCase {
    // MARK: Internal

    // MARK: - Conformance through an existential

    func testStaticRequirementsAreReachableThroughAnExistential() {
        let adapter: any StoreAdapter = StubStoreAdapter()

        XCTAssertEqual(adapter.adapterID, "stub")
        XCTAssertEqual(adapter.supportedOSRange, 14 ... 26)
    }

    func testIsExactMatchForwardsToTheStaticMatcher() {
        let adapter: any StoreAdapter = StubStoreAdapter()

        XCTAssertTrue(adapter.isExactMatch(for: Self.fingerprint(schemaHash: StubStoreAdapter.knownHash)))
        XCTAssertFalse(adapter.isExactMatch(for: Self.fingerprint(schemaHash: String(repeating: "0", count: 64))))
    }

    // MARK: - Probing a snapshot

    func testProbeReportsTheRecordCountOnAWellFormedStore() throws {
        let queue = try Self.miniatureStore(recordCount: 3)

        let result = try queue.read { try StubStoreAdapter().probe($0) }

        XCTAssertEqual(result, .ok(recordCount: 3))
        XCTAssertTrue(result.isUsable)
    }

    /// The case that matters: a store Backglance does not understand must be *reported*,
    /// not thrown and not guessed past.
    func testProbeReportsMissingTablesRatherThanThrowing() throws {
        let queue = try DatabaseQueue()
        try queue.write { try $0.execute(sql: "CREATE TABLE dbinfo (key TEXT, value TEXT)") }

        let result = try queue.read { try StubStoreAdapter().probe($0) }

        XCTAssertEqual(result, .missingTables(["record", "app"]))
        XCTAssertFalse(result.isUsable)
    }

    func testProbeReportsARenamedColumnAsUnknownSchema() throws {
        let queue = try Self.miniatureStore(recordCount: 0, deliveredColumn: "delivered_at")

        let result = try queue.read { try StubStoreAdapter().probe($0) }

        guard case let .unknownSchema(details) = result else {
            return XCTFail("expected .unknownSchema, got \(result.logDescription)")
        }
        XCTAssertTrue(details.contains("delivered_date"), details)
    }

    // MARK: - Reading records

    func testRecordsAfterCursorReadsForwardOnlyAndInRecIDOrder() throws {
        let queue = try Self.miniatureStore(recordCount: 5)

        let records = try queue.read { try StubStoreAdapter().records(after: StoreCursor(lastRecID: 2), in: $0) }

        XCTAssertEqual(records.map(\.recID), [3, 4, 5])
        XCTAssertEqual(records.map(\.appIdentifier), Array(repeating: "app.backglance.Fixture", count: 3))
        XCTAssertEqual(records.first?.plistData, Data("payload-3".utf8))
    }

    func testCursorForRecordCarriesRecIDAndDeliveryDate() throws {
        let queue = try Self.miniatureStore(recordCount: 1)
        let record = try XCTUnwrap(queue.read { try StubStoreAdapter().records(after: .start, in: $0) }.first)

        let cursor = StubStoreAdapter().cursor(for: record)

        XCTAssertEqual(cursor.lastRecID, record.recID)
        XCTAssertEqual(cursor.lastDeliveredDate, record.deliveredDate)
    }

    // MARK: - Content-free descriptions

    /// 🔒 An accidental `"\(record)"` in a log call must print a byte count, never the
    /// payload. The default reflection dump would print the plist bytes.
    func testRawRecordNeverPrintsItsPayload() {
        let record = Self.rawRecord(recID: 42, payload: "secret-verification-code-449021")

        for rendering in ["\(record)", String(describing: record), String(reflecting: record), record.logDescription] {
            XCTAssertFalse(rendering.contains("449021"), rendering)
            XCTAssertTrue(rendering.contains("rec 42"), rendering)
            XCTAssertTrue(rendering.contains("app=app.backglance.Fixture"), rendering)
        }
    }

    func testProbeResultLogDescriptionsAreContentFree() {
        XCTAssertEqual(ProbeResult.ok(recordCount: 7).logDescription, "ok records=7")
        XCTAssertEqual(ProbeResult.permissionDenied.logDescription, "permission denied")
        XCTAssertEqual(ProbeResult.missingTables(["record", "app"]).logDescription, "missing tables: record,app")
        XCTAssertEqual(ProbeResult.unknownSchema(details: "record.uuid missing").logDescription,
                       "unknown schema: record.uuid missing")
    }

    // MARK: Private

    private static let delivered = Date(timeIntervalSinceReferenceDate: 774_000_000)

    private static func fingerprint(schemaHash: String) -> StoreFingerprint {
        StoreFingerprint(
            schemaHash: schemaHash,
            dbinfoVersion: nil,
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        )
    }

    private static func rawRecord(recID: Int64, payload: String) -> RawStoreRecord {
        RawStoreRecord(
            recID: recID,
            appIdentifier: "app.backglance.Fixture",
            uuid: UUID(),
            plistData: Data(payload.utf8),
            deliveredDate: delivered,
            requestDate: nil,
            presented: true,
            style: 0
        )
    }

    /// A store with the shape the adapters read, small enough to assert on exactly.
    /// Synthetic by construction — nothing here comes from a real store.
    private static func miniatureStore(recordCount: Int,
                                       deliveredColumn: String = "delivered_date") throws -> DatabaseQueue
    {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE dbinfo (key TEXT, value TEXT)")
            try db.execute(sql: "CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier TEXT)")
            try db.execute(sql: """
            CREATE TABLE record (
                rec_id INTEGER PRIMARY KEY,
                app_id INTEGER,
                uuid BLOB,
                data BLOB,
                \(deliveredColumn) REAL,
                request_date REAL,
                presented INTEGER,
                style INTEGER
            )
            """)
            try db.execute(sql: "INSERT INTO app (app_id, identifier) VALUES (1, 'app.backglance.Fixture')")
            for index in 0 ..< max(recordCount, 0) {
                let recID = index + 1
                try db.execute(sql: """
                INSERT INTO record (rec_id, app_id, uuid, data, \(deliveredColumn), request_date, presented, style)
                VALUES (?, 1, ?, ?, ?, NULL, 1, 0)
                """, arguments: [
                    recID,
                    Data(UUID().rawBytes),
                    Data("payload-\(recID)".utf8),
                    delivered.timeIntervalSinceReferenceDate,
                ])
            }
        }
        return queue
    }
}

// MARK: - StubStoreAdapter

/// The template adapter from
/// docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md#template-for-a-new-adapter, reduced to
/// what these tests need. It exists to prove the protocol is implementable as specified;
/// the shipping adapters arrive with their own fixtures.
private struct StubStoreAdapter: StoreAdapter {
    static let id = "stub"
    static let supportedOS: ClosedRange<Int> = 14 ... 26
    static let knownHash = String(repeating: "a", count: 64)

    static func matches(_ fingerprint: StoreFingerprint) -> Bool {
        fingerprint.schemaHash == knownHash
    }

    func probe(_ db: Database) throws -> ProbeResult {
        let present = try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        let missing = ["record", "app", "dbinfo"].filter { !present.contains($0) }
        guard missing.isEmpty else {
            return .missingTables(missing)
        }

        let columns = try db.columns(in: "record").map(\.name)
        for needed in ["rec_id", "app_id", "uuid", "data", "delivered_date", "presented"]
            where !columns.contains(needed)
        {
            return .unknownSchema(details: "record.\(needed) missing; columns: \(columns.joined(separator: ","))")
        }
        return try .ok(recordCount: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record") ?? 0)
    }

    func records(after cursor: StoreCursor, in db: Database) throws -> [RawStoreRecord] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT r.rec_id, a.identifier, r.uuid, r.data, r.delivered_date, r.request_date, r.presented, r.style
            FROM record r
            JOIN app a ON a.app_id = r.app_id
            WHERE r.rec_id > ?
            ORDER BY r.rec_id
            LIMIT 500
            """,
            arguments: [cursor.lastRecID]
        )

        return rows.compactMap { row in
            guard let plist: Data = row["data"], let identifier: String = row["identifier"] else {
                return nil
            }
            let delivered: Double? = row["delivered_date"]
            let requested: Double? = row["request_date"]
            return RawStoreRecord(
                recID: row["rec_id"],
                appIdentifier: identifier,
                uuid: UUID(),
                plistData: plist,
                deliveredDate: delivered.map { Date(timeIntervalSinceReferenceDate: $0) },
                requestDate: requested.map { Date(timeIntervalSinceReferenceDate: $0) },
                presented: (row["presented"] as Int64? ?? 1) != 0,
                style: row["style"]
            )
        }
    }

    func cursor(for record: RawStoreRecord) -> StoreCursor {
        StoreCursor(lastRecID: record.recID, lastDeliveredDate: record.deliveredDate)
    }
}

// MARK: - UUID + raw bytes

private extension UUID {
    /// The 16 raw bytes, as the store keeps them.
    var rawBytes: [UInt8] {
        withUnsafeBytes(of: uuid) { Array($0) }
    }
}
