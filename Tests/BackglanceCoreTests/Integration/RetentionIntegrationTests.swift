@testable import BackglanceCore
import BackglanceTestSupport
import Foundation
import GRDB
import XCTest

// MARK: - RetentionIntegrationTests

/// At-scale companion to `RetentionJobTests`: the same job, run over a seeded
/// 20,000-row archive, so a regression under real batching has somewhere to fail.
///
/// 🔒 The headline assertion is FTS parity: `notifications_fts`'s row count has to equal
/// `notifications`'s after a full run. A cascade that fails to fire `notifications_ad`
/// on a batched `DELETE` is easy to miss at ten rows and easy to hit at ten thousand.
///
/// See docs/testing/TESTING.md#retention-tests.
final class RetentionIntegrationTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - Cascades, at scale

    /// 🔒 The trace a failed cascade leaves behind: an FTS posting for a notification
    /// that no longer exists, at a scale where the batched delete loop actually runs.
    func testFTSStaysInParityWithNotificationsAfterAFullPass() async throws {
        let archive = try XCTUnwrap(archive)
        _ = try await seedLargeArchive()
        let job = try makeJob()

        _ = try await job.prune()
        _ = try await job.prune()

        let notifications = try count(in: archive)
        XCTAssertGreaterThan(notifications, 0, "a parity of zero and zero would prove nothing")
        XCTAssertEqual(try ftsCount(in: archive), notifications)
    }

    /// 🔒 A `redactions`, `digest_items` or `embeddings` row whose notification is gone
    /// is the same failure as an FTS orphan, just in a table nobody thinks to check.
    /// Caught with a `LEFT JOIN`, which finds an orphan whatever produced it.
    func testNoDerivedRowOutlivesTheNotificationItDescribes() async throws {
        let archive = try XCTUnwrap(archive)
        _ = try await seedLargeArchive()
        let job = try makeJob()

        _ = try await job.prune()
        _ = try await job.prune()

        for table in Self.derivedTables {
            XCTAssertEqual(try orphanCount(in: archive, table: table), 0, table)
        }
    }

    /// Cascade at scale, both directions: a survivor keeps its derived data, a
    /// hard-pruned row loses it — checked for a set spanning both outcomes, so a
    /// cascade that only fires on one side of the cutoff cannot pass by accident.
    func testDerivedDataFollowsWhicheverSideOfTheCutoffItsNotificationLandedOn() async throws {
        let archive = try XCTUnwrap(archive)
        let seed = try await seedLargeArchive()
        let expectedBefore = seed.derivedExpiredIDs.count + seed.derivedSurvivingIDs.count
        for table in Self.derivedTables {
            XCTAssertEqual(try tableCount(in: archive, table), expectedBefore, "\(table) before pruning")
        }
        let job = try makeJob()

        _ = try await job.prune()
        _ = try await job.prune()

        for table in Self.derivedTables {
            XCTAssertEqual(
                try derivedCount(in: archive, table: table, for: seed.derivedSurvivingIDs),
                seed.derivedSurvivingIDs.count,
                "\(table), surviving side"
            )
            XCTAssertEqual(
                try derivedCount(in: archive, table: table, for: seed.derivedExpiredIDs),
                0,
                "\(table), expired side"
            )
        }
    }

    // MARK: - The policy matrix, at scale

    /// Every branch `RetentionJob` can take, on the same archive: `days30`, `forever`,
    /// `hours24`, pins, and rows the user had already soft-deleted before the job ran.
    func testEveryAppSurvivesExactlyWhatItsPolicyAndTheUserSaid() async throws {
        let archive = try XCTUnwrap(archive)
        let seed = try await seedLargeArchive()
        let job = try makeJob()

        _ = try await job.prune()
        _ = try await job.prune()

        let live = try liveIDs(in: archive)

        // 🔒 `forever` keeps everything except what the user deleted themselves.
        XCTAssertTrue(live.isDisjoint(with: seed.foreverPreDeletedIDs), "a soft delete overrides forever")
        let foreverSurvivors = seed.foreverIDs.subtracting(seed.foreverPreDeletedIDs)
        XCTAssertEqual(live.intersection(foreverSurvivors), foreverSurvivors, "forever, minus the user's own deletes")

        // Pinned rows are all past the global cutoff and survive anyway.
        XCTAssertEqual(live.intersection(seed.pinnedIDs), seed.pinnedIDs, "pinned rows")

        // `hours24`: everything past its day-old cutoff is gone, everything inside it stays.
        XCTAssertTrue(live.isDisjoint(with: seed.hours24ExpiredIDs), "hours24, past its cutoff")
        XCTAssertEqual(
            live.intersection(seed.hours24SurvivingIDs),
            seed.hours24SurvivingIDs,
            "hours24, inside its cutoff"
        )

        // `days30`: expired rows gone except the pins, surviving rows untouched.
        XCTAssertTrue(
            live.isDisjoint(with: seed.defaultExpiredIDs.subtracting(seed.pinnedIDs)),
            "days30, past its cutoff and unpinned"
        )
        let defaultSurvivors = seed.defaultSurvivingIDs.subtracting(seed.allPreDeletedIDs)
        XCTAssertEqual(live.intersection(defaultSurvivors), defaultSurvivors, "days30, inside its cutoff")

        // 🔒 The user's own soft deletes are gone regardless of bucket or age.
        XCTAssertTrue(live.isDisjoint(with: seed.allPreDeletedIDs), "the user's own soft deletes")
    }

    /// `apps.notification_count` is what the privacy panes and the app filter show.
    /// Checked per app against a plain `COUNT(*)`, not against the job's own report.
    func testAppCountersMatchLiveRowsAfterAPruneAtScale() async throws {
        let archive = try XCTUnwrap(archive)
        _ = try await seedLargeArchive()
        let job = try makeJob()

        _ = try await job.prune()
        _ = try await job.prune()

        for app in try archive.allApps() {
            let appID = try XCTUnwrap(app.id)
            XCTAssertEqual(app.notificationCount, try liveCount(in: archive, appID: appID), app.bundleId)
        }
    }

    // MARK: - Timing

    /// 🔒 Gated behind `PerfGate`, whose doc comment explains why a wall-clock budget
    /// skips on a shared runner rather than failing on it.
    func testAFullPassOverTheSeededArchiveCompletesWithinBudget() async throws {
        try XCTSkipUnless(PerfGate.isEnabled, "wall-clock budgets only run with BACKGLANCE_PERF=1")
        _ = try await seedLargeArchive()
        let job = try makeJob()

        let start = Date()
        _ = try await job.prune()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, PerfGate.threshold(0.5))
    }

    // MARK: Private

    private static let now = Date(timeIntervalSince1970: 1_787_236_200)
    private static let immediate = RetentionJob.Schedule(launchDelay: 0, interval: 3_600)
    private static let derivedTables = ["redactions", "digest_items", "embeddings"]

    private var archive: Archive?

    private func makeJob() throws -> RetentionJob {
        try RetentionJob(
            archive: XCTUnwrap(archive),
            defaults: throwawayDefaults(),
            schedule: Self.immediate
        ) { Self.now }
    }

    /// Builds the 20,000-row archive every test above shares: three apps set up here,
    /// the five age buckets that populate them handed off to `seedAllBuckets`.
    private func seedLargeArchive() async throws -> SeedResult {
        let archive = try XCTUnwrap(archive)
        let defaultApp = try archive.upsertApp(bundleID: "com.example.default", now: Self.now)
        let foreverApp = try archive.upsertApp(bundleID: "com.example.forever", now: Self.now)
        let hours24App = try archive.upsertApp(bundleID: "com.example.hours24", now: Self.now)
        try archive.setRetention(.policy(.forever), bundleID: "com.example.forever")
        try archive.setRetention(.policy(.hours24), bundleID: "com.example.hours24")
        let defaultAppID = try XCTUnwrap(defaultApp.id)
        let foreverAppID = try XCTUnwrap(foreverApp.id)
        let hours24AppID = try XCTUnwrap(hours24App.id)
        let now = Self.now

        // One transaction for all twenty thousand rows, not a commit per row: setup
        // is not the thing the batched-transaction design below exists to test.
        return try await archive.pool.write { db in
            try seedAllBuckets(
                db,
                defaultAppID: defaultAppID,
                foreverAppID: foreverAppID,
                hours24AppID: hours24AppID,
                now: now
            )
        }
    }

    private func count(in archive: Archive) throws -> Int {
        try archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
    }

    private func liveIDs(in archive: Archive) throws -> Set<Int64> {
        try archive.pool.read { db in
            try Set(Int64.fetchAll(db, sql: "SELECT id FROM notifications WHERE is_deleted = 0"))
        }
    }

    private func liveCount(in archive: Archive, appID: Int64) throws -> Int {
        try archive.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM notifications WHERE app_id = ? AND is_deleted = 0",
                arguments: [appID]
            ) ?? -1
        }
    }

    /// A plain `SELECT count(*)` on an FTS5 table scans it, which is what parity needs:
    /// the total number of postings, not how many mention a particular word.
    private func ftsCount(in archive: Archive) throws -> Int {
        try archive.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM notifications_fts") ?? -1
        }
    }

    private func tableCount(in archive: Archive, _ table: String) throws -> Int {
        try archive.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? -1
        }
    }

    /// A row in `table` whose `notification_id` no longer names a live notification.
    private func orphanCount(in archive: Archive, table: String) throws -> Int {
        try archive.pool.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT count(*) FROM \(table) t
                LEFT JOIN notifications n ON n.id = t.notification_id
                 WHERE n.id IS NULL
                """
            ) ?? -1
        }
    }

    private func derivedCount(in archive: Archive, table: String, for ids: Set<Int64>) throws -> Int {
        guard !ids.isEmpty else {
            return 0
        }
        let placeholders = databaseQuestionMarks(count: ids.count)
        return try archive.pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM \(table) WHERE notification_id IN (\(placeholders))",
                arguments: StatementArguments(Array(ids))
            ) ?? -1
        }
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

// MARK: - BucketSpec

/// What one call to `seedBucket` needs: which app, how many rows, what ages, and which
/// index windows — if any — get pinned, pre-deleted, or fitted with derived data.
private struct BucketSpec {
    let appID: Int64
    let count: Int
    let age: AgeWindow
    var pinned: Range<Int> = 0 ..< 0
    var preDeleted: Range<Int> = 0 ..< 0
    var derived: Range<Int> = 0 ..< 0
}

// MARK: - BucketIDs

/// What one `seedBucket` call produced, so `seedLargeArchive()` can fold several
/// buckets into a `SeedResult` without re-deriving which ids landed where.
private struct BucketIDs {
    var all: Set<Int64> = []
    var pinned: Set<Int64> = []
    var preDeleted: Set<Int64> = []
    var derived: Set<Int64> = []
}

// MARK: - SeedResult

/// The ids `seedLargeArchive()` produced, grouped by what the tests above check them
/// against — not a general-purpose seed report, just the sets those assertions use.
private struct SeedResult {
    let defaultExpiredIDs: Set<Int64>
    let defaultSurvivingIDs: Set<Int64>
    let foreverIDs: Set<Int64>
    let foreverPreDeletedIDs: Set<Int64>
    let pinnedIDs: Set<Int64>
    let hours24ExpiredIDs: Set<Int64>
    let hours24SurvivingIDs: Set<Int64>
    let allPreDeletedIDs: Set<Int64>
    let derivedExpiredIDs: Set<Int64>
    let derivedSurvivingIDs: Set<Int64>
}

// MARK: - AgeWindow

/// A range of possible ages for a seeded row, in whole days or whole hours rather than
/// raw seconds.
private struct AgeWindow {
    // MARK: Internal

    static func days(_ range: ClosedRange<Int>) -> AgeWindow {
        AgeWindow(range: range, unit: 86_400)
    }

    static func hours(_ range: ClosedRange<Int>) -> AgeWindow {
        AgeWindow(range: range, unit: 3_600)
    }

    /// One random age drawn uniformly from the window.
    func sample(using random: inout SplitMix64) -> TimeInterval {
        let span = range.upperBound - range.lowerBound + 1
        return TimeInterval(range.lowerBound + random.int(below: span)) * unit
    }

    // MARK: Private

    private let range: ClosedRange<Int>
    private let unit: TimeInterval
}

// MARK: - Seeding helpers

/// The five buckets `seedLargeArchive()` needs, folded into one `SeedResult`.
private func seedAllBuckets(
    _ db: Database,
    defaultAppID: Int64,
    foreverAppID: Int64,
    hours24AppID: Int64,
    now: Date
) throws -> SeedResult {
    var random = SplitMix64(seed: 0x5EED_0173)

    func bucket(_ spec: BucketSpec) throws -> BucketIDs {
        try seedBucket(db, spec, now: now, random: &random)
    }

    // The global default (`days30`), either side of its cutoff: pinned and
    // already-soft-deleted rows carved out of the expired end, derived data on both.
    var defaultExpiredSpec = BucketSpec(appID: defaultAppID, count: 7_000, age: .days(31 ... 90))
    defaultExpiredSpec.pinned = 0 ..< 50
    defaultExpiredSpec.preDeleted = 50 ..< 100
    defaultExpiredSpec.derived = 100 ..< 200
    let defaultExpired = try bucket(defaultExpiredSpec)

    var defaultSurvivingSpec = BucketSpec(appID: defaultAppID, count: 7_000, age: .days(1 ... 29))
    defaultSurvivingSpec.preDeleted = 0 ..< 50
    defaultSurvivingSpec.derived = 50 ..< 150
    let defaultSurviving = try bucket(defaultSurvivingSpec)

    // `forever`: far past any cutoff, except the slice the user deleted themselves,
    // which should go regardless.
    var foreverSpec = BucketSpec(appID: foreverAppID, count: 3_000, age: .days(400 ... 999))
    foreverSpec.preDeleted = 0 ..< 30
    let forever = try bucket(foreverSpec)

    // `hours24`, either side of its own, much shorter cutoff.
    let hours24Expired = try bucket(BucketSpec(appID: hours24AppID, count: 1_500, age: .hours(25 ... 72)))
    let hours24Surviving = try bucket(BucketSpec(appID: hours24AppID, count: 1_500, age: .hours(1 ... 23)))

    return SeedResult(
        defaultExpiredIDs: defaultExpired.all,
        defaultSurvivingIDs: defaultSurviving.all,
        foreverIDs: forever.all,
        foreverPreDeletedIDs: forever.preDeleted,
        pinnedIDs: defaultExpired.pinned,
        hours24ExpiredIDs: hours24Expired.all,
        hours24SurvivingIDs: hours24Surviving.all,
        allPreDeletedIDs: defaultExpired.preDeleted
            .union(defaultSurviving.preDeleted)
            .union(forever.preDeleted),
        derivedExpiredIDs: defaultExpired.derived,
        derivedSurvivingIDs: defaultSurviving.derived
    )
}

/// One bucket of same-shaped rows: `spec.count` rows for `spec.appID`, aged uniformly
/// within `spec.age`, with `spec`'s disjoint index windows marking a row pinned,
/// already soft-deleted, or fitted with derived data.
private func seedBucket(
    _ db: Database,
    _ spec: BucketSpec,
    now: Date,
    random: inout SplitMix64
) throws -> BucketIDs {
    var ids = BucketIDs()
    for index in 0 ..< spec.count {
        let deliveredAt = now.addingTimeInterval(-spec.age.sample(using: &random))
        let isPinned = spec.pinned.contains(index)
        let isDeleted = spec.preDeleted.contains(index)
        let id = try insertNotification(
            db,
            appID: spec.appID,
            uuid: random.uuid().uuidString,
            deliveredAt: deliveredAt,
            isPinned: isPinned,
            isDeleted: isDeleted
        )
        ids.all.insert(id)
        if isPinned {
            ids.pinned.insert(id)
        }
        if isDeleted {
            ids.preDeleted.insert(id)
        }
        if spec.derived.contains(index) {
            try attachDerivedData(db, notificationID: id, now: now)
            ids.derived.insert(id)
        }
    }
    return ids
}

/// Raw SQL rather than `Archive.insertOrUpdate`, whose per-row duplicate lookup would
/// make seeding twenty thousand rows the slow part of this file.
private func insertNotification(
    _ db: Database,
    appID: Int64,
    uuid: String,
    deliveredAt: Date,
    isPinned: Bool,
    isDeleted: Bool
) throws -> Int64 {
    let delivered = deliveredAt.timeIntervalSince1970
    try db.execute(
        sql: """
        INSERT INTO notifications
            (uuid, app_id, title, body, delivered_at, captured_at, is_pinned, is_deleted)
        VALUES (?, ?, 'Fixture', 'Fixture body', ?, ?, ?, ?)
        """,
        arguments: [uuid, appID, delivered, delivered, isPinned, isDeleted]
    )
    return db.lastInsertedRowID
}

/// Attaches one of every kind of row a notification can own — a redaction event, an
/// away session and digest item, and an embedding — the same shape
/// `RetentionJobTests.seedWithEverything()` builds one of.
private func attachDerivedData(_ db: Database, notificationID: Int64, now: Date) throws {
    let moment = now.timeIntervalSince1970
    try db.execute(
        sql: "INSERT INTO redactions (notification_id, kind, pattern_id, redacted_at) VALUES (?, 'otp', 'otp.bare', ?)",
        arguments: [notificationID, moment]
    )
    try db.execute(
        sql: "INSERT INTO away_sessions (started_at, ended_at, reason) VALUES (?, ?, 'locked')",
        arguments: [moment, moment + 600]
    )
    let sessionID = db.lastInsertedRowID
    try db.execute(
        sql: "INSERT INTO digests (away_session_id, created_at, item_count) VALUES (?, ?, 1)",
        arguments: [sessionID, moment]
    )
    let digestID = db.lastInsertedRowID
    try db.execute(
        sql: "INSERT INTO digest_items (digest_id, notification_id, rank) VALUES (?, ?, 0)",
        arguments: [digestID, notificationID]
    )
    try db.execute(
        sql: """
        INSERT INTO embeddings (notification_id, model, dims, vector, created_at)
        VALUES (?, ?, ?, ?, ?)
        """,
        arguments: [
            notificationID,
            Embedding.currentModel,
            Embedding.dimensions,
            Data(count: Embedding.dimensions * MemoryLayout<Float>.size),
            moment,
        ]
    )
}
