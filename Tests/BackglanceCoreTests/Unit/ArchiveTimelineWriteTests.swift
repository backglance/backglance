@testable import BackglanceCore
import BackglanceTestSupport
import Foundation
import GRDB
import XCTest

final class ArchiveTimelineWriteTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - Marking read

    func testMarkingARowReadFlipsItOnce() throws {
        let archive = try XCTUnwrap(archive)
        let ids = try TimelineSeed.fill(archive, count: 3)
        let target = try XCTUnwrap(ids.first)

        XCTAssertTrue(try archive.markRead(target))
        XCTAssertFalse(try archive.markRead(target), "an already-read row is not a change")

        let row = try XCTUnwrap(archive.timelinePage().first { $0.id == target })
        XCTAssertTrue(row.isRead)
    }

    /// The visibility timer calls this far more often than it changes anything,
    /// and every real write wakes the timeline's observation — so a repeat has
    /// to be free.
    func testMarkingAnAlreadyReadRowTouchesNothing() throws {
        let archive = try XCTUnwrap(archive)
        let ids = try TimelineSeed.fill(archive, count: 2)
        let target = try XCTUnwrap(ids.first)
        try archive.markRead(target)

        let unreadBefore = try archive.pool.read { db in try Self.unreadCount(db) }
        try archive.markRead(target)
        let unreadAfter = try archive.pool.read { db in try Self.unreadCount(db) }

        XCTAssertEqual(unreadBefore, unreadAfter)
    }

    func testMarkAllReadClearsEveryVisibleRow() throws {
        let archive = try XCTUnwrap(archive)
        try TimelineSeed.fill(archive, count: 5)

        XCTAssertEqual(try archive.markAllRead(), 5)
        XCTAssertEqual(try archive.markAllRead(), 0, "nothing is left to mark")
        XCTAssertTrue(try archive.timelinePage().allSatisfy(\.isRead))
    }

    /// "Mark all read" is about the timeline in front of the user, and a
    /// soft-deleted row is not in it.
    func testMarkAllReadLeavesDeletedRowsAlone() throws {
        let archive = try XCTUnwrap(archive)
        try TimelineSeed.fill(archive, count: 4, deleted: [1, 2])

        XCTAssertEqual(try archive.markAllRead(), 2)
    }

    // MARK: - The badge query

    func testTheBadgeCountsOnlyUnreadUnmutedRowsAfterTheAnchor() throws {
        let archive = try XCTUnwrap(archive)
        let ids = try TimelineSeed.fill(archive, count: 4)
        try archive.markRead(XCTUnwrap(ids.first))

        let all = try archive.pool.read { db in
            try Archive.unreadBadgeCount(db, since: UnixDate(.distantPast))
        }
        let sinceNow = try archive.pool.read { db in
            try Archive.unreadBadgeCount(db, since: UnixDate(Stubs.epoch.addingTimeInterval(60)))
        }

        XCTAssertEqual(all, 3, "the row marked read no longer counts")
        XCTAssertEqual(sinceNow, 0, "nothing was delivered after the anchor")
    }

    func testAMutedAppNeverLightsTheBadgeUp() throws {
        let archive = try XCTUnwrap(archive)
        try TimelineSeed.fill(archive, count: 3)
        try archive.pool.write { db in
            try db.execute(sql: "UPDATE apps SET is_muted = 1")
        }

        let count = try archive.pool.read { db in
            try Archive.unreadBadgeCount(db, since: UnixDate(.distantPast))
        }

        XCTAssertEqual(count, 0)
    }

    /// The badge renders anything at the cap as "99+", so counting past it
    /// would be work nobody ever sees.
    func testTheCountStopsAtTheCap() throws {
        let archive = try XCTUnwrap(archive)
        try TimelineSeed.fill(archive, count: Archive.unreadBadgeCap + 50)

        let count = try archive.pool.read { db in
            try Archive.unreadBadgeCount(db, since: UnixDate(.distantPast))
        }

        XCTAssertEqual(count, Archive.unreadBadgeCap)
    }

    // MARK: - Resolving a uuid (backglance://open?id=)

    func testANotificationIsFoundByItsUUID() throws {
        let archive = try XCTUnwrap(archive)
        let ids = try TimelineSeed.fill(archive, count: 3)
        let target = try XCTUnwrap(ids.first)
        let expected = try XCTUnwrap(archive.timelinePage().first { $0.id == target })

        let found = try archive.notification(uuid: expected.uuid)

        XCTAssertEqual(found?.id, target)
    }

    /// The whole point of `backglance://open?id=`'s error path
    /// (docs/api/API_DOCUMENTATION.md#error-behavior): a uuid the archive has never
    /// seen resolves to `nil`, not a thrown error.
    func testAnUnknownUUIDResolvesToNil() throws {
        let archive = try XCTUnwrap(archive)
        try TimelineSeed.fill(archive, count: 2)

        XCTAssertNil(try archive.notification(uuid: UUID().uuidString))
    }

    /// A soft-deleted row is not in the timeline anywhere else either — the lookup
    /// agrees, so `backglance://open?id=` for a since-deleted notification reports
    /// "Not in the archive" rather than resolving a row `TimelineStore` could never
    /// show.
    func testASoftDeletedNotificationIsNotFoundByUUID() throws {
        let archive = try XCTUnwrap(archive)
        try TimelineSeed.fill(archive, count: 3, deleted: [1])
        let deletedUUID = try archive.pool.read { db in
            try String.fetchOne(db, sql: "SELECT uuid FROM notifications WHERE is_deleted = 1")
        }
        let uuid = try XCTUnwrap(deletedUUID)

        XCTAssertNil(try archive.notification(uuid: uuid))
    }

    // MARK: - The away-session half of the anchor

    func testTheLatestFinishedAwaySessionEndIsTheAnchorCandidate() throws {
        let archive = try XCTUnwrap(archive)
        try insertAwaySession(
            startedAt: Stubs.epoch.addingTimeInterval(-600),
            endedAt: Stubs.epoch.addingTimeInterval(-300)
        )
        try insertAwaySession(
            startedAt: Stubs.epoch.addingTimeInterval(-200),
            endedAt: Stubs.epoch.addingTimeInterval(-100)
        )

        let end = try XCTUnwrap(archive.lastAwaySessionEnd())

        XCTAssertEqual(
            end.date.timeIntervalSince1970,
            Stubs.epoch.addingTimeInterval(-100).timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    /// A session that has not ended means the user has not come back, so it is
    /// not a moment they looked at anything.
    func testAnOpenAwaySessionIsNotAnAnchor() throws {
        let archive = try XCTUnwrap(archive)
        try insertAwaySession(startedAt: Stubs.epoch.addingTimeInterval(-600), endedAt: nil)

        XCTAssertNil(try archive.lastAwaySessionEnd())
    }

    func testNoAwaySessionsMeansNoAnchorCandidate() throws {
        let archive = try XCTUnwrap(archive)

        XCTAssertNil(try archive.lastAwaySessionEnd())
    }

    // MARK: Private

    private var archive: Archive?

    private static func unreadCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notifications WHERE is_read = 0") ?? 0
    }

    private func insertAwaySession(startedAt: Date, endedAt: Date?) throws {
        let archive = try XCTUnwrap(archive)
        try archive.pool.write { db in
            var session = AwaySession(
                startedAt: UnixDate(startedAt),
                endedAt: endedAt.map(UnixDate.init),
                reason: .locked
            )
            try session.insert(db)
        }
    }
}
