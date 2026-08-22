@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

/// `apps.display_name_key` and `notifications.sender_key`: the folded mirrors that
/// `from:` and `sender:` actually compare against.
///
/// They exist because SQLite's `lower()` folds A–Z and nothing else, so a Swift-folded
/// needle compared against `lower(display_name)` missed every non-ASCII name. The search
/// half of that bug is covered by `NonASCIIFilterTests` in `BackglanceSearchTests`; this
/// is the half that matters here — that the keys are written at all, and stay in step
/// with the text they mirror. A key that goes stale is worse than no key: the search
/// would keep working and quietly return the wrong rows.
///
/// See docs/architecture/DATABASE_SCHEMA.md#match-keys.
final class MatchKeyColumnsTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - Written on the way in

    func testAnInsertedNotificationCarriesItsFoldedSender() throws {
        let archive = try XCTUnwrap(archive)
        let appID = try XCTUnwrap(archive.upsertApp(bundleID: "com.example.chat", now: Self.epoch).id)

        try archive.insert(Self.notification(appID: appID, sender: "AYŞE"))

        XCTAssertEqual(try senderKeys(), ["ayse"])
    }

    func testANotificationWithNoSenderHasNoKey() throws {
        let archive = try XCTUnwrap(archive)
        let appID = try XCTUnwrap(archive.upsertApp(bundleID: "com.example.chat", now: Self.epoch).id)

        try archive.insert(Self.notification(appID: appID, sender: nil))

        XCTAssertEqual(try senderKeys(), [nil])
    }

    func testSettingAnAppsDisplayNameWritesItsFoldedKey() throws {
        let archive = try XCTUnwrap(archive)
        _ = try archive.upsertApp(bundleID: "com.example.bank", now: Self.epoch)

        try archive.setDisplayName("İŞBANK", bundleID: "com.example.bank")

        XCTAssertEqual(try displayNameKeys(), ["isbank"])
    }

    // MARK: - Kept in step

    /// The store rewrites a notification in place when a thread updates, and
    /// ``Archive/insertOrUpdate(_:redaction:)`` copies the new sender over the old one.
    /// The key has to follow, or `sender:` keeps matching the name that is no longer
    /// there.
    func testAThreadUpdateRefreshesTheSenderKey() throws {
        let archive = try XCTUnwrap(archive)
        let appID = try XCTUnwrap(archive.upsertApp(bundleID: "com.example.chat", now: Self.epoch).id)
        let first = Self.notification(appID: appID, sender: "AYŞE")
        try archive.insert(first)

        var updated = first
        updated.sender = "Gökhan"
        _ = try archive.insertOrUpdate(updated)

        XCTAssertEqual(try senderKeys(), ["gokhan"])
    }

    /// A rename, or a user switching their system language. `setDisplayName` writes only
    /// when the name changed, so this also proves the key is not left behind by that
    /// short-circuit.
    func testARenamedAppRefreshesItsKey() throws {
        let archive = try XCTUnwrap(archive)
        _ = try archive.upsertApp(bundleID: "com.example.bank", now: Self.epoch)
        try archive.setDisplayName("İŞBANK", bundleID: "com.example.bank")

        try archive.setDisplayName("Işbank Mobil", bundleID: "com.example.bank")

        XCTAssertEqual(try displayNameKeys(), ["isbank mobil"])
    }

    // MARK: - The backfill

    /// An archive written before v3 has the text but not the keys, and its owner did
    /// nothing to deserve a search that stopped working. The migration folds what is
    /// already there.
    func testTheMigrationFoldsRowsWrittenBeforeTheColumnsExisted() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("bg-backfill-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }

        let queue = try DatabaseQueue(path: path.path)
        var upToV2 = ArchiveMigrations.migrator()
        upToV2.eraseDatabaseOnSchemaChange = false
        try upToV2.migrate(queue, upTo: "v2_embeddings")
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO apps(bundle_id, display_name, first_seen_at, last_seen_at)
                VALUES ('com.example.bank', 'İŞBANK', 0, 0)
                """
            )
            try db.execute(
                sql: """
                INSERT INTO notifications(uuid, app_id, sender, delivered_at, captured_at)
                VALUES ('E6C9D0B2-0000-0000-0000-000000000001', 1, 'AYŞE', 0, 0)
                """
            )
        }
        try queue.close()

        let migrated = try Archive(path: path.path)

        let keys = try migrated.pool.read { db in
            try (
                app: String.fetchOne(db, sql: "SELECT display_name_key FROM apps"),
                sender: String.fetchOne(db, sql: "SELECT sender_key FROM notifications")
            )
        }
        XCTAssertEqual(keys.app, "isbank")
        XCTAssertEqual(keys.sender, "ayse")
    }

    // MARK: Private

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private var archive: Archive?

    private static func notification(appID: Int64, sender: String?) -> ArchivedNotification {
        ArchivedNotification(
            uuid: UUID().uuidString,
            appId: appID,
            title: "Transfer",
            sender: sender,
            deliveredAt: UnixDate(epoch),
            capturedAt: UnixDate(epoch)
        )
    }

    private func senderKeys() throws -> [String?] {
        try XCTUnwrap(archive).pool.read { db in
            try Row.fetchAll(db, sql: "SELECT sender_key FROM notifications").map { $0["sender_key"] as String? }
        }
    }

    private func displayNameKeys() throws -> [String?] {
        try XCTUnwrap(archive).pool.read { db in
            try Row.fetchAll(db, sql: "SELECT display_name_key FROM apps").map { $0["display_name_key"] as String? }
        }
    }
}
