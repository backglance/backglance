@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

/// Timestamps here are fixed whole seconds. `Date()` carries sub-microsecond
/// precision that does not reliably survive the trip through
/// `timeIntervalSince1970` and back, which makes exact-equality assertions after a
/// round trip flaky — see the note in `AssociationsTests`.
final class ArchiveInsertTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - upsertApp

    func testUpsertAppCreatesTheRowOnFirstSight() throws {
        let app = try archive.upsertApp(bundleID: "com.example.demo", now: now)

        XCTAssertNotNil(app.id)
        XCTAssertEqual(app.bundleId, "com.example.demo")
        XCTAssertEqual(app.notificationCount, 0)
        XCTAssertEqual(app.retention, .inherit)
    }

    func testUpsertAppReturnsTheSameRowOnSecondSight() throws {
        let first = try archive.upsertApp(bundleID: "com.example.demo", now: now)
        let second = try archive.upsertApp(bundleID: "com.example.demo", now: now.addingTimeInterval(60))

        XCTAssertEqual(first.id, second.id)
        let rows = try archive.pool.read { db in try AppRecord.fetchCount(db) }
        XCTAssertEqual(rows, 1)
    }

    /// An existing row's retention is the user's setting. Capture sees the app again
    /// on every notification, so overwriting here would silently undo a choice.
    func testUpsertAppDoesNotOverwriteRetentionOnAnExistingRow() throws {
        var app = try archive.upsertApp(bundleID: "com.example.demo", now: now)
        app.retention = .policy(.days7)
        try archive.pool.write { db in try app.update(db) }

        let again = try archive.upsertApp(bundleID: "com.example.demo", now: now, retention: .policy(.hours24))

        XCTAssertEqual(again.retention, .policy(.days7))
    }

    func testUpsertAppEnablesOTPRedactionForMessagesAndMail() throws {
        XCTAssertTrue(try archive.upsertApp(bundleID: "com.apple.MobileSMS", now: now).redactOtp)
        XCTAssertTrue(try archive.upsertApp(bundleID: "com.apple.mail", now: now).redactOtp)
        XCTAssertFalse(try archive.upsertApp(bundleID: "com.example.demo", now: now).redactOtp)
    }

    // MARK: - insert

    func testInsertStoresTheNotificationAndReturnsItsID() throws {
        let app = try archive.upsertApp(bundleID: "com.example.demo", now: now)
        let stored = try archive.insert(makeNotification(appID: XCTUnwrap(app.id)))

        XCTAssertNotNil(stored.id)
        XCTAssertEqual(try archive.pool.read { db in try ArchivedNotification.fetchCount(db) }, 1)
    }

    func testInsertUpdatesTheOwningAppsBookkeeping() throws {
        let app = try archive.upsertApp(bundleID: "com.example.demo", now: now)
        let appID = try XCTUnwrap(app.id)

        try archive.insert(makeNotification(appID: appID, uuid: uuidA, deliveredAt: now))
        try archive.insert(makeNotification(appID: appID, uuid: uuidB, deliveredAt: now.addingTimeInterval(600)))

        let reloaded = try XCTUnwrap(archive.pool.read { db in try AppRecord.fetchOne(db, key: appID) })
        XCTAssertEqual(reloaded.notificationCount, 2)
        XCTAssertEqual(reloaded.lastSeenAt.date.timeIntervalSince1970, now.timeIntervalSince1970 + 600)
    }

    /// Import walks the store in `rec_id` order, which is not delivery order, so the
    /// seen-at window has to widen rather than track whichever row landed last.
    func testInsertingAnOlderNotificationDoesNotMoveLastSeenBackwards() throws {
        let app = try archive.upsertApp(bundleID: "com.example.demo", now: now)
        let appID = try XCTUnwrap(app.id)

        try archive.insert(makeNotification(appID: appID, uuid: uuidA, deliveredAt: now))
        try archive.insert(makeNotification(appID: appID, uuid: uuidB, deliveredAt: now.addingTimeInterval(-oneHour)))

        let reloaded = try XCTUnwrap(archive.pool.read { db in try AppRecord.fetchOne(db, key: appID) })
        XCTAssertEqual(reloaded.lastSeenAt.date.timeIntervalSince1970, now.timeIntervalSince1970)
        XCTAssertEqual(reloaded.firstSeenAt.date.timeIntervalSince1970, now.timeIntervalSince1970 - oneHour)
    }

    // MARK: - Duplicates

    func testInsertingTheSameUUIDTwiceThrowsDuplicate() throws {
        let appID = try XCTUnwrap(archive.upsertApp(bundleID: "com.example.demo", now: now).id)
        try archive.insert(makeNotification(appID: appID, uuid: uuidA, storeRecID: 1))

        XCTAssertThrowsError(
            try archive.insert(makeNotification(appID: appID, uuid: uuidA, storeRecID: 2))
        ) { error in
            guard case ArchiveError.duplicate = error else {
                return XCTFail("expected ArchiveError.duplicate, got \(error)")
            }
        }
    }

    func testInsertingTheSameStoreRecIDTwiceThrowsDuplicate() throws {
        let appID = try XCTUnwrap(archive.upsertApp(bundleID: "com.example.demo", now: now).id)
        try archive.insert(makeNotification(appID: appID, uuid: uuidA, storeRecID: 424))

        XCTAssertThrowsError(
            try archive.insert(makeNotification(appID: appID, uuid: uuidB, storeRecID: 424))
        ) { error in
            guard case ArchiveError.duplicate = error else {
                return XCTFail("expected ArchiveError.duplicate, got \(error)")
            }
        }
    }

    /// `store_rec_id` is unique only *where present*, so rows without one — a record
    /// the store never gave an id — must not collide with each other.
    func testNullStoreRecIDsDoNotCollide() throws {
        let appID = try XCTUnwrap(archive.upsertApp(bundleID: "com.example.demo", now: now).id)

        try archive.insert(makeNotification(appID: appID, uuid: uuidA, storeRecID: nil))
        try archive.insert(makeNotification(appID: appID, uuid: uuidB, storeRecID: nil))

        XCTAssertEqual(try archive.pool.read { db in try ArchivedNotification.fetchCount(db) }, 2)
    }

    /// A duplicate must leave nothing behind: the count, the app bookkeeping and the
    /// FTS index all have to look exactly as they did before the attempt.
    func testARejectedDuplicateLeavesNoTrace() throws {
        let appID = try XCTUnwrap(archive.upsertApp(bundleID: "com.example.demo", now: now).id)
        try archive.insert(makeNotification(appID: appID, uuid: uuidA, storeRecID: 7))

        XCTAssertThrowsError(try archive.insert(makeNotification(appID: appID, uuid: uuidA, storeRecID: 7)))

        let (notifications, indexed, count) = try archive.pool.read { db in
            try (
                ArchivedNotification.fetchCount(db),
                Int.fetchOne(db, sql: "SELECT count(*) FROM notifications_fts") ?? -1,
                AppRecord.fetchOne(db, key: appID)?.notificationCount ?? -1
            )
        }
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(indexed, 1)
        XCTAssertEqual(count, 1, "the rejected insert must not have bumped the app's count")
    }

    /// A foreign-key failure is a caller bug. Folding it into `.duplicate` would hide
    /// it, because `.duplicate` is the one error the capture pipeline swallows.
    func testAForeignKeyFailureIsNotReportedAsDuplicate() throws {
        XCTAssertThrowsError(try archive.insert(makeNotification(appID: unknownAppID))) { error in
            if case ArchiveError.duplicate = error {
                XCTFail("a foreign-key failure must not be reported as a duplicate")
            }
        }
    }

    // MARK: - Redaction audit row

    func testInsertWritesTheRedactionAuditRowAndLinksIt() throws {
        let appID = try XCTUnwrap(archive.upsertApp(bundleID: "com.apple.MobileSMS", now: now).id)
        var notification = makeNotification(appID: appID)
        notification.redaction = .otp

        let stored = try archive.insert(
            notification,
            redaction: RedactionEvent(
                id: nil,
                notificationId: 0, // filled in by insert
                kind: .otp,
                patternId: "otp.keyword.en",
                redactedAt: UnixDate(now)
            )
        )

        let events = try archive.pool.read { db in try RedactionEvent.fetchAll(db) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.notificationId, stored.id)
        XCTAssertEqual(events.first?.patternId, "otp.keyword.en")
    }

    func testInsertWithoutRedactionWritesNoAuditRow() throws {
        let appID = try XCTUnwrap(archive.upsertApp(bundleID: "com.example.demo", now: now).id)
        try archive.insert(makeNotification(appID: appID))

        XCTAssertEqual(try archive.pool.read { db in try RedactionEvent.fetchCount(db) }, 0)
    }

    // MARK: - Search wiring

    func testAnInsertedNotificationIsImmediatelyFindable() throws {
        let appID = try XCTUnwrap(archive.upsertApp(bundleID: "com.example.demo", now: now).id)
        var notification = makeNotification(appID: appID)
        notification.title = "quarterly invoice"
        try archive.insert(notification)

        let hits = try archive.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM notifications_fts WHERE notifications_fts MATCH 'invoice'")
        }
        XCTAssertEqual(hits, 1)
    }

    // MARK: - repairCounts

    /// The happy path has nothing to do, and has to say so rather than rewriting every
    /// row: a repair that always reports work done is a repair nobody can trust.
    func testRepairCountsLeavesCorrectCountsAlone() throws {
        let archive = try XCTUnwrap(archive)
        let appID = try XCTUnwrap(archive.upsertApp(bundleID: "com.example.chat", now: now).id)
        try archive.insert(makeNotification(appID: appID, uuid: uuidA))
        try archive.insert(makeNotification(appID: appID, uuid: uuidB))

        let repaired = try archive.repairCounts()

        XCTAssertEqual(repaired, 0)
        let count = try archive.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT notification_count FROM apps WHERE id = ?", arguments: [appID])
        }
        XCTAssertEqual(count, 2)
    }

    /// Drift is the whole reason the method exists, so it is induced directly: the
    /// counter is denormalized, and an interrupted prune or a restored archive file can
    /// leave it disagreeing with the rows it counts.
    func testRepairCountsRecomputesADriftedCount() throws {
        let archive = try XCTUnwrap(archive)
        let appID = try XCTUnwrap(archive.upsertApp(bundleID: "com.example.chat", now: now).id)
        try archive.insert(makeNotification(appID: appID, uuid: uuidA))
        try archive.insert(makeNotification(appID: appID, uuid: uuidB))
        try archive.pool.write { db in
            try db.execute(sql: "UPDATE apps SET notification_count = 47 WHERE id = ?", arguments: [appID])
        }

        let repaired = try archive.repairCounts()

        XCTAssertEqual(repaired, 1)
        let count = try archive.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT notification_count FROM apps WHERE id = ?", arguments: [appID])
        }
        XCTAssertEqual(count, 2)
    }

    /// Soft-deleted rows are not in the timeline, so they are not in the count either —
    /// the repair has to agree with what the insert path counts.
    func testRepairCountsExcludesSoftDeletedRows() throws {
        let archive = try XCTUnwrap(archive)
        let appID = try XCTUnwrap(archive.upsertApp(bundleID: "com.example.chat", now: now).id)
        try archive.insert(makeNotification(appID: appID, uuid: uuidA))
        try archive.insert(makeNotification(appID: appID, uuid: uuidB))
        try archive.pool.write { db in
            try db.execute(sql: "UPDATE notifications SET is_deleted = 1 WHERE uuid = ?", arguments: [self.uuidB])
        }

        try archive.repairCounts()

        let count = try archive.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT notification_count FROM apps WHERE id = ?", arguments: [appID])
        }
        XCTAssertEqual(count, 1)
    }

    /// An app whose notifications have all been pruned keeps its row — it carries the
    /// user's per-app settings — and its count has to fall to zero rather than stick.
    func testRepairCountsZeroesAnAppWithNoNotificationsLeft() throws {
        let archive = try XCTUnwrap(archive)
        let appID = try XCTUnwrap(archive.upsertApp(bundleID: "com.example.chat", now: now).id)
        try archive.pool.write { db in
            try db.execute(sql: "UPDATE apps SET notification_count = 12 WHERE id = ?", arguments: [appID])
        }

        try archive.repairCounts()

        let count = try archive.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT notification_count FROM apps WHERE id = ?", arguments: [appID])
        }
        XCTAssertEqual(count, 0)
    }

    // MARK: Private

    private let now = Date(timeIntervalSince1970: 1_755_421_200)
    private let oneHour: TimeInterval = 60 * 60
    /// An app id no row has, to force a foreign-key failure.
    private let unknownAppID: Int64 = 999
    private let uuidA = "AAAAAAAA-0000-4000-8000-000000000001"
    private let uuidB = "BBBBBBBB-0000-4000-8000-000000000002"

    private var archive: Archive!

    private func makeNotification(
        appID: Int64,
        uuid: String? = nil,
        deliveredAt: Date? = nil,
        storeRecID: Int64? = nil
    ) -> ArchivedNotification {
        ArchivedNotification(
            id: nil,
            uuid: uuid ?? uuidA,
            appId: appID,
            title: "Fixture title",
            subtitle: nil,
            body: "Fixture body",
            sender: nil,
            threadId: nil,
            category: nil,
            deliveredAt: UnixDate(deliveredAt ?? now),
            capturedAt: UnixDate(now),
            source: .live,
            presented: true,
            awaySessionId: nil,
            deepLink: nil,
            attachmentsJson: nil,
            redaction: .none,
            isRead: false,
            isPinned: false,
            isDeleted: false,
            storeRecId: storeRecID
        )
    }
}
