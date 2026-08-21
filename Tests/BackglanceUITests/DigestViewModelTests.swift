@testable import BackglanceCore
import BackglanceTestSupport
@testable import BackglanceUI
import Foundation
import GRDB
import XCTest

/// Covers `DigestViewModel`: grouping, the muted split, the overflow count, the
/// subheadline's pieces, and the three writes the card can make.
///
/// `@testable import BackglanceCore` (in addition to `BackglanceUI`) is needed here
/// because `Digest`, `DigestItem` and `AwaySession` have no public initializer —
/// production code only ever gets one back from the archive or `DigestEngine`. This
/// suite has to build the rows `DigestEngine` would have written, the same way
/// `ArchiveDigestTests` and `DigestEngineTests` do on the Core side.
@MainActor
final class DigestViewModelTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archiveStorage = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archiveStorage = nil
        try super.tearDownWithError()
    }

    // MARK: - Grouping

    func testLoadGroupsRowsByAppPreservingRankOrder() throws {
        let appA = try app("com.example.A")
        let appB = try app("com.example.B")
        let a1 = try notification(appID: appA, delivered: base.addingTimeInterval(100))
        let b1 = try notification(appID: appB, delivered: base.addingTimeInterval(200))
        let a2 = try notification(appID: appA, delivered: base.addingTimeInterval(300))

        let stored = try session()
        let digest = try makeDigest(session: stored, itemCount: 3)
        // Rank order deliberately disagrees with delivery order: a1, b1, a2.
        try insertItems(digestID: XCTUnwrap(digest.id), ranked: [a1.id, b1.id, a2.id].compactMap { $0 })

        let vm = try makeViewModel(digest: digest, session: stored)
        vm.load()

        XCTAssertEqual(vm.appSections.map(\.appName), ["com.example.A", "com.example.B"])
        XCTAssertEqual(
            vm.appSections[0].items.map(\.id),
            [a1.id, a2.id].compactMap { $0 },
            "app A takes the position of its best-ranked row, and its own rows stay rank-ordered"
        )
        XCTAssertEqual(vm.appSections[1].items.map(\.id), [b1.id].compactMap { $0 })
    }

    func testMutedAppsGoToMutedItemsNeverToAppSections() throws {
        let mutedApp = try app("com.example.Muted", muted: true)
        let normalApp = try app("com.example.Normal")
        let mutedNotif = try notification(appID: mutedApp, delivered: base.addingTimeInterval(100))
        let normalNotif = try notification(appID: normalApp, delivered: base.addingTimeInterval(200))

        let stored = try session()
        let digest = try makeDigest(session: stored, itemCount: 2)
        try insertItems(
            digestID: XCTUnwrap(digest.id),
            ranked: [mutedNotif.id, normalNotif.id].compactMap { $0 }
        )

        let vm = try makeViewModel(digest: digest, session: stored)
        vm.load()

        XCTAssertEqual(vm.appSections.map(\.appName), ["com.example.Normal"], "a muted app never appears here")
        XCTAssertEqual(vm.mutedItems.map(\.id), [mutedNotif.id].compactMap { $0 })
        XCTAssertEqual(vm.mutedCount, 1)
    }

    // MARK: - overflowCount

    func testOverflowCountIsItemCountMinusTheRowsActuallyShown() throws {
        let appID = try app("com.example.A")
        let ids = try (0 ..< 3).map { try notification(appID: appID, delivered: base.addingTimeInterval(Double($0))) }

        let stored = try session()
        // itemCount reflects the whole selection (5); only 3 rows made it into digest_items.
        let digest = try makeDigest(session: stored, itemCount: 5)
        try insertItems(digestID: XCTUnwrap(digest.id), ranked: ids.compactMap(\.id))

        let vm = try makeViewModel(digest: digest, session: stored)
        vm.load()

        XCTAssertEqual(vm.overflowCount, 2)
    }

    func testOverflowCountIsClampedToZeroWhenItemCountIsSmallerThanTheLoadedRows() throws {
        let appID = try app("com.example.A")
        let ids = try (0 ..< 2).map { try notification(appID: appID, delivered: base.addingTimeInterval(Double($0))) }

        let stored = try session()
        // A stored count smaller than what is actually loaded — retention pruning is the
        // real-world cause; here it is forced directly to exercise the clamp.
        let digest = try makeDigest(session: stored, itemCount: 1)
        try insertItems(digestID: XCTUnwrap(digest.id), ranked: ids.compactMap(\.id))

        let vm = try makeViewModel(digest: digest, session: stored)
        vm.load()

        XCTAssertEqual(vm.overflowCount, 0, "'and -1 more' is never a sentence the card should say")
    }

    // MARK: - Subheadline and symbol

    func testSubheadlineJoinsItsPiecesWithoutHardcodingTheLocaleSpecificTime() throws {
        let duration: TimeInterval = 47 * 60
        let stored = try session(from: base, to: base.addingTimeInterval(duration), reason: .locked)
        let digest = try makeDigest(session: stored, itemCount: 0)

        let vm = try makeViewModel(digest: digest, session: stored)

        let expectedWhile = DigestViewModel.whileLabel(for: .locked)
        let expectedDuration = Duration.seconds(duration).formatted(.units(allowed: [.minutes], width: .abbreviated))
        let parts = vm.subheadline.components(separatedBy: " · ")

        XCTAssertEqual(parts.count, 3, "reason, duration and ended time — joined, not concatenated")
        XCTAssertEqual(parts[0], expectedWhile)
        XCTAssertEqual(parts[1], expectedDuration)
        XCTAssertTrue(parts[2].hasPrefix("ended "), "the third piece is the locale-formatted end time")
    }

    func testPrimaryReasonSymbolMatchesTheSessionsReason() throws {
        let lockedSession = try session(reason: .locked)
        let lockedDigest = try makeDigest(session: lockedSession, itemCount: 0)
        XCTAssertEqual(try makeViewModel(digest: lockedDigest, session: lockedSession).primaryReasonSymbol, "lock.fill")

        let focusSession = try session(reason: .focus)
        let focusDigest = try makeDigest(session: focusSession, itemCount: 0)
        XCTAssertEqual(try makeViewModel(digest: focusDigest, session: focusSession).primaryReasonSymbol, "moon.fill")
    }

    // MARK: - markShown()

    func testMarkShownStampsOnceAndKeepsTheFirstTimestamp() throws {
        let stored = try session()
        let digest = try makeDigest(session: stored, itemCount: 0)
        let clock = TestClock(now: base)
        let vm = try makeViewModel(digest: digest, session: stored, clock: clock)

        vm.markShown()
        let firstStamp = clock.now
        clock.advance(by: 3_600)
        vm.markShown()

        let reloaded = try XCTUnwrap(try fetchDigest(XCTUnwrap(digest.id)))
        XCTAssertEqual(reloaded.shownAt?.date, firstStamp, "reopening the card must not move shown_at")
    }

    // MARK: - dismiss()

    func testDismissSetsIsDismissedAndWritesDismissedAt() throws {
        let stored = try session()
        let digest = try makeDigest(session: stored, itemCount: 0)
        let clock = TestClock(now: base)
        let vm = try makeViewModel(digest: digest, session: stored, clock: clock)

        vm.dismiss()

        XCTAssertTrue(vm.isDismissed)
        let reloaded = try XCTUnwrap(try fetchDigest(XCTUnwrap(digest.id)))
        XCTAssertEqual(reloaded.dismissedAt?.date, base)
    }

    // MARK: - markAllRead()

    func testMarkAllReadMarksExactlyTheDigestsNotificationsAndLeavesTheRestUnread() throws {
        let appID = try app("com.example.A")
        let mutedAppID = try app("com.example.Muted", muted: true)
        let inDigest = try notification(appID: appID, delivered: base.addingTimeInterval(100))
        let inDigestMuted = try notification(appID: mutedAppID, delivered: base.addingTimeInterval(200))
        let outside = try notification(appID: appID, delivered: base.addingTimeInterval(300))

        let stored = try session()
        let digest = try makeDigest(session: stored, itemCount: 2)
        try insertItems(
            digestID: XCTUnwrap(digest.id),
            ranked: [inDigest.id, inDigestMuted.id].compactMap { $0 }
        )

        let vm = try makeViewModel(digest: digest, session: stored)
        vm.load()
        vm.markAllRead()

        XCTAssertTrue(try isRead(XCTUnwrap(inDigest.id)))
        XCTAssertTrue(try isRead(XCTUnwrap(inDigestMuted.id)), "muting de-prioritizes; it is still in the digest")
        XCTAssertFalse(try isRead(XCTUnwrap(outside.id)), "'mark all read' means this digest, not the timeline")
    }

    // MARK: - dayCounts

    func testDayCountsIsEmptyForASameDaySession() throws {
        // A fixed calendar, same as the multi-day case below: near-midnight UTC bases
        // must not make this flaky depending on where the test happens to run.
        let calendar = fixedCalendar
        let stored = try session(from: base, to: base.addingTimeInterval(2 * 3_600))
        let digest = try makeDigest(session: stored, itemCount: 0)

        let vm = try makeViewModel(digest: digest, session: stored, calendar: calendar)
        vm.load()

        XCTAssertTrue(vm.dayCounts.isEmpty, "a single-day breakdown would just repeat the headline")
    }

    func testDayCountsHasOneEntryPerLocalDayOldestFirstForAThreeDaySession() throws {
        let calendar = fixedCalendar
        let day1 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2_026, month: 3, day: 1, hour: 20)))
        let day2 = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day1))
        let day3 = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: day1))

        let stored = try session(
            from: calendar.date(byAdding: .hour, value: -1, to: day1) ?? day1,
            to: calendar.date(byAdding: .hour, value: 3, to: day3) ?? day3
        )
        let appID = try app("com.example.A")

        for offset in [0.0, 600.0] {
            try notification(appID: appID, delivered: day1.addingTimeInterval(offset), awaySessionID: stored.id)
        }
        try notification(appID: appID, delivered: day2.addingTimeInterval(300), awaySessionID: stored.id)
        for offset in [0.0, 600.0, 1_200.0] {
            try notification(appID: appID, delivered: day3.addingTimeInterval(offset), awaySessionID: stored.id)
        }

        let digest = try makeDigest(session: stored, itemCount: 0)
        let vm = try makeViewModel(digest: digest, session: stored, calendar: calendar)
        vm.load()

        XCTAssertEqual(vm.dayCounts.map(\.count), [2, 1, 3])
        XCTAssertEqual(
            vm.dayCounts.map(\.id),
            [day1, day2, day3].map(calendar.startOfDay(for:)),
            "oldest local day first"
        )
    }

    // MARK: Private

    private var archiveStorage: Archive?

    private let base = Date(timeIntervalSince1970: 1_755_600_000)

    /// A calendar pinned to a fixed timezone so a day-boundary assertion does not
    /// depend on where the machine running the tests happens to be.
    private var fixedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul") ?? .gmt
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    private func archive() throws -> Archive {
        try XCTUnwrap(archiveStorage)
    }

    private func makeViewModel(
        digest: Digest,
        session: AwaySession?,
        calendar: Calendar = .current,
        clock: TestClock? = nil
    ) throws -> DigestViewModel {
        let clock = clock ?? TestClock(now: base)
        return try DigestViewModel(
            archive: archive(),
            digest: digest,
            session: session,
            calendar: calendar
        ) { clock.now }
    }

    @discardableResult
    private func app(_ bundleID: String, muted: Bool = false) throws -> Int64 {
        var record = try archive().upsertApp(bundleID: bundleID, now: base)
        record.displayName = bundleID
        if muted {
            record.isMuted = true
        }
        try archive().pool.write { db in try record.update(db) }
        return try XCTUnwrap(record.id)
    }

    @discardableResult
    private func notification(
        appID: Int64,
        delivered: Date,
        awaySessionID: Int64? = nil,
        isRead: Bool = false
    ) throws -> ArchivedNotification {
        try archive().insert(ArchivedNotification(
            uuid: UUID().uuidString,
            appId: appID,
            title: "Seed",
            deliveredAt: UnixDate(delivered),
            capturedAt: UnixDate(delivered),
            awaySessionId: awaySessionID,
            isRead: isRead
        ))
    }

    private func session(
        from start: Date? = nil,
        to end: Date? = nil,
        reason: AwayReason = .locked
    ) throws -> AwaySession {
        try archive().insertAwaySession(
            AwaySession(
                startedAt: UnixDate(start ?? base),
                endedAt: UnixDate(end ?? base.addingTimeInterval(600)),
                reason: reason
            )
        )
    }

    private func makeDigest(session: AwaySession, itemCount: Int) throws -> Digest {
        try archive().pool.write { db in
            var digest = try Digest(
                awaySessionId: XCTUnwrap(session.id),
                createdAt: session.endedAt ?? UnixDate(self.base),
                itemCount: itemCount
            )
            try digest.insert(db)
            return digest
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
