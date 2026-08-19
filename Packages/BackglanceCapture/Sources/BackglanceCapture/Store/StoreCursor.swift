import BackglanceCore
import Foundation

// MARK: - StoreCursor

/// How far capture has read into Apple's store.
///
/// Persisted as JSON in `capture_state.cursor` and written **once per batch, after that
/// batch's inserts have committed**. The ordering is the whole design: a crash between
/// the inserts and the cursor write re-reads records that were already archived, and the
/// unique index on `notifications.store_rec_id` turns each of those re-inserts into a
/// no-op. Writing the cursor first would instead skip them permanently. Losing
/// notifications is the failure that matters here; re-reading a few is not.
///
/// See docs/features/CAPTURE.md#cursor-persistence.
public struct StoreCursor: Codable, Hashable, Sendable {
    // MARK: Lifecycle

    public init(lastRecID: Int64 = 0, lastDeliveredDate: Date? = nil) {
        self.lastRecID = lastRecID
        self.lastDeliveredDate = lastDeliveredDate
    }

    // MARK: Public

    /// A cursor that has read nothing. Where a first-launch import starts, and where a
    /// store that has plainly been replaced resets to.
    public static let start = StoreCursor()

    /// The `rec_id` of the last record read. This is the actual measure of progress:
    /// the next batch asks for `rec_id > lastRecID`.
    public let lastRecID: Int64

    /// When that record was delivered, if it is known.
    ///
    /// Informational — Settings shows it as "last notification seen at" — and an input
    /// to the store-reset heuristic. Never the thing a batch is selected by: dates in
    /// the store are not monotonic the way `rec_id` is.
    public let lastDeliveredDate: Date?

    /// The cursor after reading a record.
    public func advanced(toRecID recID: Int64, deliveredAt date: Date?) -> StoreCursor {
        StoreCursor(lastRecID: recID, lastDeliveredDate: date ?? lastDeliveredDate)
    }

    /// Whether `tailRecID` — the highest `rec_id` currently in the store — means the
    /// store was reset under us.
    ///
    /// `rec_id` only ever climbs while a store lives, so a tail *below* the cursor means
    /// the store is not the one this cursor was taken from: the user reset the Mac's
    /// notification database, or macOS replaced it. Resuming from the old cursor would
    /// skip everything in the new store, quite possibly forever. Resetting re-reads what
    /// is there, and `store_rec_id` deduplication absorbs any genuine overlap.
    public func isStale(givenTailRecID tailRecID: Int64) -> Bool {
        tailRecID < lastRecID
    }
}

// MARK: - Archive + cursor persistence

public extension Archive {
    /// The persisted cursor, or `nil` if capture has never recorded one.
    ///
    /// A cursor that will not decode also reads as `nil`, by way of
    /// ``BackglanceCore/Archive/captureStateJSON(_:as:)``. That is deliberate: it is
    /// resumable state, so a row written by some other build costs a re-read on the next
    /// bootstrap rather than a launch failure.
    func loadCursor() throws -> StoreCursor? {
        try captureStateJSON(.cursor, as: StoreCursor.self)
    }

    /// Records how far capture has read. Call after the batch's inserts have committed.
    func saveCursor(_ cursor: StoreCursor) throws {
        try setCaptureStateJSON(cursor, for: .cursor)
    }

    /// Forgets the cursor, so the next bootstrap starts fresh.
    ///
    /// Removes the row rather than writing ``StoreCursor/start``: "never read anything"
    /// and "read up to rec_id 0" are different states, and only the row's absence says
    /// the first one.
    func clearCursor() throws {
        try setCaptureState(nil, for: .cursor)
    }

    /// The fingerprint recorded at the last successful bootstrap.
    ///
    /// Lives here with the cursor for the same reason: `StoreFingerprint` is a
    /// `BackglanceCapture` type, and `BackglanceCore` must not know about it
    /// (docs/architecture/ARCHITECTURE.md#dependency-graph). The archive stores an
    /// opaque JSON blob; the typed accessor belongs on this side of the boundary.
    func loadFingerprint() throws -> StoreFingerprint? {
        try captureStateJSON(.fingerprint, as: StoreFingerprint.self)
    }

    func saveFingerprint(_ fingerprint: StoreFingerprint) throws {
        try setCaptureStateJSON(fingerprint, for: .fingerprint)
    }
}
