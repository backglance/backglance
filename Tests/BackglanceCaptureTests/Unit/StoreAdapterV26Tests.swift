@testable import BackglanceCapture
import Foundation
import GRDB
import XCTest

/// V26 reads through the same ``RecordQuery`` as V14 and V15, so these cover its identity
/// and the one thing Tahoe actually brought: extra columns on `record` that Backglance
/// does not read and must not trip over.
final class StoreAdapterV26Tests: XCTestCase {
    // MARK: Internal

    func testIdentityMatchesTheCompatibilityTable() {
        XCTAssertEqual(StoreAdapterV26.id, "v26")
        XCTAssertEqual(StoreAdapterV26.supportedOS, 26 ... 26)
    }

    func testClaimsNoExactMatchWithoutAVerifiedHash() {
        XCTAssertTrue(StoreAdapterV26.knownSchemaHashes.isEmpty)
        XCTAssertFalse(StoreAdapterV26.matches(Self.tahoeFingerprint))
    }

    /// Apple's most common change is an additive one. A column Backglance ignores must
    /// leave both the probe and the read exactly as they were.
    func testColumnsBackglanceDoesNotReadAreIgnored() throws {
        let queue = try MiniatureStore.make(
            rows: MiniatureStore.rows(2),
            extraRecordColumns: ["focus_disposition", "delivery_channel"]
        )

        let (probe, records) = try queue.read { db in
            try (StoreAdapterV26().probe(db), StoreAdapterV26().records(after: .start, in: db))
        }

        XCTAssertEqual(probe, .ok(recordCount: 2))
        XCTAssertEqual(records.map(\.recID), [1, 2])
        XCTAssertEqual(records.first?.plistData, Data("payload-1".utf8))
    }

    func testReadsForwardFromTheCursor() throws {
        let queue = try MiniatureStore.make(rows: MiniatureStore.rows(4))

        let records = try queue.read { try StoreAdapterV26().records(after: StoreCursor(lastRecID: 3), in: $0) }

        XCTAssertEqual(records.map(\.recID), [4])
    }

    func testCursorForRecordCarriesRecIDAndDeliveryDate() throws {
        let queue = try MiniatureStore.make(rows: MiniatureStore.rows(1))
        let record = try XCTUnwrap(queue.read { try StoreAdapterV26().records(after: .start, in: $0) }.first)

        let cursor = StoreAdapterV26().cursor(for: record)

        XCTAssertEqual(cursor.lastRecID, 1)
        XCTAssertEqual(cursor.lastDeliveredDate, MiniatureStore.delivered)
    }

    // MARK: Private

    private static let tahoeFingerprint = StoreFingerprint(
        schemaHash: String(repeating: "c", count: 64),
        dbinfoVersion: "26",
        osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0)
    )
}
