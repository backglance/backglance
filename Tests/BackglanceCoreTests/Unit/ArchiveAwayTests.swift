@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

/// Covers the `Archive` side of the away model: writing a finished session down, closing
/// one a previous run left open, and reading recent sessions back.
///
/// `AwaySessionTrackerTests` proves the state machine; this proves the row that comes out
/// of it survives the real schema (`Archive(inMemory: true)`, so foreign keys are on).
final class ArchiveAwayTests: XCTestCase {
    // MARK: Internal

    // MARK: - Insert

    func testInsertingASessionReturnsItWithItsIdentifier() throws {
        let archive = try Archive(inMemory: true)
        let started = Date(timeIntervalSince1970: 1_755_600_000)

        let stored = try archive.insertAwaySession(AwaySession(
            startedAt: UnixDate(started),
            endedAt: UnixDate(started.addingTimeInterval(900)),
            reason: .locked
        ))

        let id = try XCTUnwrap(stored.id)
        let fetched = try XCTUnwrap(archive.pool.read { db in try AwaySession.fetchOne(db, key: id) })
        XCTAssertEqual(fetched.reason, .locked)
        XCTAssertEqual(fetched.startedAt.date, started)
        XCTAssertFalse(fetched.isOpen)
    }

    func testAShortSessionIsWrittenJustLikeALongOne() throws {
        let archive = try Archive(inMemory: true)
        let started = Date(timeIntervalSince1970: 1_755_600_000)

        // Under the digest threshold. The row still belongs in the table: `is:missed`
        // reads it (docs/features/MISSED_DIGEST.md#session-merging-and-thresholds).
        try archive.insertAwaySession(AwaySession(
            startedAt: UnixDate(started),
            endedAt: UnixDate(started.addingTimeInterval(30)),
            reason: .focus
        ))

        let count = try archive.pool.read { db in try AwaySession.fetchCount(db) }
        XCTAssertEqual(count, 1)
    }

    // MARK: - Closing what a crash left behind

    func testClosingOpenSessionsOnlyTouchesTheOpenOnes() throws {
        let archive = try Archive(inMemory: true)
        let base = Date(timeIntervalSince1970: 1_755_600_000)
        let finishedEnd = UnixDate(base.addingTimeInterval(600))

        try archive.insertAwaySession(AwaySession(
            startedAt: UnixDate(base), endedAt: finishedEnd, reason: .locked
        ))
        try archive.insertAwaySession(AwaySession(
            startedAt: UnixDate(base.addingTimeInterval(3_600)), endedAt: nil, reason: .asleep
        ))

        let repairedAt = base.addingTimeInterval(7_200)
        let closed = try archive.closeOpenAwaySessions(endedAt: repairedAt)
        XCTAssertEqual(closed, 1)

        let all = try archive.pool.read { db in
            try AwaySession.order(Column("started_at")).fetchAll(db)
        }
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].endedAt, finishedEnd, "a finished session must keep its own end")
        XCTAssertEqual(all[1].endedAt?.date, repairedAt)
        XCTAssertTrue(all.allSatisfy { !$0.isOpen })
    }

    func testClosingOpenSessionsIsANoOpWhenThereAreNone() throws {
        let archive = try Archive(inMemory: true)
        XCTAssertEqual(try archive.closeOpenAwaySessions(endedAt: Date()), 0)
    }

    // MARK: - Reading back

    func testRecentSessionsComeBackNewestFirstAndSkipOpenOnes() throws {
        let archive = try Archive(inMemory: true)
        let base = Date(timeIntervalSince1970: 1_755_600_000)

        for offset in [0.0, 3_600.0, 7_200.0] {
            try archive.insertAwaySession(AwaySession(
                startedAt: UnixDate(base.addingTimeInterval(offset)),
                endedAt: UnixDate(base.addingTimeInterval(offset + 600)),
                reason: .locked
            ))
        }
        // Older than the window, and one still running.
        try archive.insertAwaySession(AwaySession(
            startedAt: UnixDate(base.addingTimeInterval(-86_400)),
            endedAt: UnixDate(base.addingTimeInterval(-86_000)),
            reason: .asleep
        ))
        try archive.insertAwaySession(AwaySession(
            startedAt: UnixDate(base.addingTimeInterval(10_800)), endedAt: nil, reason: .manual
        ))

        let recent = try archive.awaySessions(since: base)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(
            recent.map(\.startedAt.date),
            [7_200.0, 3_600.0, 0.0].map { base.addingTimeInterval($0) }
        )
    }

    func testTheLimitIsHonoured() throws {
        let archive = try Archive(inMemory: true)
        let base = Date(timeIntervalSince1970: 1_755_600_000)

        for offset in stride(from: 0.0, to: 5_000.0, by: 1_000.0) {
            try archive.insertAwaySession(AwaySession(
                startedAt: UnixDate(base.addingTimeInterval(offset)),
                endedAt: UnixDate(base.addingTimeInterval(offset + 100)),
                reason: .locked
            ))
        }

        XCTAssertEqual(try archive.awaySessions(since: base, limit: 2).count, 2)
    }

    // MARK: - Linking notifications to a session

    func testNotificationsDeliveredDuringTheSessionAreLinked() throws {
        let archive = try Archive(inMemory: true)
        let base = Date(timeIntervalSince1970: 1_755_600_000)
        let appID = try seedApp(archive)

        let before = try seedNotification(archive, appID: appID, at: base.addingTimeInterval(-60))
        let during = try seedNotification(archive, appID: appID, at: base.addingTimeInterval(300))
        let after = try seedNotification(archive, appID: appID, at: base.addingTimeInterval(1_200))

        let session = try archive.insertAwaySession(AwaySession(
            startedAt: UnixDate(base),
            endedAt: UnixDate(base.addingTimeInterval(600)),
            reason: .locked
        ))
        XCTAssertEqual(try archive.linkNotifications(to: session), 1)

        XCTAssertEqual(try awaySessionID(archive, of: during), session.id)
        XCTAssertNil(try awaySessionID(archive, of: before))
        XCTAssertNil(try awaySessionID(archive, of: after))
    }

    func testTheSessionBoundsAreInclusive() throws {
        let archive = try Archive(inMemory: true)
        let base = Date(timeIntervalSince1970: 1_755_600_000)
        let appID = try seedApp(archive)
        let end = base.addingTimeInterval(600)

        // A notification delivered in the very second the screen locked was missed.
        let atStart = try seedNotification(archive, appID: appID, at: base)
        let atEnd = try seedNotification(archive, appID: appID, at: end)

        let session = try archive.insertAwaySession(AwaySession(
            startedAt: UnixDate(base), endedAt: UnixDate(end), reason: .locked
        ))
        XCTAssertEqual(try archive.linkNotifications(to: session), 2)
        XCTAssertNotNil(try awaySessionID(archive, of: atStart))
        XCTAssertNotNil(try awaySessionID(archive, of: atEnd))
    }

    func testANotificationBelongsToTheFirstSessionThatClaimedIt() throws {
        let archive = try Archive(inMemory: true)
        let base = Date(timeIntervalSince1970: 1_755_600_000)
        let appID = try seedApp(archive)
        let target = try seedNotification(archive, appID: appID, at: base.addingTimeInterval(300))

        let first = try archive.insertAwaySession(AwaySession(
            startedAt: UnixDate(base), endedAt: UnixDate(base.addingTimeInterval(600)), reason: .locked
        ))
        let second = try archive.insertAwaySession(AwaySession(
            startedAt: UnixDate(base), endedAt: UnixDate(base.addingTimeInterval(600)), reason: .asleep
        ))

        XCTAssertEqual(try archive.linkNotifications(to: first), 1)
        XCTAssertEqual(try archive.linkNotifications(to: second), 0, "an already-claimed row must not move")
        XCTAssertEqual(try awaySessionID(archive, of: target), first.id)
    }

    func testDeletedNotificationsAreNotLinked() throws {
        let archive = try Archive(inMemory: true)
        let base = Date(timeIntervalSince1970: 1_755_600_000)
        let appID = try seedApp(archive)
        let deleted = try seedNotification(
            archive, appID: appID, at: base.addingTimeInterval(300), isDeleted: true
        )

        let session = try archive.insertAwaySession(AwaySession(
            startedAt: UnixDate(base), endedAt: UnixDate(base.addingTimeInterval(600)), reason: .locked
        ))
        XCTAssertEqual(try archive.linkNotifications(to: session), 0)
        XCTAssertNil(try awaySessionID(archive, of: deleted))
    }

    func testAnUnpersistedOrOpenSessionLinksNothing() throws {
        let archive = try Archive(inMemory: true)
        let base = Date(timeIntervalSince1970: 1_755_600_000)
        let appID = try seedApp(archive)
        try seedNotification(archive, appID: appID, at: base.addingTimeInterval(300))

        // Never inserted: no id to link to.
        let unsaved = AwaySession(
            startedAt: UnixDate(base), endedAt: UnixDate(base.addingTimeInterval(600)), reason: .locked
        )
        XCTAssertEqual(try archive.linkNotifications(to: unsaved), 0)

        // Still open: no window to claim yet.
        let open = try archive.insertAwaySession(AwaySession(
            startedAt: UnixDate(base), endedAt: nil, reason: .locked
        ))
        XCTAssertEqual(try archive.linkNotifications(to: open), 0)
    }

    /// A below-threshold session earns no digest, and linking is what keeps the archive's
    /// promise that it is still worth searching.
    func testAShortSessionStillLinksSoItRemainsFindable() throws {
        let archive = try Archive(inMemory: true)
        let base = Date(timeIntervalSince1970: 1_755_600_000)
        let appID = try seedApp(archive)
        let target = try seedNotification(archive, appID: appID, at: base.addingTimeInterval(15))

        let session = try archive.insertAwaySession(AwaySession(
            startedAt: UnixDate(base), endedAt: UnixDate(base.addingTimeInterval(30)), reason: .locked
        ))
        XCTAssertEqual(try archive.linkNotifications(to: session), 1)
        XCTAssertEqual(try awaySessionID(archive, of: target), session.id)
    }

    func testDeletingASessionLeavesItsNotificationsAlone() throws {
        let archive = try Archive(inMemory: true)
        let base = Date(timeIntervalSince1970: 1_755_600_000)
        let appID = try seedApp(archive)
        let target = try seedNotification(archive, appID: appID, at: base.addingTimeInterval(300))

        let session = try archive.insertAwaySession(AwaySession(
            startedAt: UnixDate(base), endedAt: UnixDate(base.addingTimeInterval(600)), reason: .locked
        ))
        try archive.linkNotifications(to: session)

        // ON DELETE SET NULL: retention pruning a session must not take notifications
        // with it.
        try archive.pool.write { db in
            _ = try AwaySession.deleteOne(db, key: session.id)
        }
        XCTAssertNil(try awaySessionID(archive, of: target))
        let survives = try archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        XCTAssertEqual(survives, 1)
    }

    // MARK: Private

    private enum SeedFailure: Error {
        case noRowID
    }

    private func seedApp(_ archive: Archive) throws -> Int64 {
        try archive.pool.write { db in
            var app = AppRecord(
                bundleId: "com.example.Chat",
                displayName: "Chat",
                firstSeenAt: UnixDate(Date(timeIntervalSince1970: 1_755_000_000)),
                lastSeenAt: UnixDate(Date(timeIntervalSince1970: 1_755_000_000))
            )
            try app.insert(db)
            guard let id = app.id else {
                throw SeedFailure.noRowID
            }
            return id
        }
    }

    @discardableResult
    private func seedNotification(
        _ archive: Archive,
        appID: Int64,
        at delivered: Date,
        isDeleted: Bool = false
    ) throws -> Int64 {
        try archive.pool.write { db in
            var row = ArchivedNotification(
                uuid: UUID().uuidString,
                appId: appID,
                title: "Seed",
                deliveredAt: UnixDate(delivered),
                capturedAt: UnixDate(delivered),
                isDeleted: isDeleted
            )
            try row.insert(db)
            guard let id = row.id else {
                throw SeedFailure.noRowID
            }
            return id
        }
    }

    private func awaySessionID(_ archive: Archive, of notificationID: Int64) throws -> Int64? {
        try archive.pool.read { db in
            try ArchivedNotification.fetchOne(db, key: notificationID)?.awaySessionId
        }
    }
}
