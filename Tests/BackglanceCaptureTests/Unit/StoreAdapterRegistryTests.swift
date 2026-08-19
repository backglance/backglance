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

    // MARK: - Resolution with a probe

    /// A verified fingerprint plus a clean probe is the only path to ordinary running.
    func testAnExactMatchThatProbesCleanIsMatched() throws {
        let queue = try MiniatureStore.make(rows: MiniatureStore.rows(2))

        let resolution = try queue.read { db in
            StoreAdapterRegistry.resolve(
                fingerprint: Self.fingerprint(os: 26, schemaHash: StubAdapter.knownHash),
                probing: db,
                in: [StubAdapter(), StoreAdapterV26()]
            )
        }

        guard case let .matched(adapter) = resolution else {
            return XCTFail("expected .matched, got \(resolution.logDescription)")
        }
        XCTAssertEqual(adapter.adapterID, "stub-v99")
    }

    /// The macOS-just-updated case: the hash is unfamiliar, the store still reads. Capture
    /// keeps running, and the note is what tells the maintainer to refresh a fixture.
    func testAnUnknownFingerprintOnAReadableStoreIsAProbedFallback() throws {
        let queue = try MiniatureStore.make(rows: MiniatureStore.rows(1))

        let resolution = try queue.read { db in
            StoreAdapterRegistry.resolve(fingerprint: Self.fingerprint(os: 27), probing: db)
        }

        guard case let .fallback(adapter, note) = resolution else {
            return XCTFail("expected .fallback, got \(resolution.logDescription)")
        }
        XCTAssertEqual(adapter.adapterID, "v26")
        XCTAssertTrue(note.contains("ffffffffffff"), note)
        XCTAssertTrue(note.contains("v26"), note)
    }

    /// The case the whole design exists for: a store that is not the shape any adapter
    /// reads stops capture instead of being parsed anyway.
    func testAStoreMissingTheTablesAnAdapterReadsIsDegraded() throws {
        let queue = try MiniatureStore.make(droppingTables: ["record"])
        let fingerprint = Self.fingerprint(os: 26)

        let resolution = try queue.read { db in
            StoreAdapterRegistry.resolve(fingerprint: fingerprint, probing: db)
        }

        XCTAssertEqual(Self.degradedReason(of: resolution), .unknownSchema(fingerprint))
        XCTAssertNil(resolution.adapter)
    }

    func testARenamedColumnIsDegradedRatherThanFallenBackOn() throws {
        let queue = try MiniatureStore.make(renamingDeliveredDateTo: "delivered_at")
        let fingerprint = Self.fingerprint(os: 26)

        let resolution = try queue.read { db in
            StoreAdapterRegistry.resolve(fingerprint: fingerprint, probing: db)
        }

        XCTAssertEqual(Self.degradedReason(of: resolution), .unknownSchema(fingerprint))
    }

    /// Full Disk Access revoked between the snapshot and the read. The user gets the one
    /// message they can act on, not "unrecognised store".
    func testAProbeThatIsDeniedBecomesTheFullDiskAccessState() throws {
        let queue = try MiniatureStore.make()

        let resolution = try queue.read { db in
            StoreAdapterRegistry.resolve(fingerprint: Self.fingerprint(os: 99), probing: db, in: [DeniedAdapter()])
        }

        XCTAssertEqual(Self.degradedReason(of: resolution), .noFullDiskAccess)
    }

    /// An unexpected SQLite failure must not escape: resolution never throws, and the
    /// detail it records is a result code rather than the failing statement.
    func testAProbeThatThrowsBecomesAContentFreeReadError() throws {
        let queue = try MiniatureStore.make()

        let resolution = try queue.read { db in
            StoreAdapterRegistry.resolve(fingerprint: Self.fingerprint(os: 99), probing: db, in: [ThrowingAdapter()])
        }

        guard case let .readError(detail)? = Self.degradedReason(of: resolution) else {
            return XCTFail("expected .readError, got \(resolution.logDescription)")
        }
        XCTAssertEqual(detail, "sqlite 11")
        XCTAssertFalse(detail.contains("SELECT"), detail)
    }

    /// No candidate at all: the probe is never reached, and nothing is read.
    func testAMacOSWithNoCandidateIsDegradedWithoutProbing() throws {
        let queue = try MiniatureStore.make(rows: MiniatureStore.rows(1))
        let fingerprint = Self.fingerprint(os: 13)

        let resolution = try queue.read { db in
            StoreAdapterRegistry.resolve(fingerprint: fingerprint, probing: db)
        }

        XCTAssertEqual(Self.degradedReason(of: resolution), .unknownSchema(fingerprint))
    }

    /// Recognising the fingerprint is not a licence to skip the probe. A store whose hash
    /// was verified once but whose tables are gone now — a store replaced under us, or a
    /// truncated snapshot — still has to degrade.
    func testAnExactMatchWhoseProbeFailsStillDegrades() throws {
        let queue = try MiniatureStore.make(droppingTables: ["record"])
        let fingerprint = Self.fingerprint(os: 26, schemaHash: StubAdapter.knownHash)

        let resolution = try queue.read { db in
            StoreAdapterRegistry.resolve(fingerprint: fingerprint, probing: db, in: [StubAdapter()])
        }

        XCTAssertEqual(Self.degradedReason(of: resolution), .unknownSchema(fingerprint))
    }

    /// An empty adapter list is what a build with every adapter removed would look like.
    /// It resolves to nothing rather than reaching for something.
    func testNoRegisteredAdaptersDegradesWithoutReading() throws {
        let queue = try MiniatureStore.make(rows: MiniatureStore.rows(1))
        let fingerprint = Self.fingerprint(os: 26)

        let resolution = try queue.read { db in
            StoreAdapterRegistry.resolve(fingerprint: fingerprint, probing: db, in: [])
        }

        XCTAssertEqual(Self.degradedReason(of: resolution), .unknownSchema(fingerprint))
    }

    func testTheAdapterToReadWithIsCarriedByMatchedAndFallbackAlike() throws {
        let queue = try MiniatureStore.make(rows: MiniatureStore.rows(1))

        let (matched, fallback) = try queue.read { db in
            (
                StoreAdapterRegistry.resolve(
                    fingerprint: Self.fingerprint(os: 26, schemaHash: StubAdapter.knownHash),
                    probing: db,
                    in: [StubAdapter()]
                ),
                StoreAdapterRegistry.resolve(fingerprint: Self.fingerprint(os: 26), probing: db)
            )
        }

        XCTAssertEqual(matched.adapter?.adapterID, "stub-v99")
        XCTAssertEqual(fallback.adapter?.adapterID, "v26")
    }

    /// 🔒 Resolution is logged on every bootstrap, so its rendering carries adapter ids,
    /// a hash prefix and a fixed reason — never a path, and never anything from a record.
    func testLogDescriptionsNameTheAdapterAndTheReason() throws {
        let queue = try MiniatureStore.make(rows: MiniatureStore.rows(1))
        let degradedFingerprint = Self.fingerprint(os: 13)

        let (fallback, degraded) = try queue.read { db in
            (
                StoreAdapterRegistry.resolve(fingerprint: Self.fingerprint(os: 26), probing: db),
                StoreAdapterRegistry.resolve(fingerprint: degradedFingerprint, probing: db)
            )
        }

        XCTAssertTrue(fallback.logDescription.hasPrefix("fallback v26:"), fallback.logDescription)
        XCTAssertTrue(degraded.logDescription.hasPrefix("degraded: unknown schema"), degraded.logDescription)
        XCTAssertTrue(degraded.logDescription.contains("os=13.0"), degraded.logDescription)
    }

    // MARK: Private

    /// The reason a resolution degraded for, or `nil` if it did not.
    private static func degradedReason(of resolution: StoreAdapterRegistry.Resolution) -> DegradedReason? {
        guard case let .degraded(reason) = resolution else {
            return nil
        }
        return reason
    }

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

// MARK: - DeniedAdapter

/// An adapter whose probe reports that the snapshot cannot be read — Full Disk Access
/// revoked after the copy was taken.
private struct DeniedAdapter: StoreAdapter {
    static let id = "denied"
    static let supportedOS: ClosedRange<Int> = 99 ... 99

    static func matches(_: StoreFingerprint) -> Bool {
        false
    }

    func probe(_: Database) throws -> ProbeResult {
        .permissionDenied
    }

    func records(after _: StoreCursor, in _: Database) throws -> [RawStoreRecord] {
        []
    }

    func cursor(for record: RawStoreRecord) -> StoreCursor {
        StoreCursor(lastRecID: record.recID, lastDeliveredDate: record.deliveredDate)
    }
}

// MARK: - ThrowingAdapter

/// An adapter whose probe fails the way a corrupt snapshot would. The SQL in the error is
/// there so the test can assert it does not reach the degraded reason.
private struct ThrowingAdapter: StoreAdapter {
    static let id = "throwing"
    static let supportedOS: ClosedRange<Int> = 99 ... 99

    static func matches(_: StoreFingerprint) -> Bool {
        false
    }

    func probe(_: Database) throws -> ProbeResult {
        throw DatabaseError(
            resultCode: .SQLITE_CORRUPT,
            message: "database disk image is malformed",
            sql: "SELECT name FROM sqlite_master"
        )
    }

    func records(after _: StoreCursor, in _: Database) throws -> [RawStoreRecord] {
        []
    }

    func cursor(for record: RawStoreRecord) -> StoreCursor {
        StoreCursor(lastRecID: record.recID, lastDeliveredDate: record.deliveredDate)
    }
}
