import Foundation
import GRDB

public extension Archive {
    // MARK: - Keys

    /// The bookkeeping the capture pipeline keeps between launches, in
    /// `capture_state`.
    ///
    /// Four rows, no more: the schema is a key/value table precisely so that adding a
    /// piece of capture bookkeeping never needs a migration. See
    /// docs/architecture/DATABASE_SCHEMA.md#capture_state-schema_meta.
    enum CaptureStateKey: String, CaseIterable, Sendable {
        /// JSON of `StoreCursor { lastRecID, lastDeliveredDate }` — how far capture
        /// has read. Written once per batch, *after* that batch's inserts committed,
        /// so a crash mid-batch re-reads records rather than skipping them.
        case cursor

        /// JSON of the last `StoreFingerprint` seen. A change means macOS moved the
        /// store's schema under us and the adapter must be re-resolved.
        case fingerprint

        /// The adapter that last read the store, e.g. `"v26"`.
        case adapterID = "adapter_id"

        /// Unix seconds of the last `importExisting()`, so first-launch import runs
        /// once rather than on every launch.
        case lastImportAt = "last_import_at"
    }

    // MARK: - Raw string access

    /// The stored string for `key`, or `nil` if nothing has been written yet.
    func captureState(_ key: CaptureStateKey) throws -> String? {
        try pool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM capture_state WHERE key = ?",
                arguments: [key.rawValue]
            )
        }
    }

    /// Writes `value` for `key`, replacing whatever was there. Passing `nil` removes
    /// the row, which is how capture resets a cursor rather than writing a sentinel.
    func setCaptureState(_ value: String?, for key: CaptureStateKey) throws {
        try pool.write { db in
            guard let value else {
                try db.execute(sql: "DELETE FROM capture_state WHERE key = ?", arguments: [key.rawValue])
                return
            }
            try db.execute(
                sql: """
                INSERT INTO capture_state(key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [key.rawValue, value]
            )
        }
    }

    // MARK: - JSON access

    /// Decodes the JSON stored for `key`.
    ///
    /// A value that will not decode returns `nil` rather than throwing. The two JSON
    /// keys — the cursor and the fingerprint — are both *resumable* state: losing one
    /// costs a re-read or a re-probe on the next bootstrap, which is a far better
    /// outcome than a launch that fails because a row written by a different build
    /// no longer parses. See docs/features/CAPTURE.md#cursor-persistence.
    ///
    /// This is also why `Archive` is generic over the payload instead of naming the
    /// types: `StoreCursor` and `StoreFingerprint` live in `BackglanceCapture`, which
    /// depends on `BackglanceCore` and not the other way round
    /// (docs/architecture/ARCHITECTURE.md#dependency-graph). To the archive they are
    /// opaque JSON blobs, and `BackglanceCapture` puts the typed accessors on top.
    func captureStateJSON<Value: Decodable>(_ key: CaptureStateKey, as type: Value.Type) throws -> Value? {
        guard let json = try captureState(key) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// Encodes `value` as JSON and stores it for `key`.
    ///
    /// Spelled `…JSON` rather than overloading ``setCaptureState(_:for:)``: `String`
    /// is itself `Encodable`, so the two would form an overload set in which passing a
    /// string resolves to *this* method, which then calls itself with the encoded
    /// string — unbounded recursion that a test caught as a crash rather than a
    /// compile error.
    func setCaptureStateJSON(_ value: some Encodable, for key: CaptureStateKey) throws {
        let data = try JSONEncoder().encode(value)
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw ArchiveError.insertFailed(
                uuid: UUID(),
                underlying: "capture_state.\(key.rawValue): JSON is not UTF-8"
            )
        }
        try setCaptureState(json, for: key)
    }

    // MARK: - Typed conveniences

    /// The adapter id recorded at the last successful bootstrap.
    func adapterID() throws -> String? {
        try captureState(.adapterID)
    }

    func saveAdapterID(_ adapterID: String) throws {
        try setCaptureState(adapterID, for: .adapterID)
    }

    /// When `importExisting()` last completed, or `nil` if it never has — which is
    /// what makes first launch distinguishable from every launch after it.
    ///
    /// Stored as Unix seconds in a text column rather than as JSON, matching
    /// docs/features/CAPTURE.md#cursor-persistence.
    func lastImportDate() throws -> Date? {
        guard
            let raw = try captureState(.lastImportAt),
            let seconds = Double(raw)
        else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    func saveLastImport(_ date: Date) throws {
        try setCaptureState(String(date.timeIntervalSince1970), for: .lastImportAt)
    }
}
