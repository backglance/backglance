@testable import BackglanceCapture
import Foundation
import GRDB
import XCTest

// MARK: - StoreAdapterRegistryTests

/// Resolution is the decision that keeps a mis-parse from ever starting, so these are
/// written as a table of the situations a real Mac produces: the macOS we tested, the
/// point release we did not, the beta that does not exist yet, and the store that is not
/// a notification store at all.
final class StoreAdapterRegistryTests: XCTestCase {
    // MARK: Internal

    // MARK: - Registration

    func testAdaptersAreRegisteredNewestFirst() {
        let ids = StoreAdapterRegistry.adapters.map(\.adapterID)

        XCTAssertEqual(ids, ["v26", "v15", "v14"])
    }

    /// Two adapters claiming the same macOS would make resolution depend on array order
    /// rather than on what was fixture-tested.
    func testNoTwoAdaptersClaimTheSameOSMajor() {
        let claimed = StoreAdapterRegistry.adapters.flatMap { Array($0.supportedOSRange) }

        XCTAssertEqual(claimed.count, Set(claimed).count, "adapters overlap on an OS major: \(claimed)")
    }

    // MARK: - Lookup

    /// Rule one. A hash that a fixture verified is the only outcome used without a probe,
    /// and it wins even when another adapter claims the running macOS.
    func testAnExactFingerprintMatchWinsOverTheOSMajorFallback() {
        let adapters: [any StoreAdapter] = [StubAdapter(), StoreAdapterV26()]

        let resolved = StoreAdapterRegistry.resolve(
            fingerprint: Self.fingerprint(os: 26, schemaHash: StubAdapter.knownHash),
            in: adapters
        )

        XCTAssertEqual(resolved?.adapterID, "stub-v99")
    }

    /// With no hash to match, the same list falls through to the adapter that claims the
    /// running macOS — the fallback the probe then has to confirm.
    func testWithoutAnExactMatchTheOSMajorAdapterIsChosen() {
        let adapters: [any StoreAdapter] = [StubAdapter(), StoreAdapterV26()]

        let resolved = StoreAdapterRegistry.resolve(fingerprint: Self.fingerprint(os: 26), in: adapters)

        XCTAssertEqual(resolved?.adapterID, "v26")
    }

    /// The unfamiliar-hash-on-a-known-macOS case: a point release that changed an index
    /// or bumped `dbinfo`. The adapter for that macOS is the candidate.
    func testAnUnknownHashOnASupportedMacOSFallsBackToThatOSAdapter() {
        XCTAssertEqual(StoreAdapterRegistry.resolve(fingerprint: Self.fingerprint(os: 14))?.adapterID, "v14")
        XCTAssertEqual(StoreAdapterRegistry.resolve(fingerprint: Self.fingerprint(os: 15))?.adapterID, "v15")
        XCTAssertEqual(StoreAdapterRegistry.resolve(fingerprint: Self.fingerprint(os: 26))?.adapterID, "v26")
    }

    /// A macOS newer than anything shipped — the 27 beta case. The newest adapter is the
    /// only reasonable guess, and the probe decides whether it is usable.
    func testAMacOSNewerThanEveryAdapterFallsBackToTheNewestOne() {
        XCTAssertEqual(StoreAdapterRegistry.resolve(fingerprint: Self.fingerprint(os: 27))?.adapterID, "v26")
        XCTAssertEqual(StoreAdapterRegistry.resolve(fingerprint: Self.fingerprint(os: 99))?.adapterID, "v26")
    }

    /// Older than anything Backglance supports. There is no candidate, and inventing one
    /// is exactly the guess this design exists to avoid.
    func testAMacOSOlderThanEveryAdapterResolvesToNothing() {
        XCTAssertNil(StoreAdapterRegistry.resolve(fingerprint: Self.fingerprint(os: 13)))
    }

    /// The lookup is pure: same fingerprint, same answer, no matter how often it is asked.
    func testResolutionIsPureAndRepeatable() {
        let fingerprint = Self.fingerprint(os: 26)

        let first = StoreAdapterRegistry.resolve(fingerprint: fingerprint)?.adapterID
        let second = StoreAdapterRegistry.resolve(fingerprint: fingerprint)?.adapterID

        XCTAssertEqual(first, second)
    }

    // MARK: Private

    private static func fingerprint(os major: Int,
                                    schemaHash: String = String(repeating: "f", count: 64)) -> StoreFingerprint
    {
        StoreFingerprint(
            schemaHash: schemaHash,
            dbinfoVersion: nil,
            osVersion: OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0)
        )
    }
}

// MARK: - StubAdapter

/// An adapter with a hash of its own, for the exact-match rule. Claims a macOS no adapter
/// ships for, so it can only ever be reached by matching its fingerprint.
private struct StubAdapter: StoreAdapter {
    static let id = "stub-v99"
    static let supportedOS: ClosedRange<Int> = 99 ... 99
    static let knownHash = String(repeating: "e", count: 64)

    static func matches(_ fingerprint: StoreFingerprint) -> Bool {
        fingerprint.schemaHash == knownHash
    }

    func probe(_ db: Database) throws -> ProbeResult {
        try RecordQuery.probe(db)
    }

    func records(after cursor: StoreCursor, in db: Database) throws -> [RawStoreRecord] {
        try RecordQuery.records(after: cursor, in: db)
    }

    func cursor(for record: RawStoreRecord) -> StoreCursor {
        StoreCursor(lastRecID: record.recID, lastDeliveredDate: record.deliveredDate)
    }
}
