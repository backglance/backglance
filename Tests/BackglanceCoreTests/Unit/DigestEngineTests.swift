@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

/// Covers `DigestEngine.build(for:)` against the pipeline in
/// docs/features/MISSED_DIGEST.md#business-logic-digestengine: two selection signals,
/// the exclusions, ranking, the shown cap, and one digest per session.
///
/// Everything runs on `Archive(inMemory: true)` so foreign keys are enforced — the
/// cascade behaviour is part of what is being asserted.
final class DigestEngineTests: XCTestCase {
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

    // MARK: - The two selection signals

    func testNotificationsInsideTheWindowAreSelected() throws {
        try seed(at: base.addingTimeInterval(-60))
        let inside = try seed(at: base.addingTimeInterval(300))
        try seed(at: base.addingTimeInterval(1_200))

        let digest = try XCTUnwrap(try build())
        XCTAssertEqual(digest.itemCount, 1)
        XCTAssertEqual(try itemIDs(of: digest), [inside])
    }

    func testAnUnpresentedNotificationJustOutsideTheWindowIsStillSelected() throws {
        // A Focus swallowed the banner and `usernoted`'s clock is not ours — the skew
        // allowance is what keeps that record in the digest it belongs to.
        let skewed = try seed(at: base.addingTimeInterval(-60), presented: false)
        let digest = try XCTUnwrap(try build())
        XCTAssertEqual(try itemIDs(of: digest), [skewed])
    }

    func testAnUnpresentedNotificationFarOutsideTheWindowIsNotSelected() throws {
        try seed(at: base.addingTimeInterval(-DigestEngine.skewWindow - 60), presented: false)
        XCTAssertNil(try build(), "the skew allowance is not an open-ended reach")
    }

    func testAPresentedNotificationOutsideTheWindowIsNotSelected() throws {
        // It was shown, and it arrived while the user was here. Nothing was missed.
        try seed(at: base.addingTimeInterval(-60), presented: true)
        XCTAssertNil(try build())
    }

    // MARK: - What never surfaces

    func testDeletedNotificationsAreNotSelected() throws {
        try seed(at: base.addingTimeInterval(300), isDeleted: true)
        XCTAssertNil(try build())
    }

    func testNotificationsFromAnExcludedAppAreNotSelected() throws {
        // Belt and braces: an excluded app is never captured, but an exclusion added
        // *after* capture is exactly the case where the row exists and must not resurface.
        try seed(at: base.addingTimeInterval(300))
        try archive().pool.write { db in
            try db.execute(sql: "UPDATE apps SET is_excluded = 1")
        }
        XCTAssertNil(try build())
    }

    func testANotificationAlreadyInAnotherDigestIsNotSelectedAgain() throws {
        try seed(at: base.addingTimeInterval(300))
        let first = try XCTUnwrap(try build())
        XCTAssertEqual(first.itemCount, 1)

        // A second, overlapping session must not show the same item twice.
        let second = try session(from: base, to: base.addingTimeInterval(600), reason: .asleep)
        XCTAssertNil(try DigestEngine(archive: archive()).build(for: second))
    }

    // MARK: - Nothing to say

    func testASessionWithNoNotificationsWritesNoDigestRow() throws {
        XCTAssertNil(try build())
        let digests = try archive().pool.read { db in try Digest.fetchCount(db) }
        XCTAssertEqual(digests, 0, "an empty digest is an interruption that says nothing happened")
    }

    // MARK: - One per session

    func testASecondBuildForTheSameSessionThrowsAlreadyBuilt() throws {
        try seed(at: base.addingTimeInterval(300))
        let stored = try session(from: base, to: base.addingTimeInterval(600))
        let engine = try DigestEngine(archive: archive())
        let first = try XCTUnwrap(try engine.build(for: stored))

        // Wake and unlock racing produces two session-end events; the second must be
        // refused at the data layer rather than by the caller remembering to check.
        XCTAssertThrowsError(try engine.build(for: stored)) { error in
            XCTAssertEqual(error as? DigestEngine.DigestError, .alreadyBuilt(digestID: first.id ?? -1))
        }
        let count = try archive().pool.read { db in try Digest.fetchCount(db) }
        XCTAssertEqual(count, 1)
    }

    func testAnUnpersistedOrOpenSessionCannotBeSummarised() throws {
        let engine = try DigestEngine(archive: archive())
        let unsaved = AwaySession(startedAt: UnixDate(base), endedAt: UnixDate(base), reason: .locked)
        XCTAssertThrowsError(try engine.build(for: unsaved)) { error in
            XCTAssertEqual(error as? DigestEngine.DigestError, .sessionNotPersisted)
        }

        let open = try archive().insertAwaySession(
            AwaySession(startedAt: UnixDate(base), endedAt: nil, reason: .locked)
        )
        XCTAssertThrowsError(try engine.build(for: open)) { error in
            XCTAssertEqual(error as? DigestEngine.DigestError, .sessionNotPersisted)
        }
    }

    // MARK: - Ranking

    func testWithoutRulesItemsAreNewestFirst() throws {
        let oldest = try seed(at: base.addingTimeInterval(100))
        let newest = try seed(at: base.addingTimeInterval(500))
        let middle = try seed(at: base.addingTimeInterval(300))

        let digest = try XCTUnwrap(try build())
        XCTAssertEqual(try itemIDs(of: digest), [newest, middle, oldest])
    }

    func testTriagedItemsSortAboveEverythingElse() throws {
        let ordinary = try seed(at: base.addingTimeInterval(500))
        let important = try seed(at: base.addingTimeInterval(100))

        // Older, but the rules called it important — so it leads.
        let digest = try XCTUnwrap(try build(triage: PinningTriage(pinned: [important])))
        XCTAssertEqual(try itemIDs(of: digest), [important, ordinary])
    }

    func testMutedAppsSinkBelowEverythingElse() throws {
        let mutedAppID = try seedApp(bundleID: "com.example.Noisy", muted: true)
        let noisy = try seed(at: base.addingTimeInterval(500), appID: mutedAppID)
        let ordinary = try seed(at: base.addingTimeInterval(100))

        // Newer, but muted — so it goes last.
        let digest = try XCTUnwrap(try build())
        XCTAssertEqual(try itemIDs(of: digest), [ordinary, noisy])
    }

    // MARK: - The cap

    func testTheHeadlineCountsEverythingButOnlyTheCapIsStored() throws {
        let total = DigestEngine.shownCap + 12
        for index in 0 ..< total {
            try seed(at: base.addingTimeInterval(Double(index + 1)))
        }

        let digest = try XCTUnwrap(try build())
        XCTAssertEqual(digest.itemCount, total, "the headline number is what was missed, not what fits")
        XCTAssertEqual(try itemIDs(of: digest).count, DigestEngine.shownCap)
    }

    func testRanksAreTheDisplayOrderStartingAtZero() throws {
        for index in 0 ..< 3 {
            try seed(at: base.addingTimeInterval(Double(index + 1)))
        }
        let digest = try XCTUnwrap(try build())
        let ranks = try archive().pool.read { db in
            try DigestItem
                .filter(Column("digest_id") == digest.id)
                .order(Column("rank"))
                .fetchAll(db)
                .map(\.rank)
        }
        XCTAssertEqual(ranks, [0, 1, 2])
    }

    // MARK: - Session linking

    func testStragglersOutsideTheWindowAreClaimedByTheDigest() throws {
        // Inside the window: already linked when the session was recorded. Outside it and
        // unpresented: only the digest can claim it.
        let inside = try seed(at: base.addingTimeInterval(300))
        let straggler = try seed(at: base.addingTimeInterval(-60), presented: false)

        let stored = try session(from: base, to: base.addingTimeInterval(600))
        try archive().linkNotifications(to: stored)
        XCTAssertNil(try awaySessionID(of: straggler), "the exact window does not reach it")

        try DigestEngine(archive: archive()).build(for: stored)
        XCTAssertEqual(try awaySessionID(of: inside), stored.id)
        XCTAssertEqual(try awaySessionID(of: straggler), stored.id)
    }

    func testItemsBeyondTheCapAreStillLinked() throws {
        let total = DigestEngine.shownCap + 5
        var ids: [Int64] = []
        for index in 0 ..< total {
            try ids.append(seed(at: base.addingTimeInterval(Double(index + 1))))
        }
        let stored = try session(from: base, to: base.addingTimeInterval(600))
        try DigestEngine(archive: archive()).build(for: stored)

        // The tail is not shown, but `is:missed` still has to find it.
        for id in ids {
            XCTAssertEqual(try awaySessionID(of: id), stored.id)
        }
    }

    // MARK: - Cascades

    func testDeletingADigestTakesItsItemsAndNotThePayload() throws {
        try seed(at: base.addingTimeInterval(300))
        let digest = try XCTUnwrap(try build())

        try archive().pool.write { db in
            _ = try Digest.deleteOne(db, key: digest.id)
        }
        let items = try archive().pool.read { db in try DigestItem.fetchCount(db) }
        let notifications = try archive().pool.read { db in try ArchivedNotification.fetchCount(db) }
        XCTAssertEqual(items, 0)
        XCTAssertEqual(notifications, 1, "a digest is a view of notifications, not their owner")
    }

    // MARK: Private

    /// Marks a chosen set as pinned, standing in for `RulesEngine` until it ships.
    private struct PinningTriage: TriageEvaluating {
        let pinned: Set<Int64>

        func evaluate(_ notification: ArchivedNotification) -> Triage {
            guard let id = notification.id, pinned.contains(id) else {
                return .none
            }
            return Triage(pinned: true)
        }
    }

    private enum SeedFailure: Error {
        case noRowID
    }

    private var archiveStorage: Archive?
    private var appIDStorage: Int64?

    private let base = Date(timeIntervalSince1970: 1_755_600_000)

    private func archive() throws -> Archive {
        try XCTUnwrap(archiveStorage)
    }

    private func seedApp(bundleID: String = "com.example.Chat", muted: Bool = false) throws -> Int64 {
        try archive().pool.write { db in
            var app = AppRecord(
                bundleId: bundleID,
                displayName: bundleID,
                isMuted: muted,
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
    private func seed(
        at delivered: Date,
        appID: Int64? = nil,
        presented: Bool = true,
        isDeleted: Bool = false
    ) throws -> Int64 {
        let owner = try appID ?? XCTUnwrap(appIDStorage)
        return try archive().pool.write { db in
            var row = ArchivedNotification(
                uuid: UUID().uuidString,
                appId: owner,
                title: "Seed",
                deliveredAt: UnixDate(delivered),
                capturedAt: UnixDate(delivered),
                presented: presented,
                isDeleted: isDeleted
            )
            try row.insert(db)
            guard let id = row.id else {
                throw SeedFailure.noRowID
            }
            return id
        }
    }

    private func session(
        from start: Date,
        to end: Date,
        reason: AwayReason = .locked
    ) throws -> AwaySession {
        try archive().insertAwaySession(
            AwaySession(startedAt: UnixDate(start), endedAt: UnixDate(end), reason: reason)
        )
    }

    /// Builds a digest for the standard 10-minute session these cases share.
    private func build(triage: any TriageEvaluating = NoTriage()) throws -> Digest? {
        let stored = try session(from: base, to: base.addingTimeInterval(600))
        return try DigestEngine(archive: archive(), triage: triage).build(for: stored)
    }

    private func itemIDs(of digest: Digest) throws -> [Int64] {
        try archive().pool.read { db in
            try DigestItem
                .filter(Column("digest_id") == digest.id)
                .order(Column("rank"))
                .fetchAll(db)
                .map(\.notificationId)
        }
    }

    private func awaySessionID(of notificationID: Int64) throws -> Int64? {
        try archive().pool.read { db in
            try ArchivedNotification.fetchOne(db, key: notificationID)?.awaySessionId
        }
    }
}
