import Foundation
import GRDB

// MARK: - StoreAdapterV26

/// Reads the notification store as macOS 26 Tahoe keeps it. The primary development
/// target.
///
/// ⚠️ Reads an undocumented Apple database. The layout is an observation verified by
/// `Tests/Fixtures/SystemStore/macOS26/`, not an API.
///
/// Tahoe redesigned Notification Center's interface and left the store's shape alone: the
/// tables and the columns Backglance reads are Sonoma's, so this adapter shares
/// ``RecordQuery`` with ``StoreAdapterV14`` and ``StoreAdapterV15``. `record` carries a
/// few additional columns in 26 that Backglance does not read, and not reading them is
/// deliberate — an adapter that selected `*` would turn every one of Apple's additive
/// changes into a breakage.
///
/// Being the newest adapter gives this type a second job: it is the one the registry
/// reaches for on a macOS newer than anything Backglance has been tested against. That
/// path is guarded by ``probe(_:)`` and reported as a best-effort fallback rather than a
/// match, so a macOS 27 beta either keeps capturing on a store that still looks right or
/// says plainly that it does not recognise it.
///
/// See docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md#macos-26-tahoe--storeadapterv26.
public struct StoreAdapterV26: StoreAdapter {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public static let id = "v26"

    /// 26 only. The newest-adapter fallback is the registry's decision, not a claim this
    /// adapter makes about a macOS nobody has run a fixture against.
    public static let supportedOS: ClosedRange<Int> = 26 ... 26

    public static func matches(_ fingerprint: StoreFingerprint) -> Bool {
        knownSchemaHashes.contains(fingerprint.schemaHash)
    }

    public func probe(_ db: Database) throws -> ProbeResult {
        try RecordQuery.probe(db)
    }

    public func records(after cursor: StoreCursor, in db: Database) throws -> [RawStoreRecord] {
        try RecordQuery.records(after: cursor, in: db)
    }

    public func cursor(for record: RawStoreRecord) -> StoreCursor {
        StoreCursor(lastRecID: record.recID, lastDeliveredDate: record.deliveredDate)
    }

    // MARK: Internal

    /// Schema hashes observed on macOS 26 and confirmed by fixture. Every point release
    /// is a fixture-refresh trigger, so this set is expected to grow.
    ///
    /// Empty until the macOS 26 fixture exists, for the reason given on
    /// ``StoreAdapterV14/knownSchemaHashes``. Populated from the bundled
    /// `KnownFingerprints.json`, which `Scripts/verify_fixture.sh` regenerates from the
    /// fixtures.
    static let knownSchemaHashes: Set<String> = []
}
