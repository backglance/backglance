import Foundation
import GRDB

// MARK: - StoreAdapterV14

/// Reads the notification store as macOS 14 Sonoma keeps it.
///
/// ⚠️ Reads an undocumented Apple database. Every column name below is an observation
/// verified by `Tests/Fixtures/SystemStore/macOS14/`, not an API.
///
/// The oldest adapter and the most stable one: this layout — `dbinfo`, `app`, `record`
/// with a binary-plist `data` column and Cocoa-reference-seconds dates — was already
/// documented publicly for macOS 11 through 13, and every 14.x point release has produced
/// the same schema hash. It is the shape ``RecordQuery`` implements, so this type is
/// identity plus delegation: what the adapter *is*, not how it reads.
///
/// See docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md#macos-14-sonoma--storeadapterv14.
public struct StoreAdapterV14: StoreAdapter {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public static let id = "v14"

    /// 14 only. Sequoia gets its own identity even though it reads identically, so that
    /// "which macOS has been fixture-tested" stays answerable from the adapter list.
    public static let supportedOS: ClosedRange<Int> = 14 ... 14

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

    /// Schema hashes observed on macOS 14 and confirmed by fixture.
    ///
    /// Empty until the macOS 14 fixture exists, which is deliberate rather than pending:
    /// an empty set means ``matches(_:)`` never claims an exact match, so the registry
    /// reaches this adapter through its OS-major fallback and only uses it once
    /// ``probe(_:)`` has confirmed the tables and columns are there. Claiming a hash that
    /// nothing has verified is the failure mode that ships a silent mis-parse; declining
    /// to claim one merely costs a probe.
    ///
    /// Read from the bundled `KnownFingerprints.json` through ``StoreFingerprints``,
    /// which `Scripts/verify_fixture.sh` regenerates from the fixtures.
    static var knownSchemaHashes: Set<String> {
        StoreFingerprints.v14
    }
}
