@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

/// Covers `AppRecord`, `ArchivedNotification`, `RetentionPolicy`, and
/// `AppRetention` — in particular that every property maps onto the real
/// `ArchiveMigrations` schema (a typo in a column name here would be
/// invisible to the type checker and only surface as a GRDB runtime error
/// against a real database).
final class ModelsTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        queue = try DatabaseQueue()
        try ArchiveMigrations.migrator().migrate(queue)
    }

    override func tearDown() {
        queue = nil
        super.tearDown()
    }

    // MARK: - AppRecord round trip

    func testAppRecordRoundTripsThroughTheRealSchema() throws {
        let now = UnixDate(Date(timeIntervalSince1970: 1_755_000_000))
        var app = AppRecord(
            bundleId: "com.apple.MobileSMS",
            displayName: "Messages",
            retention: .policy(.days7),
            isExcluded: false,
            isMuted: true,
            redactOtp: true,
            firstSeenAt: now,
            lastSeenAt: now,
            notificationCount: 3
        )

        XCTAssertNil(app.id)
        try queue.write { db in try app.insert(db) }
        XCTAssertNotNil(app.id, "didInsert should have captured the rowID")

        let fetched = try queue.read { db in try AppRecord.fetchOne(db, key: app.id) }
        XCTAssertEqual(fetched, app)
        XCTAssertEqual(fetched?.retention, .policy(.days7))
        XCTAssertEqual(fetched?.isMuted, true)
        XCTAssertEqual(fetched?.redactOtp, true)
    }

    // MARK: - ArchivedNotification round trip

    func testArchivedNotificationRoundTripsThroughTheRealSchema() throws {
        let appID = try insertApp()
        let deliveredAt = UnixDate(Date(timeIntervalSince1970: 1_755_100_000))
        let capturedAt = UnixDate(Date(timeIntervalSince1970: 1_755_100_001))

        var notification = ArchivedNotification(
            uuid: UUID().uuidString,
            appId: appID,
            title: "Verification code",
            subtitle: "sub",
            body: "body",
            sender: "sender",
            threadId: "thread-1",
            category: "otp",
            deliveredAt: deliveredAt,
            capturedAt: capturedAt,
            source: .live,
            presented: false,
            awaySessionId: nil,
            deepLink: "imessage://",
            attachmentsJson: "[]",
            redaction: .otp,
            isRead: true,
            isPinned: true,
            isDeleted: false,
            storeRecId: 42
        )

        XCTAssertNil(notification.id)
        try queue.write { db in try notification.insert(db) }
        XCTAssertNotNil(notification.id, "didInsert should have captured the rowID")

        let fetched = try queue.read { db in try ArchivedNotification.fetchOne(db, key: notification.id) }
        XCTAssertEqual(fetched, notification)
        XCTAssertEqual(fetched?.appId, appID)
        XCTAssertEqual(fetched?.presented, false)
        XCTAssertEqual(fetched?.redaction, .otp)
        XCTAssertEqual(fetched?.storeRecId, 42)
    }

    // MARK: - AppRetention raw-value round trip

    func testAppRetentionRawValueRoundTrip() {
        XCTAssertEqual(AppRetention(rawValue: "inherit"), .inherit)
        XCTAssertEqual(AppRetention.inherit.rawValue, "inherit")

        for policy in RetentionPolicy.allCases {
            XCTAssertEqual(AppRetention(rawValue: policy.rawValue), .policy(policy))
            XCTAssertEqual(AppRetention.policy(policy).rawValue, policy.rawValue)
        }
    }

    func testAppRetentionRejectsUnknownRawValue() {
        XCTAssertNil(AppRetention(rawValue: "quarterly"))
        XCTAssertNil(AppRetention(rawValue: ""))
    }

    // MARK: - RetentionPolicy.interval

    func testRetentionPolicyIntervalIsNilForForeverAndNever() {
        XCTAssertNil(RetentionPolicy.forever.interval)
        XCTAssertNil(RetentionPolicy.never.interval)
    }

    func testRetentionPolicyIntervalMatchesItsName() {
        XCTAssertEqual(RetentionPolicy.hours24.interval, 60 * 60 * 24)
        XCTAssertEqual(RetentionPolicy.days7.interval, 60 * 60 * 24 * 7)
        XCTAssertEqual(RetentionPolicy.days30.interval, 60 * 60 * 24 * 30)
    }

    // MARK: - recent(limit:)

    func testRecentExcludesDeletedRowsAndOrdersNewestFirst() throws {
        let appID = try insertApp()
        let base = Date(timeIntervalSince1970: 1_755_200_000)

        var kept: [ArchivedNotification] = []
        for offset in 0 ..< 3 {
            let notification = try insertNotification(
                appId: appID,
                deliveredAt: base.addingTimeInterval(TimeInterval(offset * 60))
            )
            kept.append(notification)
        }

        var deleted = makeNotification(appId: appID, deliveredAt: base.addingTimeInterval(600))
        deleted.isDeleted = true
        try queue.write { db in try deleted.insert(db) }

        let fetched = try queue.read { db in try ArchivedNotification.recent(limit: 10).fetchAll(db) }

        XCTAssertEqual(fetched.map(\.id), kept.reversed().map(\.id), "newest delivered_at first")
        XCTAssertFalse(fetched.contains { $0.id == deleted.id })
    }

    func testRecentRespectsLimit() throws {
        let appID = try insertApp()
        let base = Date(timeIntervalSince1970: 1_755_300_000)
        for offset in 0 ..< 5 {
            _ = try insertNotification(appId: appID, deliveredAt: base.addingTimeInterval(TimeInterval(offset * 60)))
        }

        let fetched = try queue.read { db in try ArchivedNotification.recent(limit: 2).fetchAll(db) }
        XCTAssertEqual(fetched.count, 2)
    }

    // MARK: - Keyset pagination

    func testKeysetPagingCoversEachRowExactlyOnceAcrossTwoPages() throws {
        let appID = try insertApp()
        let base = Date(timeIntervalSince1970: 1_755_400_000)

        var inserted: [ArchivedNotification] = []
        for offset in 0 ..< 5 {
            let notification = try insertNotification(
                appId: appID,
                deliveredAt: base.addingTimeInterval(TimeInterval(offset * 60))
            )
            inserted.append(notification)
        }
        let newestFirst = inserted.reversed().map(\.id)

        let firstPage = try queue.read { db in
            try ArchivedNotification.page(after: nil, limit: 3).fetchAll(db)
        }
        XCTAssertEqual(firstPage.map(\.id), Array(newestFirst.prefix(3)))

        let last = try XCTUnwrap(firstPage.last)
        let cursor = try (deliveredAt: last.deliveredAt, id: XCTUnwrap(last.id))
        let secondPage = try queue.read { db in
            try ArchivedNotification.page(after: cursor, limit: 3).fetchAll(db)
        }
        XCTAssertEqual(secondPage.map(\.id), Array(newestFirst.suffix(2)))

        let seenAcrossBothPages = firstPage.map(\.id) + secondPage.map(\.id)
        XCTAssertEqual(seenAcrossBothPages.count, Set(seenAcrossBothPages).count, "no row repeated across pages")
        XCTAssertEqual(Set(seenAcrossBothPages), Set(inserted.map(\.id)), "no row skipped across pages")
    }

    func testKeysetPagingTiebreaksOnIdWhenDeliveredAtTies() throws {
        let appID = try insertApp()
        let sharedInstant = Date(timeIntervalSince1970: 1_755_500_000)

        let first = try insertNotification(appId: appID, deliveredAt: sharedInstant)
        let second = try insertNotification(appId: appID, deliveredAt: sharedInstant)

        let firstPage = try queue.read { db in try ArchivedNotification.page(after: nil, limit: 1).fetchAll(db) }
        XCTAssertEqual(firstPage.map(\.id), [second.id], "id DESC breaks the delivered_at tie")

        let head = try XCTUnwrap(firstPage.first)
        let cursor = try (deliveredAt: head.deliveredAt, id: XCTUnwrap(head.id))
        let secondPage = try queue.read { db in try ArchivedNotification.page(after: cursor, limit: 1).fetchAll(db) }
        XCTAssertEqual(secondPage.map(\.id), [first.id])
    }

    // MARK: - Source encoding

    func testImportSourceEncodesToTheStringImport() throws {
        let appID = try insertApp()
        var notification = makeNotification(appId: appID, deliveredAt: Date())
        notification.source = .imports
        try queue.write { db in try notification.insert(db) }

        let raw = try queue.read { db in
            try String.fetchOne(db, sql: "SELECT source FROM notifications WHERE id = ?", arguments: [notification.id])
        }
        XCTAssertEqual(raw, "import")

        let fetched = try queue.read { db in try ArchivedNotification.fetchOne(db, key: notification.id) }
        XCTAssertEqual(fetched?.source, .imports)
    }

    // MARK: Private

    private var queue: DatabaseQueue!

    /// Inserts a minimal `AppRecord` and returns its rowID.
    @discardableResult
    private func insertApp(bundleId: String = "com.example.app") throws -> Int64 {
        var app = AppRecord(bundleId: bundleId, firstSeenAt: .now, lastSeenAt: .now)
        try queue.write { db in try app.insert(db) }
        return try XCTUnwrap(app.id)
    }

    private func makeNotification(appId: Int64, deliveredAt: Date) -> ArchivedNotification {
        ArchivedNotification(
            uuid: UUID().uuidString,
            appId: appId,
            deliveredAt: UnixDate(deliveredAt),
            capturedAt: UnixDate(deliveredAt)
        )
    }

    @discardableResult
    private func insertNotification(appId: Int64, deliveredAt: Date) throws -> ArchivedNotification {
        var notification = makeNotification(appId: appId, deliveredAt: deliveredAt)
        try queue.write { db in try notification.insert(db) }
        return notification
    }
}
