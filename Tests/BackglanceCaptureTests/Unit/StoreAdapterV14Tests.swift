@testable import BackglanceCapture
import Foundation
import GRDB
import XCTest

/// V14 is identity plus delegation to ``RecordQuery``, so these cover both: that the
/// adapter declares what it actually supports, and that the shared reader behaves the way
/// the capture loop assumes — forward-only, bounded, and quietly tolerant of the rows a
/// real store contains that a notification is not.
final class StoreAdapterV14Tests: XCTestCase {
    // MARK: Internal

    // MARK: - Identity

    func testIdentityMatchesTheCompatibilityTable() {
        XCTAssertEqual(StoreAdapterV14.id, "v14")
        XCTAssertEqual(StoreAdapterV14.supportedOS, 14 ... 14)
    }

    /// Every hash here got in by way of a fixture whose records the suite parses and
    /// checks, so an exact match is something that was verified rather than assumed. An
    /// unfamiliar hash still resolves to nothing, which is what sends the registry down
    /// the probe-guarded fallback instead.
    func testClaimsOnlyFixtureVerifiedHashes() {
        XCTAssertFalse(
            StoreAdapterV14.knownSchemaHashes.isEmpty,
            "the macOS 14 fixture's hash should be registered in KnownFingerprints.json"
        )
        XCTAssertFalse(StoreAdapterV14.matches(Self.fingerprint(schemaHash: String(repeating: "a", count: 64))))
    }

    // MARK: - Probe

    func testProbeCountsRecordsOnASonomaShapedStore() throws {
        let queue = try MiniatureStore.make(rows: MiniatureStore.rows(3))

        let result = try queue.read { try StoreAdapterV14().probe($0) }

        XCTAssertEqual(result, .ok(recordCount: 3))
    }

    func testProbeReportsEveryMissingTableAtOnce() throws {
        let queue = try MiniatureStore.make(droppingTables: ["record", "app"])

        let result = try queue.read { try StoreAdapterV14().probe($0) }

        XCTAssertEqual(result, .missingTables(["record", "app"]))
    }

    /// The macOS-changed-a-column case. It has to come back as a value the registry can
    /// turn into degraded mode, naming what was actually there for the maintainer.
    func testProbeReportsARenamedColumnWithTheColumnsItFound() throws {
        let queue = try MiniatureStore.make(renamingDeliveredDateTo: "delivered_at")

        let result = try queue.read { try StoreAdapterV14().probe($0) }

        guard case let .unknownSchema(details) = result else {
            return XCTFail("expected .unknownSchema, got \(result.logDescription)")
        }
        XCTAssertTrue(details.hasPrefix("record.delivered_date missing"), details)
        XCTAssertTrue(details.contains("delivered_at"), details)
    }

    // MARK: - Reading

    func testRecordsReadForwardFromTheCursorInRecIDOrder() throws {
        let queue = try MiniatureStore.make(rows: MiniatureStore.rows(5))

        let records = try queue.read { try StoreAdapterV14().records(after: StoreCursor(lastRecID: 2), in: $0) }

        XCTAssertEqual(records.map(\.recID), [3, 4, 5])
        XCTAssertEqual(records.first?.plistData, Data("payload-3".utf8))
        XCTAssertEqual(records.first?.deliveredDate, MiniatureStore.delivered)
        XCTAssertEqual(records.first?.appIdentifier, "app.backglance.Fixture")
    }

    /// A first-launch import faces a store far larger than one batch. The cap is what
    /// keeps that import to steady chunks with a cursor written after each.
    func testABatchIsCappedAtFiveHundredRecords() throws {
        let queue = try MiniatureStore.make(rows: MiniatureStore.rows(600))

        let records = try queue.read { try StoreAdapterV14().records(after: .start, in: $0) }

        XCTAssertEqual(records.count, 500)
        XCTAssertEqual(records.first?.recID, 1)
        XCTAssertEqual(records.last?.recID, 500)
    }

    func testTheStoresSixteenByteUUIDBlobIsDecoded() throws {
        let expected = UUID()
        var row = MiniatureStore.Row(recID: 1)
        row.uuidBlob = Data(expected.rawBytes)
        let queue = try MiniatureStore.make(rows: [row])

        let records = try queue.read { try StoreAdapterV14().records(after: .start, in: $0) }

        XCTAssertEqual(records.first?.uuid, expected)
    }

    /// A blob that is not 16 bytes is not a UUID we can trust. Substituting a generated
    /// one keeps the record archivable; deduplication rests on `store_rec_id` anyway.
    func testAMalformedUUIDBlobFallsBackToAGeneratedUUID() throws {
        var truncated = MiniatureStore.Row(recID: 1)
        truncated.uuidBlob = Data([0x01, 0x02, 0x03])
        var absent = MiniatureStore.Row(recID: 2)
        absent.uuidBlob = nil
        let queue = try MiniatureStore.make(rows: [truncated, absent])

        let records = try queue.read { try StoreAdapterV14().records(after: .start, in: $0) }

        XCTAssertEqual(records.count, 2)
        XCTAssertNotEqual(records[0].uuid, records[1].uuid)
    }

    func testANeverDeliveredRecordKeepsANilDate() throws {
        var scheduled = MiniatureStore.Row(recID: 1)
        scheduled.deliveredDate = nil
        let queue = try MiniatureStore.make(rows: [scheduled])

        let records = try queue.read { try StoreAdapterV14().records(after: .start, in: $0) }

        XCTAssertNil(records.first?.deliveredDate)
    }

    /// The digest calls `presented == false` "you missed this", so an unknown value has
    /// to read as shown — the direction that cannot invent a missed notification.
    func testPresentedIsCarriedThroughAndDefaultsToShown() throws {
        var missed = MiniatureStore.Row(recID: 1)
        missed.presented = false
        var unknown = MiniatureStore.Row(recID: 2)
        unknown.presented = nil
        let queue = try MiniatureStore.make(rows: [missed, unknown])

        let records = try queue.read { try StoreAdapterV14().records(after: .start, in: $0) }

        XCTAssertEqual(records.map(\.presented), [false, true])
    }

    /// Rows with no payload exist in real stores. Archiving one would put an entry with
    /// no content in the timeline; skipping it costs nothing, since the cursor advances
    /// from the rows that were read.
    func testARecordWithNoPayloadIsSkipped() throws {
        var empty = MiniatureStore.Row(recID: 2)
        empty.payload = nil
        let queue = try MiniatureStore.make(rows: [MiniatureStore.Row(recID: 1), empty, MiniatureStore.Row(recID: 3)])

        let records = try queue.read { try StoreAdapterV14().records(after: .start, in: $0) }

        XCTAssertEqual(records.map(\.recID), [1, 3])
    }

    func testReadingAnEmptyStoreYieldsNothingRatherThanFailing() throws {
        let queue = try MiniatureStore.make()

        let records = try queue.read { try StoreAdapterV14().records(after: .start, in: $0) }

        XCTAssertTrue(records.isEmpty)
    }

    // MARK: - Cursor

    func testCursorForRecordCarriesRecIDAndDeliveryDate() throws {
        let queue = try MiniatureStore.make(rows: MiniatureStore.rows(1))
        let record = try XCTUnwrap(queue.read { try StoreAdapterV14().records(after: .start, in: $0) }.first)

        let cursor = StoreAdapterV14().cursor(for: record)

        XCTAssertEqual(cursor.lastRecID, 1)
        XCTAssertEqual(cursor.lastDeliveredDate, MiniatureStore.delivered)
    }

    func testTailRecIDReportsTheHighestRecordAndZeroForAnEmptyStore() throws {
        let populated = try MiniatureStore.make(rows: MiniatureStore.rows(4))
        let empty = try MiniatureStore.make()

        try XCTAssertEqual(populated.read { try RecordQuery.tailRecID(in: $0) }, 4)
        try XCTAssertEqual(empty.read { try RecordQuery.tailRecID(in: $0) }, 0)
    }

    // MARK: Private

    private static func fingerprint(schemaHash: String) -> StoreFingerprint {
        StoreFingerprint(
            schemaHash: schemaHash,
            dbinfoVersion: "14",
            osVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        )
    }
}
