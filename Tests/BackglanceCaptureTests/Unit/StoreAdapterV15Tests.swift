@testable import BackglanceCapture
import Foundation
import GRDB
import XCTest

/// V15 delegates its reading to the same ``RecordQuery`` as V14, which
/// `StoreAdapterV14Tests` covers in depth. What is worth pinning here is what is actually
/// different: the identity, and that the delegation is in fact wired up.
final class StoreAdapterV15Tests: XCTestCase {
    // MARK: Internal

    func testIdentityMatchesTheCompatibilityTable() {
        XCTAssertEqual(StoreAdapterV15.id, "v15")
        XCTAssertEqual(StoreAdapterV15.supportedOS, 15 ... 15)
    }

    /// Every hash here got in by way of a fixture whose records the suite parses and
    /// checks, so an exact match is something that was verified rather than assumed. An
    /// unfamiliar hash still resolves to nothing, which is what sends the registry down
    /// the probe-guarded fallback instead.
    func testClaimsOnlyFixtureVerifiedHashes() {
        XCTAssertFalse(
            StoreAdapterV15.knownSchemaHashes.isEmpty,
            "the macOS 15 fixture's hash should be registered in KnownFingerprints.json"
        )
        XCTAssertFalse(StoreAdapterV15.matches(Self.sequoiaFingerprint))
    }

    func testReadsTheSameLayoutAsSonoma() throws {
        let queue = try MiniatureStore.make(rows: MiniatureStore.rows(3))

        let (probe, records) = try queue.read { db in
            try (StoreAdapterV15().probe(db), StoreAdapterV15().records(after: StoreCursor(lastRecID: 1), in: db))
        }

        XCTAssertEqual(probe, .ok(recordCount: 3))
        XCTAssertEqual(records.map(\.recID), [2, 3])
        XCTAssertEqual(records.first?.deliveredDate, MiniatureStore.delivered)
    }

    func testCursorForRecordCarriesRecIDAndDeliveryDate() throws {
        let queue = try MiniatureStore.make(rows: MiniatureStore.rows(1))
        let record = try XCTUnwrap(queue.read { try StoreAdapterV15().records(after: .start, in: $0) }.first)

        let cursor = StoreAdapterV15().cursor(for: record)

        XCTAssertEqual(cursor.lastRecID, 1)
        XCTAssertEqual(cursor.lastDeliveredDate, MiniatureStore.delivered)
    }

    // MARK: Private

    private static let sequoiaFingerprint = StoreFingerprint(
        schemaHash: String(repeating: "b", count: 64),
        dbinfoVersion: "15",
        osVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)
    )
}
