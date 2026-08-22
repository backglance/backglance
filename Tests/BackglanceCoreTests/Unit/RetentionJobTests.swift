@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

/// Covers `RetentionJob` — the only thing in Backglance that deletes a notification the
/// user did not ask it to delete.
///
/// 🔒 Two claims are load-bearing and are tested separately from everything else: that a
/// row survives one pass before it is removed for real, and that removing it takes its
/// derived data with it. A prune that left an FTS posting or an embedding behind would
/// leave a machine-readable trace of a notification the user believes is gone.
///
/// The clock is injected rather than slept on, so "thirty-one days old" is a fact about
/// the row rather than about how long the suite ran.
///
/// See docs/features/PRIVACY_CONTROLS.md#retentionjob.
final class RetentionJobTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - The two phases

    /// 🔒 One pass flags, it does not remove. The row is invisible everywhere that filters
    /// `is_deleted = 0`, and still on disk — which is the window a mistake can be undone
    /// in.
    func testAnExpiredRowIsFlaggedByTheFirstPassAndStillPresent() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(bundleID: "com.example.chat", ages: [-40 * day])

        let report = try await makeJob().prune()

        XCTAssertEqual(report.softDeleted, 1)
        XCTAssertEqual(report.hardDeleted, 0)
        XCTAssertEqual(try count(in: archive), 1, "still on disk")
        XCTAssertEqual(try liveCount(in: archive), 0, "and invisible to everything that reads")
    }

    /// The second pass is what removes it. Two passes, not one — a design that would be
    /// pointless if either pass did both halves.
    func testTheSecondPassRemovesWhatTheFirstFlagged() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(bundleID: "com.example.chat", ages: [-40 * day])
        let job = try makeJob()
        _ = try await job.prune()

        let report = try await job.prune()

        XCTAssertEqual(report.hardDeleted, 1)
        XCTAssertEqual(try count(in: archive), 0)
    }

    func testARowInsideItsWindowIsUntouched() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(bundleID: "com.example.chat", ages: [-2 * day])

        _ = try await makeJob().prune()
        _ = try await makeJob().prune()

        XCTAssertEqual(try liveCount(in: archive), 1)
    }

    /// The boundary, stated: thirty days exactly is not "older than thirty days".
    func testARowExactlyAtTheCutoffSurvives() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(bundleID: "com.example.chat", ages: [-30 * day])

        _ = try await makeJob().prune()

        XCTAssertEqual(try liveCount(in: archive), 1)
    }

    // MARK: - What is exempt

    /// 🔒 Pinning is the user saying "keep this". A policy they set for an app in general
    /// does not overrule a decision they made about one notification in particular.
    func testAPinnedRowIsNeverExpiredByAge() async throws {
        let archive = try XCTUnwrap(archive)
        let ids = try seed(bundleID: "com.example.chat", ages: [-400 * day])
        try await archive.pool.write { db in
            try db.execute(sql: "UPDATE notifications SET is_pinned = 1 WHERE id = ?", arguments: [ids[0]])
        }

        _ = try await makeJob().prune()
        _ = try await makeJob().prune()

        XCTAssertEqual(try liveCount(in: archive), 1)
    }

    /// And unpinning makes it eligible again, rather than exempting it forever.
    func testUnpinningMakesARowEligibleOnTheNextPass() async throws {
        let archive = try XCTUnwrap(archive)
        let ids = try seed(bundleID: "com.example.chat", ages: [-400 * day])
        try await archive.pool.write { db in
            try db.execute(sql: "UPDATE notifications SET is_pinned = 1 WHERE id = ?", arguments: [ids[0]])
        }
        _ = try await makeJob().prune()
        try await archive.pool.write { db in
            try db.execute(sql: "UPDATE notifications SET is_pinned = 0 WHERE id = ?", arguments: [ids[0]])
        }

        _ = try await makeJob().prune()

        XCTAssertEqual(try liveCount(in: archive), 0)
    }

    func testAnAppSetToForeverKeepsEverything() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(bundleID: "com.example.chat", ages: [-400 * day])
        try archive.setRetention(.policy(.forever), bundleID: "com.example.chat")

        _ = try await makeJob().prune()

        XCTAssertEqual(try liveCount(in: archive), 1)
    }

    /// A per-app override that keeps *less* than the global is the case worth pinning: a
    /// job that took the longer of the two would silently ignore the stricter setting.
    func testAnAppOverrideThatKeepsLessThanTheGlobalIsHonoured() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(bundleID: "com.example.chat", ages: [-2 * day])
        try archive.setRetention(.policy(.hours24), bundleID: "com.example.chat")

        _ = try await makeJob().prune()

        XCTAssertEqual(try liveCount(in: archive), 0)
    }

    func testTheGlobalPolicyAppliesToAppsWithNoOverride() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(bundleID: "com.example.chat", ages: [-10 * day])
        let defaults = try throwawayDefaults()
        RetentionSettings.save(global: .days7, to: defaults)

        _ = try await makeJob(defaults: defaults).prune()

        XCTAssertEqual(try liveCount(in: archive), 0)
    }

    // MARK: - The undo window

    /// 🔒 A row the user soft-deleted moments ago may still have a visible "Undo".
    /// Hard-deleting it would make that button lie, so the job is told what not to touch.
    func testAProtectedRowIsNotHardDeleted() async throws {
        let archive = try XCTUnwrap(archive)
        let ids = try seed(bundleID: "com.example.chat", ages: [-40 * day, -40 * day])
        _ = try await makeJob().prune()
        let spared = ids[0]

        let report = try await makeJob(protecting: [spared]).prune()

        XCTAssertEqual(report.hardDeleted, 1)
        XCTAssertEqual(try count(in: archive), 1)
        let survivor = try await archive.pool.read { db in try Int64.fetchOne(db, sql: "SELECT id FROM notifications") }
        XCTAssertEqual(survivor, spared)
    }

    /// And it is a *delay*, not an exemption: once the undo window closes, the next pass
    /// takes it.
    func testAProtectedRowIsRemovedOnceItIsNoLongerProtected() async throws {
        let archive = try XCTUnwrap(archive)
        let ids = try seed(bundleID: "com.example.chat", ages: [-40 * day])
        _ = try await makeJob().prune()
        _ = try await makeJob(protecting: [ids[0]]).prune()

        _ = try await makeJob().prune()

        XCTAssertEqual(try count(in: archive), 0)
    }

    // MARK: - Cascades

    /// 🔒 The claim that matters most. A hard delete has to take everything derived from
    /// the notification with it — the FTS postings by trigger, the audit row, the digest
    /// item and the embedding by foreign key. Anything left behind is a machine-readable
    /// trace of a notification the user believes is gone.
    func testAHardDeleteTakesTheDerivedDataWithIt() async throws {
        let archive = try XCTUnwrap(archive)
        let id = try seedWithEverything()
        XCTAssertEqual(try ftsCount(in: archive), 1)
        XCTAssertEqual(try tableCount(in: archive, "redactions"), 1)
        XCTAssertEqual(try tableCount(in: archive, "digest_items"), 1)
        XCTAssertEqual(try tableCount(in: archive, "embeddings"), 1)

        let job = try makeJob()
        _ = try await job.prune()
        _ = try await job.prune()

        XCTAssertEqual(try count(in: archive), 0, "the notification")
        XCTAssertEqual(try ftsCount(in: archive), 0, "its FTS postings")
        XCTAssertEqual(try tableCount(in: archive, "redactions"), 0, "its audit row")
        XCTAssertEqual(try tableCount(in: archive, "digest_items"), 0, "its digest item")
        XCTAssertEqual(try tableCount(in: archive, "embeddings"), 0, "its embedding")
        XCTAssertNotNil(id)
    }

    /// The soft-delete half leaves the derived data alone, which is what makes the window
    /// between the two passes a window rather than a slower way of doing the same thing.
    func testASoftDeleteLeavesTheDerivedDataInPlace() async throws {
        let archive = try XCTUnwrap(archive)
        _ = try seedWithEverything()

        _ = try await makeJob().prune()

        XCTAssertEqual(try tableCount(in: archive, "embeddings"), 1)
        XCTAssertEqual(try tableCount(in: archive, "redactions"), 1)
    }

    // MARK: - Counters and reporting

    /// `apps.notification_count` is what the privacy panes and the app filter show. A
    /// prune is the one thing that can make it wrong, so a prune is what puts it right.
    func testTheAppCounterFollowsAPrune() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(bundleID: "com.example.chat", ages: [-40 * day, -40 * day, -1 * day])
        XCTAssertEqual(try storedCount(in: archive, bundleID: "com.example.chat"), 3)

        _ = try await makeJob().prune()

        XCTAssertEqual(try storedCount(in: archive, bundleID: "com.example.chat"), 1)
    }

    func testAPassOverAnEmptyArchiveReportsNothing() async throws {
        let report = try await makeJob().prune()

        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.appsScanned, 0)
    }

    func testEveryAppIsScannedEvenWhenNoneExpire() async throws {
        try seed(bundleID: "com.example.chat", ages: [-1 * day])
        try seed(bundleID: "com.example.other", ages: [-1 * day])

        let report = try await makeJob().prune()

        XCTAssertEqual(report.appsScanned, 2)
        XCTAssertTrue(report.isEmpty)
    }

    /// A batch boundary is where an off-by-one hides. More rows than `batchSize` in one
    /// app has to come out to exactly the number that expired.
    func testAPruneLargerThanOneBatchRemovesEverythingExpired() async throws {
        let archive = try XCTUnwrap(archive)
        let expired = RetentionJob.batchSize + 7
        try seed(bundleID: "com.example.chat", ages: Array(repeating: -40 * day, count: expired) + [-1 * day])

        let first = try await makeJob().prune()
        let second = try await makeJob().prune()

        XCTAssertEqual(first.softDeleted, expired)
        XCTAssertEqual(second.hardDeleted, expired)
        XCTAssertEqual(try count(in: archive), 1)
    }

    // MARK: - Failure posture

    /// 🔒 `runOnce()` is what the launch loop and the settings button call, and neither has
    /// an answer to a thrown error beyond "try again later" — so it does not throw one. A
    /// failed pass deletes nothing and reports nothing.
    func testRunOnceOverAClosedArchiveReportsNothingRatherThanThrowing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetentionJobTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("archive.sqlite")
        let doomed = try Archive(path: url.path)
        let job = try RetentionJob(archive: doomed, defaults: throwawayDefaults(), schedule: Self.immediate)
        try FileManager.default.removeItem(at: url)

        let report = await job.runOnce()

        XCTAssertTrue(report.isEmpty)
    }

    // MARK: Private

    private static let now = Date(timeIntervalSince1970: 1_787_236_200)
    private static let immediate = RetentionJob.Schedule(launchDelay: 0, interval: 3_600)

    private let day: TimeInterval = 86_400

    private var archive: Archive?

    private func makeJob(
        defaults: UserDefaults? = nil,
        protecting protected: Set<Int64> = []
    ) throws -> RetentionJob {
        try RetentionJob(
            archive: XCTUnwrap(archive),
            defaults: defaults ?? throwawayDefaults(),
            schedule: Self.immediate,
            protectedIDs: { protected },
            now: { Self.now }
        )
    }

    /// Inserts one notification per entry in `ages`, each `age` seconds from `now`.
    @discardableResult
    private func seed(bundleID: String, ages: [TimeInterval]) throws -> [Int64] {
        let archive = try XCTUnwrap(archive)
        let app = try archive.upsertApp(bundleID: bundleID, now: Self.now)
        let appID = try XCTUnwrap(app.id)
        return try ages.map { age in
            let delivered = Self.now.addingTimeInterval(age)
            let outcome = try archive.insertOrUpdate(ArchivedNotification(
                uuid: UUID().uuidString,
                appId: appID,
                title: "Fixture",
                body: "Fixture body",
                deliveredAt: UnixDate(delivered),
                capturedAt: UnixDate(delivered)
            ))
            guard case let .inserted(id) = outcome else {
                throw XCTSkip("seed did not insert")
            }
            return id
        }
    }

    /// One expired notification with every kind of derived row hanging off it.
    private func seedWithEverything() throws -> Int64 {
        let archive = try XCTUnwrap(archive)
        let app = try archive.upsertApp(bundleID: "com.example.chat", now: Self.now)
        let appID = try XCTUnwrap(app.id)
        let delivered = Self.now.addingTimeInterval(-40 * day)
        let outcome = try archive.insertOrUpdate(
            ArchivedNotification(
                uuid: UUID().uuidString,
                appId: appID,
                title: "Fixture",
                body: "Fixture body",
                deliveredAt: UnixDate(delivered),
                capturedAt: UnixDate(delivered)
            ),
            redaction: RedactionEvent(patternId: "otp.bare", redactedAt: UnixDate(delivered))
        )
        guard case let .inserted(id) = outcome else {
            throw XCTSkip("seed did not insert")
        }

        try archive.pool.write { db in
            try db.execute(
                sql: "INSERT INTO away_sessions (started_at, ended_at, reason) VALUES (?, ?, 'locked')",
                arguments: [delivered.timeIntervalSince1970, delivered.timeIntervalSince1970 + 600]
            )
            let sessionID = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO digests (away_session_id, created_at, item_count) VALUES (?, ?, 1)",
                arguments: [sessionID, delivered.timeIntervalSince1970]
            )
            let digestID = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO digest_items (digest_id, notification_id, rank) VALUES (?, ?, 0)",
                arguments: [digestID, id]
            )
        }
        try archive.upsertEmbedding(XCTUnwrap(Embedding(
            notificationId: id,
            values: (0 ..< Embedding.dimensions).map { Float($0 % 97) / 97 }
        )))
        return id
    }

    private func count(in archive: Archive) throws -> Int {
        try archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
    }

    private func liveCount(in archive: Archive) throws -> Int {
        try archive.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM notifications WHERE is_deleted = 0") ?? 0
        }
    }

    private func ftsCount(in archive: Archive) throws -> Int {
        try archive.pool.read { db in
            try Int
                .fetchOne(db, sql: "SELECT count(*) FROM notifications_fts WHERE notifications_fts MATCH 'Fixture'") ??
                0
        }
    }

    private func tableCount(in archive: Archive, _ table: String) throws -> Int {
        try archive.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? 0
        }
    }

    private func storedCount(in archive: Archive, bundleID: String) throws -> Int {
        try archive.allApps().first { $0.bundleId == bundleID }?.notificationCount ?? -1
    }

    private func throwawayDefaults() throws -> UserDefaults {
        let name = "app.backglance.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }
}
