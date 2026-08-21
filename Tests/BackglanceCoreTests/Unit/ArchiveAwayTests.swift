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
}
