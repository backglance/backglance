import Foundation
import GRDB

// MARK: - MiniatureStore

/// An in-memory database shaped like Apple's notification store, small enough to assert
/// on exactly.
///
/// 🔒 Synthetic by construction: every value here is written by the test that asks for it.
/// Nothing reads `~/Library`, and no bytes from a real store are involved. The checked-in
/// fixtures under `Tests/Fixtures/SystemStore/` are the full-size counterpart — this is
/// for tests that want three rows and one deliberate deformity.
///
/// The schema mirrors the macOS 14 layout recorded in
/// docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md, including the columns Backglance
/// ignores, so that "the adapter ignores what it does not need" is actually exercised.
enum MiniatureStore {
    // MARK: Internal

    // MARK: - Rows

    struct Row {
        // MARK: Lifecycle

        init(recID: Int64) {
            self.recID = recID
        }

        // MARK: Internal

        var recID: Int64
        var bundleID = "app.backglance.Fixture"
        var payload: Data? = Data("payload".utf8)
        var uuidBlob: Data? = Data(UUID().rawBytes)
        var deliveredDate: Date? = MiniatureStore.delivered
        var requestDate: Date?
        var presented: Bool? = true
        var style: Int? = 0
    }

    /// A fixed instant, so date assertions do not depend on when the test runs.
    static let delivered = Date(timeIntervalSinceReferenceDate: 774_000_000)

    /// A binary plist shaped like the ones the store carries.
    ///
    /// ⚠️ The keys are the observed ones. Synthetic content only — every value here is
    /// written by the test that asks for it.
    static func payload(
        bundleID: String? = nil,
        title: String? = "Ada",
        subtitle: String? = nil,
        body: String? = "Landing at six",
        threadID: String? = nil,
        attachments: [[String: Any]] = []
    ) -> Data {
        var request: [String: Any] = [:]
        request["titl"] = title
        request["subt"] = subtitle
        request["body"] = body
        request["thre"] = threadID
        if !attachments.isEmpty {
            request["atta"] = attachments
        }

        var root: [String: Any] = ["req": request]
        root["app"] = bundleID

        // swiftlint:disable:next force_try - a dictionary of plist scalars always encodes
        return try! PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    /// A row whose payload is a real notification, rather than opaque bytes.
    static func notification(
        recID: Int64,
        bundleID: String = "app.backglance.Fixture",
        payloadBundleID: String? = nil,
        title: String? = "Ada",
        body: String? = "Landing at six"
    ) -> Row {
        var row = Row(recID: recID)
        row.bundleID = bundleID
        row.payload = payload(bundleID: payloadBundleID, title: title, body: body)
        return row
    }

    /// `count` rows numbered from 1, each with a distinct payload.
    static func rows(_ count: Int) -> [Row] {
        (1 ... count).map { recID in
            var row = Row(recID: Int64(recID))
            row.payload = Data("payload-\(recID)".utf8)
            return row
        }
    }

    /// A store containing `rows`.
    ///
    /// - Parameters:
    ///   - droppingTables: tables to leave out entirely, for probe tests.
    ///   - renamingDeliveredDateTo: renames `record.delivered_date`, which is the shape a
    ///     future macOS taking a column away would have.
    ///   - extraRecordColumns: columns on `record` that Backglance does not read. macOS
    ///     26 has several; adding one is Apple's most common change, and it must be a
    ///     non-event.
    static func make(
        rows: [Row] = [],
        droppingTables: Set<String> = [],
        renamingDeliveredDateTo deliveredColumn: String = "delivered_date",
        extraRecordColumns: [String] = []
    ) throws -> DatabaseQueue {
        try make(
            queue: DatabaseQueue(),
            rows: rows,
            droppingTables: droppingTables,
            renamingDeliveredDateTo: deliveredColumn,
            extraRecordColumns: extraRecordColumns
        )
    }

    /// The same store, as a file on disk.
    ///
    /// `CaptureEngine` reads through ``StoreSnapshot``, which copies `db` and `-wal`
    /// before opening anything, so its tests need a real file rather than an in-memory
    /// database.
    @discardableResult
    static func makeFile(
        at url: URL,
        rows: [Row] = [],
        droppingTables: Set<String> = [],
        renamingDeliveredDateTo deliveredColumn: String = "delivered_date"
    ) throws -> DatabaseQueue {
        try make(
            queue: DatabaseQueue(path: url.path),
            rows: rows,
            droppingTables: droppingTables,
            renamingDeliveredDateTo: deliveredColumn,
            extraRecordColumns: []
        )
    }

    /// Adds rows to a store that already exists — notifications arriving over time,
    /// which is what a tick is supposed to pick up.
    static func append(_ rows: [Row], to url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try insert(rows, deliveredColumn: "delivered_date", into: db)
        }
    }

    // MARK: Private

    private static func make(
        queue: DatabaseQueue,
        rows: [Row],
        droppingTables: Set<String>,
        renamingDeliveredDateTo deliveredColumn: String,
        extraRecordColumns: [String]
    ) throws -> DatabaseQueue {
        try queue.write { db in
            if !droppingTables.contains("dbinfo") {
                try db.execute(sql: "CREATE TABLE dbinfo (key TEXT PRIMARY KEY, value)")
                try db.execute(sql: "INSERT INTO dbinfo (key, value) VALUES ('compatibleVersion', '14')")
            }
            if !droppingTables.contains("app") {
                try db.execute(sql: "CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier TEXT, badge INTEGER)")
            }
            if !droppingTables.contains("record") {
                try db.execute(sql: """
                CREATE TABLE record (
                    rec_id INTEGER PRIMARY KEY,
                    app_id INTEGER,
                    uuid BLOB,
                    data BLOB,
                    request_date REAL,
                    request_last_date REAL,
                    \(deliveredColumn) REAL,
                    presented INTEGER,
                    style INTEGER,
                    snooze_fire_date REAL\(extraRecordColumns.map { ",\n                    \($0) TEXT" }.joined())
                )
                """)
            }
            guard !droppingTables.contains("record"), !droppingTables.contains("app") else {
                return
            }
            try insert(rows, deliveredColumn: deliveredColumn, into: db)
        }
        return queue
    }

    private static func insert(_ rows: [Row], deliveredColumn: String, into db: Database) throws {
        var appIDs: [String: Int64] = [:]
        for row in rows {
            let appID: Int64
            if let existing = appIDs[row.bundleID] {
                appID = existing
            } else {
                appID = Int64(appIDs.count + 1)
                appIDs[row.bundleID] = appID
                try db.execute(
                    sql: "INSERT OR IGNORE INTO app (app_id, identifier, badge) VALUES (?, ?, 0)",
                    arguments: [appID, row.bundleID]
                )
            }
            try db.execute(
                sql: """
                INSERT INTO record (rec_id, app_id, uuid, data, request_date, \(deliveredColumn), presented, style)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    row.recID,
                    appID,
                    row.uuidBlob,
                    row.payload,
                    row.requestDate?.timeIntervalSinceReferenceDate,
                    row.deliveredDate?.timeIntervalSinceReferenceDate,
                    row.presented.map { $0 ? 1 : 0 },
                    row.style,
                ]
            )
        }
    }
}

// MARK: - UUID + raw bytes

extension UUID {
    /// The 16 raw bytes, as the store keeps them.
    var rawBytes: [UInt8] {
        withUnsafeBytes(of: uuid) { Array($0) }
    }
}
