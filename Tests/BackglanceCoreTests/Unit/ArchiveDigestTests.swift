@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

/// Covers `Archive+Digest.swift`: the reads `DigestView` and `DigestViewModel` depend
/// on, and the once-only writes that stamp `shown_at` / `dismissed_at`.
///
/// Runs on `Archive(inMemory: true)`, matching `DigestEngineTests` — foreign keys are
/// enforced, so a digest row here is only ever reachable through a real away session.
final class ArchiveDigestTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archiveStorage = try Archive(inMemory: true)
        appIDStorage = try seedApp()
    }

    override func tearDownWithError() throws {
        archiveStorage = nil
        appIDStorage = nil
        try super.tearDownWithError()
    }

    // MARK: - digestNotifications(digestID:)

    func testDigestNotificationsAreOrderedByRankNotByIdOrDate() throws {
        // Deliberately seeded so id order, delivery order and rank order all disagree —
        // only a rank-order bug would slip through if any one of them coincided.
        let first = try seed(at: base.addingTimeInterval(100))
        let second = try seed(at: base.addingTimeInterval(500))
        let third = try seed(at: base.addingTimeInterval(300))

        let digestID = try insertDigest()
        try insertItems(digestID: digestID, ranked: [second, third, first])

        let rows = try archive().digestNotifications(digestID: digestID)
        XCTAssertEqual(rows.map(\.id), [second, third, first])
    }

    func testDigestNotificationsOmitsSoftDeletedRows() throws {
        let kept = try seed(at: base.addingTimeInterval(100))
        let deleted = try seed(at: base.addingTimeInterval(200))

        let digestID = try insertDigest()
        try insertItems(digestID: digestID, ranked: [kept, deleted])
        try archive().pool.write { db in
            try db.execute(sql: "UPDATE notifications SET is_deleted = 1 WHERE id = ?", arguments: [deleted])
        }

        let rows = try archive().digestNotifications(digestID: digestID)
        XCTAssertEqual(rows.map(\.id), [kept], "a row the user deleted is not part of what they missed any more")
    }

    // MARK: - markDigestShown(_:at:)

    func testMarkDigestShownIsTrueOnceThenFalseAndKeepsTheFirstTimestamp() throws {
        let digestID = try insertDigest()
        let firstStamp = base
        let secondStamp = base.addingTimeInterval(3_600)

        XCTAssertTrue(try archive().markDigestShown(digestID, at: firstStamp))
        XCTAssertFalse(try archive().markDigestShown(digestID, at: secondStamp))

        let stored = try XCTUnwrap(try fetchDigest(digestID))
        XCTAssertEqual(stored.shownAt?.date, firstStamp, "reopening the card must not move shown_at")
    }

    // MARK: - dismissDigest(_:at:)

    func testDismissDigestIsTrueOnceThenFalseAndKeepsTheFirstTimestamp() throws {
        let digestID = try insertDigest()
        let firstStamp = base
        let secondStamp = base.addingTimeInterval(3_600)

        XCTAssertTrue(try archive().dismissDigest(digestID, at: firstStamp))
        XCTAssertFalse(try archive().dismissDigest(digestID, at: secondStamp))

        let stored = try XCTUnwrap(try fetchDigest(digestID))
        XCTAssertEqual(stored.dismissedAt?.date, firstStamp)
    }

    // MARK: - pendingDigest()

    func testPendingDigestIsTheNewestUndismissedOne() throws {
        _ = try insertDigest(createdAt: base)
        let newer = try insertDigest(createdAt: base.addingTimeInterval(600))

        let pending = try XCTUnwrap(try archive().pendingDigest())
        XCTAssertEqual(pending.id, newer)
    }

    func testPendingDigestSkipsDismissedOnesAndFallsBackToTheNextNewest() throws {
        let older = try insertDigest(createdAt: base)
        let newer = try insertDigest(createdAt: base.addingTimeInterval(600))
        try archive().dismissDigest(newer, at: base.addingTimeInterval(700))

        let pending = try XCTUnwrap(try archive().pendingDigest())
        XCTAssertEqual(pending.id, older, "the newer one was answered; the older one is still waiting")
    }

    func testPendingDigestIsNilWhenEverythingIsDismissed() throws {
        let digestID = try insertDigest()
        try archive().dismissDigest(digestID, at: base.addingTimeInterval(60))

        XCTAssertNil(try archive().pendingDigest())
    }

    func testPendingDigestDoesReturnAShownButNotDismissedDigest() throws {
        // Closing the popover mid-read must not count as an answer — only
        // dismissed_at retires a digest.
        let digestID = try insertDigest()
        try archive().markDigestShown(digestID, at: base.addingTimeInterval(60))

        let pending = try XCTUnwrap(try archive().pendingDigest())
        XCTAssertEqual(pending.id, digestID)
    }

    // MARK: - lastDigest()

    func testLastDigestIsTheNewestEvenWhenDismissed() throws {
        _ = try insertDigest(createdAt: base)
        let newer = try insertDigest(createdAt: base.addingTimeInterval(600))
        try archive().dismissDigest(newer, at: base.addingTimeInterval(700))

        let last = try XCTUnwrap(try archive().lastDigest())
        XCTAssertEqual(last.id, newer, "'Last digest' reopens the most recent one regardless of its state")
    }

    // MARK: - markRead(ids:)

    func testMarkReadMarksOnlyTheGivenIdsAndReturnsTheChangedCount() throws {
        let target = try seed(at: base.addingTimeInterval(100))
        let untouched = try seed(at: base.addingTimeInterval(200))

        let changed = try archive().markRead(ids: [target])
        XCTAssertEqual(changed, 1)
        XCTAssertTrue(try isRead(target))
        XCTAssertFalse(try isRead(untouched))
    }

    func testMarkReadSkipsAlreadyReadAndSoftDeletedRows() throws {
        let alreadyRead = try seed(at: base.addingTimeInterval(100))
        let deleted = try seed(at: base.addingTimeInterval(200))
        try archive().pool.write { db in
            try db.execute(sql: "UPDATE notifications SET is_read = 1 WHERE id = ?", arguments: [alreadyRead])
            try db.execute(sql: "UPDATE notifications SET is_deleted = 1 WHERE id = ?", arguments: [deleted])
        }

        let changed = try archive().markRead(ids: [alreadyRead, deleted])
        XCTAssertEqual(changed, 0, "nothing here was actually changed by this call")
    }

    func testMarkReadOnAnEmptyArrayReturnsZero() throws {
        XCTAssertEqual(try archive().markRead(ids: []), 0)
    }

    // MARK: - deliveryDates(inAwaySession:)

    func testDeliveryDatesReturnsOnlyThatSessionsNonDeletedRowsOldestFirst() throws {
        let session = try archive().insertAwaySession(
            AwaySession(startedAt: UnixDate(base), endedAt: UnixDate(base.addingTimeInterval(600)), reason: .locked)
        )
        let otherSession = try archive().insertAwaySession(
            AwaySession(
                startedAt: UnixDate(base.addingTimeInterval(1_000)),
                endedAt: UnixDate(base.addingTimeInterval(1_600)),
                reason: .asleep
            )
        )

        try seed(at: base.addingTimeInterval(500)) // newer, in-session
        try seed(at: base.addingTimeInterval(100)) // older, in-session
        let deleted = try seed(at: base.addingTimeInterval(300))
        let elsewhere = try seed(at: base.addingTimeInterval(1_100))

        try archive().linkNotifications(to: session)
        try archive().pool.write { db in
            try db.execute(sql: "UPDATE notifications SET is_deleted = 1 WHERE id = ?", arguments: [deleted])
        }
        try archive().pool.write { db in
            try db.execute(
                sql: "UPDATE notifications SET away_session_id = ? WHERE id = ?",
                arguments: [otherSession.id, elsewhere]
            )
        }

        let dates = try archive().deliveryDates(inAwaySession: XCTUnwrap(session.id))
        XCTAssertEqual(dates, [base.addingTimeInterval(100), base.addingTimeInterval(500)])
    }

    // MARK: Private

    private enum SeedFailure: Error {
        case noRowID
    }

    private var archiveStorage: Archive?
    private var appIDStorage: Int64?

    private let base = Date(timeIntervalSince1970: 1_755_600_000)

    private func archive() throws -> Archive {
        try XCTUnwrap(archiveStorage)
    }

    private func seedApp(bundleID: String = "com.example.Chat") throws -> Int64 {
        try archive().pool.write { db in
            var app = AppRecord(
                bundleId: bundleID,
                displayName: bundleID,
                firstSeenAt: UnixDate(self.base),
                lastSeenAt: UnixDate(self.base)
            )
            try app.insert(db)
            guard let id = app.id else {
                throw SeedFailure.noRowID
            }
            return id
        }
    }

    @discardableResult
    private func seed(at delivered: Date) throws -> Int64 {
        let owner = try XCTUnwrap(appIDStorage)
        return try archive().pool.write { db in
            var row = ArchivedNotification(
                uuid: UUID().uuidString,
                appId: owner,
                title: "Seed",
                deliveredAt: UnixDate(delivered),
                capturedAt: UnixDate(delivered)
            )
            try row.insert(db)
            guard let id = row.id else {
                throw SeedFailure.noRowID
            }
            return id
        }
    }

    /// A minimal `Digest` row, backed by a real away session so the foreign key holds.
    /// Returns its id.
    @discardableResult
    private func insertDigest(createdAt: Date? = nil) throws -> Int64 {
        let created = createdAt ?? base
        let session = try archive().insertAwaySession(
            AwaySession(
                startedAt: UnixDate(created.addingTimeInterval(-600)),
                endedAt: UnixDate(created),
                reason: .locked
            )
        )
        return try archive().pool.write { db in
            var digest = try Digest(
                awaySessionId: XCTUnwrap(session.id),
                createdAt: UnixDate(created)
            )
            try digest.insert(db)
            return try XCTUnwrap(digest.id)
        }
    }

    private func insertItems(digestID: Int64, ranked: [Int64]) throws {
        try archive().pool.write { db in
            for (rank, notificationID) in ranked.enumerated() {
                var item = DigestItem(digestId: digestID, notificationId: notificationID, rank: rank)
                try item.insert(db)
            }
        }
    }

    private func fetchDigest(_ id: Int64) throws -> Digest? {
        try archive().pool.read { db in try Digest.fetchOne(db, key: id) }
    }

    private func isRead(_ id: Int64) throws -> Bool {
        try archive().pool.read { db in
            try XCTUnwrap(ArchivedNotification.fetchOne(db, key: id)).isRead
        }
    }
}
