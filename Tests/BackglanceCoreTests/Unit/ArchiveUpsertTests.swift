@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

/// The store rewrites rows in place — Messages replaces a conversation's banner, Mail
/// re-delivers an updated summary — so the same notification can arrive more than once,
/// sometimes under a new `rec_id`. These cover which of those become new rows, which
/// refresh an existing one, and what a refresh is not allowed to touch.
final class ArchiveUpsertTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        let archive = try Archive(inMemory: true)
        self.archive = archive
        appID = try XCTUnwrap(archive.upsertApp(bundleID: "com.example.chat", now: Self.delivered).id)
    }

    override func tearDownWithError() throws {
        archive = nil
        appID = nil
        try super.tearDownWithError()
    }

    // MARK: - Inserting

    func testAFirstSightingIsInserted() throws {
        let archive = try XCTUnwrap(archive)

        let outcome = try archive.insertOrUpdate(makeNotification(storeRecID: 1))

        guard case .inserted = outcome else {
            return XCTFail("expected .inserted, got \(outcome)")
        }
        let count = try archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        XCTAssertEqual(count, 1)
    }

    /// The import overlapping live capture, or a crash between the inserts and the cursor
    /// write. Nothing is written, and it is not an error.
    func testTheSameStoreRowSeenTwiceIsADuplicate() throws {
        let archive = try XCTUnwrap(archive)
        try archive.insertOrUpdate(makeNotification(storeRecID: 1))

        let outcome = try archive.insertOrUpdate(makeNotification(storeRecID: 1, uuid: UUID()))

        XCTAssertEqual(outcome, .duplicate)
        let count = try archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        XCTAssertEqual(count, 1)
    }

    // MARK: - Updating

    /// A thread update: a different store row carrying a uuid the archive already has.
    func testANewStoreRowWithAKnownUUIDRefreshesTheExistingOne() throws {
        let archive = try XCTUnwrap(archive)
        let uuid = UUID()
        try archive.insertOrUpdate(makeNotification(storeRecID: 1, uuid: uuid, body: "Landing at six"))

        let outcome = try archive.insertOrUpdate(
            makeNotification(storeRecID: 2, uuid: uuid, body: "Landing at seven")
        )

        guard case .updated = outcome else {
            return XCTFail("expected .updated, got \(outcome)")
        }
        let stored = try XCTUnwrap(archive.pool.read { db in try ArchivedNotification.fetchOne(db) })
        XCTAssertEqual(stored.body, "Landing at seven")
        XCTAssertEqual(stored.storeRecId, 2, "the refreshed row points at the store row that replaced it")
    }

    /// Re-delivered with the same words: nothing new to read, so no badge.
    func testARefreshWithUnchangedTextLeavesTheRowRead() throws {
        let archive = try XCTUnwrap(archive)
        let uuid = UUID()
        let inserted = try archive.insertOrUpdate(makeNotification(storeRecID: 1, uuid: uuid))
        guard case let .inserted(id) = inserted else {
            return XCTFail("expected .inserted")
        }
        try markRead(id)

        try archive.insertOrUpdate(makeNotification(storeRecID: 2, uuid: uuid))

        let stored = try XCTUnwrap(archive.pool.read { db in try ArchivedNotification.fetchOne(db) })
        XCTAssertTrue(stored.isRead)
    }

    func testARefreshWithChangedTextMakesTheRowUnreadAgain() throws {
        let archive = try XCTUnwrap(archive)
        let uuid = UUID()
        let inserted = try archive.insertOrUpdate(makeNotification(storeRecID: 1, uuid: uuid, body: "One message"))
        guard case let .inserted(id) = inserted else {
            return XCTFail("expected .inserted")
        }
        try markRead(id)

        try archive.insertOrUpdate(makeNotification(storeRecID: 2, uuid: uuid, body: "Two messages"))

        let stored = try XCTUnwrap(archive.pool.read { db in try ArchivedNotification.fetchOne(db) })
        XCTAssertFalse(stored.isRead)
    }

    /// A re-delivered banner must not unpin a notification or resurrect a deleted one:
    /// those are the user's decisions, not the store's.
    func testARefreshLeavesTheUsersOwnFlagsAlone() throws {
        let archive = try XCTUnwrap(archive)
        let uuid = UUID()
        let inserted = try archive.insertOrUpdate(makeNotification(storeRecID: 1, uuid: uuid))
        guard case let .inserted(id) = inserted else {
            return XCTFail("expected .inserted")
        }
        try archive.pool.write { db in
            try db.execute(sql: "UPDATE notifications SET is_pinned = 1, is_deleted = 1 WHERE id = ?", arguments: [id])
        }

        try archive.insertOrUpdate(makeNotification(storeRecID: 2, uuid: uuid, body: "Changed"))

        let stored = try XCTUnwrap(archive.pool.read { db in try ArchivedNotification.fetchOne(db) })
        XCTAssertTrue(stored.isPinned)
        XCTAssertTrue(stored.isDeleted)
    }

    /// An update is not a new notification. Counting it would inflate the noisiest-apps
    /// list every time Messages rewrote a thread.
    func testARefreshDoesNotCountAsAnotherNotificationForTheApp() throws {
        let archive = try XCTUnwrap(archive)
        let uuid = UUID()
        try archive.insertOrUpdate(makeNotification(storeRecID: 1, uuid: uuid))

        try archive.insertOrUpdate(makeNotification(storeRecID: 2, uuid: uuid, body: "Changed"))

        let app = try XCTUnwrap(archive.pool.read { db in try AppRecord.fetchOne(db) })
        XCTAssertEqual(app.notificationCount, 1)
    }

    /// The audit row belongs to the insert. Recording one per refresh would claim the
    /// same notification had been redacted again and again.
    func testARedactionIsRecordedOnceForTheInsertOnly() throws {
        let archive = try XCTUnwrap(archive)
        let uuid = UUID()
        let redaction = RedactionEvent(patternId: "otp.keyword.en", redactedAt: UnixDate(Self.delivered))
        try archive.insertOrUpdate(makeNotification(storeRecID: 1, uuid: uuid), redaction: redaction)

        try archive.insertOrUpdate(makeNotification(storeRecID: 2, uuid: uuid, body: "Changed"), redaction: redaction)

        let events = try archive.pool.read { db in try RedactionEvent.fetchAll(db) }
        XCTAssertEqual(events.count, 1)
    }

    // MARK: Private

    private static let delivered = Date(timeIntervalSinceReferenceDate: 774_000_000)

    private var archive: Archive?
    private var appID: Int64?

    private func makeNotification(
        storeRecID: Int64,
        uuid: UUID = UUID(),
        body: String? = "Landing at six"
    ) throws -> ArchivedNotification {
        try ArchivedNotification(
            uuid: uuid.uuidString,
            appId: XCTUnwrap(appID),
            title: "Ada",
            body: body,
            deliveredAt: UnixDate(Self.delivered),
            capturedAt: UnixDate(Self.delivered),
            storeRecId: storeRecID
        )
    }

    private func markRead(_ id: Int64) throws {
        try XCTUnwrap(archive).pool.write { db in
            try db.execute(sql: "UPDATE notifications SET is_read = 1 WHERE id = ?", arguments: [id])
        }
    }
}
