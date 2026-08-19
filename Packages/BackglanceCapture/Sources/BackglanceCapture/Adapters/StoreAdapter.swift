import Foundation
import GRDB

// MARK: - StoreAdapter

/// One schema family of Apple's notification store.
///
/// ⚠️ Everything behind this protocol reads an undocumented Apple database. The protocol
/// exists so that "which shape of the store are we looking at" is answered once, by
/// ``StoreAdapterRegistry``, and never re-litigated inside a query: an adapter is a
/// straight-line reader for exactly one observed layout. Adding `if osMajor >= 27`
/// branches to an adapter defeats the whole arrangement — write a new adapter instead
/// (docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md#decision-matrix-reuse-previous-adapter-vs-write-new).
///
/// Adapters are stateless `Sendable` value types. Every method runs against the
/// `Database` handle of a read-only ``StoreSnapshot`` — never the live store — so an
/// adapter can be created per tick, and holds nothing across ticks except the cursor its
/// caller persists.
///
/// The split between static and instance members is deliberate. Identity, supported OS
/// range and fingerprint matching are properties of the *schema family*, so the registry
/// can ask them without instantiating anything; reading is an operation on a snapshot, so
/// it is an instance method.
///
/// > 🔒 `probe(_:)` never reads notification content: tables, columns and a `COUNT(*)`
/// > only. `records(after:in:)` carries `record.data` out as opaque ``Data`` and does not
/// > decode it — that is ``RecordParser``'s job, behind the exclusion check.
///
/// See docs/architecture/ARCHITECTURE.md#storeadapter-protocol.
public protocol StoreAdapter: Sendable {
    /// Stable identifier persisted in `capture_state.adapter_id`, e.g. `"v26"`.
    ///
    /// It is written to the archive, so it is an on-disk format: renaming one orphans
    /// every existing install's recorded adapter. Add a new id rather than editing one.
    static var id: String { get }

    /// The macOS major versions this adapter was written and fixture-tested against.
    ///
    /// An honest claim, not a guess: the registry uses it for the OS-major fallback when
    /// a fingerprint is unknown, and Settings ▸ Capture uses it to say whether the
    /// running adapter is a match or a best-effort. Widening a range without a fixture
    /// for the new version is how a silent mis-parse ships.
    static var supportedOS: ClosedRange<Int> { get }

    /// Whether this adapter is an *exact* match for the store that produced `fingerprint`.
    ///
    /// Exact means "this schema hash was observed and fixture-tested", so the
    /// implementation is a set lookup against `KnownFingerprints.json` and nothing
    /// cleverer. A `false` here is not a refusal to run — the registry may still choose
    /// this adapter as an OS-major fallback and confirm it with ``probe(_:)``.
    static func matches(_ fingerprint: StoreFingerprint) -> Bool

    /// A cheap sanity check on a snapshot: are the tables and columns this adapter
    /// queries actually there, and is the snapshot readable at all?
    ///
    /// This is the "probe before trust" step: a fallback adapter is only ever used after
    /// its probe returns ``ProbeResult/ok(recordCount:)``. It must not throw for the
    /// ordinary failures — a missing table and a permission error are results, not
    /// errors — so that the registry can turn them into the right ``DegradedReason``
    /// (docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md#probe--unknownschema--degraded).
    func probe(_ db: Database) throws -> ProbeResult

    /// Records newer than `cursor`, ascending by `rec_id`, in one bounded batch.
    ///
    /// Bounded because a first-launch import may face tens of thousands of rows and the
    /// engine archives a batch at a time; ascending by `rec_id` because that is the only
    /// column observed to increase monotonically — delivery dates in the store are not
    /// ordered. An empty array means "nothing new", which is the common case on a tick.
    func records(after cursor: StoreCursor, in db: Database) throws -> [RawStoreRecord]

    /// The cursor to persist once `record` has been archived.
    ///
    /// The adapter owns this because it owns which store column the cursor's `rec_id`
    /// came from. Callers persist it *after* the batch's inserts commit — see
    /// ``StoreCursor``.
    func cursor(for record: RawStoreRecord) -> StoreCursor
}

// MARK: - Existential conveniences

public extension StoreAdapter {
    /// The concrete type's ``id``, reachable through an `any StoreAdapter`.
    ///
    /// The registry and `CaptureEngine` hold adapters existentially and have to write the
    /// id to `capture_state.adapter_id`; this saves every call site a `type(of:)`.
    var adapterID: String {
        Self.id
    }

    /// The concrete type's ``supportedOS``, reachable through an `any StoreAdapter`.
    var supportedOSRange: ClosedRange<Int> {
        Self.supportedOS
    }

    /// The concrete type's ``matches(_:)``, reachable through an `any StoreAdapter`.
    func isExactMatch(for fingerprint: StoreFingerprint) -> Bool {
        Self.matches(fingerprint)
    }
}

// MARK: - ProbeResult

/// What a ``StoreAdapter/probe(_:)`` found in a snapshot.
///
/// Deliberately a result rather than a thrown error: three of the four cases are things
/// Backglance expects to happen on a macOS it has not been fixture-tested against, and
/// each maps to a different ``DegradedReason``. Collapsing them into one error would lose
/// exactly the distinction the user needs ("grant Full Disk Access" versus "wait for an
/// update that understands this macOS").
///
/// > 🔒 No case carries notification content. ``unknownSchema(details:)`` and
/// > ``missingTables(_:)`` carry *schema* names — Apple's table and column identifiers —
/// > which is what makes them safe to log and to show in the diagnostics export.
public enum ProbeResult: Sendable, Equatable {
    /// The snapshot has everything the adapter reads, and `recordCount` rows in `record`.
    /// The count comes from a `COUNT(*)`; no row's payload was touched.
    case ok(recordCount: Int)

    /// The tables are there but their shape is not what the adapter expects — a renamed
    /// or dropped column, typically. `details` names the columns that were found.
    case unknownSchema(details: String)

    /// The snapshot could not be read at all. In practice this means Full Disk Access was
    /// revoked between taking the snapshot and reading it.
    case permissionDenied

    /// Tables the adapter needs that the store does not have. Empty is not a valid value
    /// here — an adapter with nothing missing returns ``ok(recordCount:)``.
    case missingTables([String])

    // MARK: Public

    /// Whether the adapter may be used against this snapshot.
    public var isUsable: Bool {
        if case .ok = self {
            return true
        }
        return false
    }

    /// Safe for the file log and `os_log` with `privacy: .public`.
    public var logDescription: String {
        switch self {
        case let .ok(recordCount):
            "ok records=\(recordCount)"

        case let .unknownSchema(details):
            "unknown schema: \(details)"

        case .permissionDenied:
            "permission denied"

        case let .missingTables(tables):
            "missing tables: \(tables.joined(separator: ","))"
        }
    }
}
