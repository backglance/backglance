import Foundation
import GRDB

// MARK: - RecordQuery

/// The SQL that macOS 14, 15 and 26 share, in one place.
///
/// ⚠️ Every identifier here is an observation of an undocumented Apple database, verified
/// by the fixtures under `Tests/Fixtures/SystemStore/`, not an API.
///
/// Those three releases keep the same tables and the same columns Backglance reads; their
/// fingerprints differ only in things Backglance does not query — a `dbinfo` version
/// value, an index definition, columns on `record` that are ignored. Copying the same
/// `SELECT` into three adapters would mean three places to fix a mistake and three
/// chances for them to drift apart, so the adapters keep separate *identities* — separate
/// `id`, `supportedOS` and known hashes, which is what makes the compatibility table
/// honest — and share this reader.
///
/// The moment a macOS renames or reshapes a column Backglance reads, its adapter stops
/// delegating here and gets its own SQL. That is the rule from
/// docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md#decision-matrix-reuse-previous-adapter-vs-write-new:
/// never a version branch inside a query.
enum RecordQuery {
    // MARK: Internal

    /// Tables the reader touches. `dbinfo` is not read for records — it is required
    /// because its absence is the clearest sign that this is not the notification store
    /// at all, which is worth catching in a probe rather than in a `SELECT`.
    static let requiredTables = ["record", "app", "dbinfo"]

    /// Columns of `record` the reader selects. Extra columns are ignored, by design:
    /// Apple adds them without changing anything Backglance depends on.
    static let requiredRecordColumns = ["rec_id", "app_id", "uuid", "data", "delivered_date", "presented"]

    /// Columns of `app` the join needs.
    static let requiredAppColumns = ["app_id", "identifier"]

    /// One batch. Bounded so a first-launch import of a large store archives in steady
    /// chunks — the engine commits and persists a cursor per batch — rather than holding
    /// everything in memory and losing all of it to one failure.
    static let batchSize = 500

    /// Tables, columns, and a `COUNT(*)`, and nothing else.
    ///
    /// > 🔒 No notification content is read here: the probe never touches `record.data`.
    ///
    /// Ordinary failures come back as values rather than errors so that the registry can
    /// map each to the ``DegradedReason`` that tells the user something useful. Only a
    /// genuinely unexpected SQLite failure is rethrown.
    static func probe(_ db: Database) throws -> ProbeResult {
        do {
            let present = try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
            let missing = requiredTables.filter { !present.contains($0) }
            guard missing.isEmpty else {
                return .missingTables(missing)
            }

            if let mismatch = try columnMismatch(db, in: "record", needing: requiredRecordColumns) {
                return mismatch
            }
            if let mismatch = try columnMismatch(db, in: "app", needing: requiredAppColumns) {
                return mismatch
            }

            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record") ?? 0
            return .ok(recordCount: count)
        } catch let error as DatabaseError where error.isPermissionFailure {
            // Full Disk Access revoked between taking the snapshot and reading it.
            return .permissionDenied
        }
    }

    /// Records newer than `cursor`, ascending by `rec_id`, at most ``batchSize`` of them.
    ///
    /// `rec_id` is the only column observed to increase monotonically, so it is both the
    /// sort key and the cursor; delivery dates are not ordered and must never be used to
    /// select a batch.
    ///
    /// Rows without a payload or without a joined app row are dropped rather than
    /// archived with a placeholder: an archive entry with no app and no content would be
    /// a notification the user never saw and cannot act on. The cursor still advances
    /// past them, because the caller advances it from the rows it did get and the next
    /// batch starts after the highest `rec_id` read.
    static func records(after cursor: StoreCursor, in db: Database, limit: Int = batchSize) throws -> [RawStoreRecord] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT r.rec_id, a.identifier, r.uuid, r.data,
                   r.delivered_date, r.request_date, r.presented, r.style
            FROM record r
            JOIN app a ON a.app_id = r.app_id
            WHERE r.rec_id > ?
            ORDER BY r.rec_id
            LIMIT ?
            """,
            arguments: [cursor.lastRecID, limit]
        )

        return rows.compactMap(rawRecord(from:))
    }

    /// The highest `rec_id` in the store, or `0` if it is empty.
    ///
    /// Used to spot a store that was reset under us — see ``StoreCursor/isStale(givenTailRecID:)``.
    static func tailRecID(in db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT MAX(rec_id) FROM record") ?? 0
    }

    // MARK: Private

    /// A row of the join, or `nil` if it is not usable as a record.
    private static func rawRecord(from row: Row) -> RawStoreRecord? {
        guard let plist: Data = row["data"], let identifier: String = row["identifier"] else {
            return nil
        }
        let delivered: Double? = row["delivered_date"]
        let requested: Double? = row["request_date"]
        return RawStoreRecord(
            recID: row["rec_id"],
            appIdentifier: identifier,
            uuid: (row["uuid"] as Data?).flatMap(uuid(fromBlob:)) ?? UUID(),
            plistData: plist,
            deliveredDate: delivered.map { Date(timeIntervalSinceReferenceDate: $0) },
            requestDate: requested.map { Date(timeIntervalSinceReferenceDate: $0) },
            // A NULL `presented` reads as "was shown". The digest's "you missed this"
            // heuristic keys off `presented == false`, so the unknown case has to fall on
            // the side that cannot invent a missed notification.
            presented: (row["presented"] as Int64? ?? 1) != 0,
            style: row["style"]
        )
    }

    /// `.unknownSchema` naming the first required column that is not there, or `nil` if
    /// the table has everything the reader needs.
    private static func columnMismatch(_ db: Database, in table: String, needing: [String]) throws -> ProbeResult? {
        let columns = try db.columns(in: table).map(\.name)
        guard let missing = needing.first(where: { !columns.contains($0) }) else {
            return nil
        }
        return .unknownSchema(details: "\(table).\(missing) missing; columns: \(columns.joined(separator: ","))")
    }

    /// The store keeps `uuid` as 16 raw bytes. Anything else is not a UUID we can trust,
    /// and the caller substitutes a generated one — deduplication rests on `store_rec_id`,
    /// which is the stronger key regardless.
    private static func uuid(fromBlob data: Data) -> UUID? {
        guard data.count == 16 else {
            return nil
        }
        return data.withUnsafeBytes { raw in
            UUID(uuid: raw.loadUnaligned(as: uuid_t.self))
        }
    }
}

// MARK: - DatabaseError + permission failures

extension DatabaseError {
    /// Whether this error is SQLite saying "you may not read this file", which for
    /// Backglance means Full Disk Access is gone rather than that the store is broken.
    var isPermissionFailure: Bool {
        resultCode == .SQLITE_AUTH || resultCode == .SQLITE_CANTOPEN || resultCode == .SQLITE_PERM
    }
}
