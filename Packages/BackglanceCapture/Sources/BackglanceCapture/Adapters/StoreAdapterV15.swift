import Foundation
import GRDB

// MARK: - StoreAdapterV15

/// Reads the notification store as macOS 15 Sequoia keeps it.
///
/// ⚠️ Reads an undocumented Apple database. The layout is an observation verified by
/// `Tests/Fixtures/SystemStore/macOS15/`, not an API.
///
/// Sequoia's store has the same tables and the same columns Backglance reads as Sonoma's;
/// its fingerprint differs only in the `dbinfo` version value and one index definition —
/// neither of which this adapter queries. It therefore shares ``RecordQuery`` with
/// ``StoreAdapterV14`` and differs only in identity.
///
/// The identities stay separate on purpose. `supportedOS` is a claim about what has been
/// fixture-tested, and the public compatibility table is built from those claims; folding
/// 15 into V14 would make the table say something nobody verified. It also keeps the
/// upgrade path honest — if 15.6 reshapes a column Backglance reads, this file grows its
/// own SQL and V14 is untouched.
///
/// See docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md#macos-15-sequoia--storeadapterv15.
public struct StoreAdapterV15: StoreAdapter {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public static let id = "v15"

    public static let supportedOS: ClosedRange<Int> = 15 ... 15

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

    /// Schema hashes observed on macOS 15 and confirmed by fixture.
    ///
    /// This is the adapter that will carry more than one: 15.4 bumped the `dbinfo` value
    /// without touching the DDL, which the playbook's decision matrix calls a
    /// fingerprint-only change — a new hash on the existing adapter, no Swift change.
    /// Empty until the macOS 15 fixture exists, for the reason given on
    /// ``StoreAdapterV14/knownSchemaHashes``: an unverified hash is a silent mis-parse
    /// waiting to happen, while no hash merely costs a probe.
    ///
    /// Populated from the bundled `KnownFingerprints.json`, which
    /// `Scripts/verify_fixture.sh` regenerates from the fixtures.
    static let knownSchemaHashes: Set<String> = []
}
