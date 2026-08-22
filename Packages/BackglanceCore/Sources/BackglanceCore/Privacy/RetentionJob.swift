import Foundation
import GRDB

// MARK: - RetentionJob

/// The only thing in Backglance that deletes a notification nobody asked it to delete.
///
/// Two phases per pass, in this order:
///
/// 1. **Hard-delete** rows that were already soft-deleted — by an earlier pass, or by the
///    user.
/// 2. **Soft-delete** rows past their app's effective cutoff.
///
/// Hard first, soft second, which reads backwards until you follow one row through it. A
/// row that expires today is soft-deleted on this pass and hard-deleted on the *next* one,
/// at most six hours later. In between it is invisible everywhere — the timeline, search,
/// the digest and the unread badge all filter `is_deleted = 0` — but still on disk, which
/// is the window in which a mistake can be undone. Doing it the other way round would
/// collapse that window to nothing and make every pass immediately irreversible.
///
/// Everything is batched, because the alternative is one transaction that holds the writer
/// while a hundred thousand rows are rewritten, and the writer is the same one capture and
/// the timeline are waiting on. Five hundred rows at a time with a yield between batches
/// keeps a prune from being something the user can feel.
///
/// See docs/features/PRIVACY_CONTROLS.md#retentionjob.
public actor RetentionJob {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - archive: what gets pruned.
    ///   - defaults: where the global policy lives. Read at the top of every pass rather
    ///     than captured, so shortening the window applies on the next pass rather than
    ///     the next launch.
    ///   - schedule: when passes happen. Injectable so a test can drive the loop without
    ///     waiting six hours for the second one.
    ///   - protectedIDs: notification ids that must not be hard-deleted yet.
    ///   - vacuum: what to do about the space a prune leaves behind.
    ///   - now: the clock. Injectable so a test can age rows rather than sleep.
    public init(
        archive: Archive,
        defaults: UserDefaults = .standard,
        schedule: Schedule = .shipped,
        protectedIDs: @escaping @Sendable () async -> Set<Int64> = { [] },
        vacuum: VacuumPolicy = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.archive = archive
        self.defaults = defaults
        self.schedule = schedule
        self.protectedIDs = protectedIDs
        self.vacuum = vacuum
        self.now = now
    }

    deinit {
        loop?.cancel()
    }

    // MARK: Public

    // MARK: - Schedule

    /// When passes run.
    public struct Schedule: Sendable, Equatable {
        // MARK: Lifecycle

        public init(launchDelay: TimeInterval, interval: TimeInterval) {
            self.launchDelay = launchDelay
            self.interval = interval
        }

        // MARK: Public

        /// Thirty seconds after launch, then every six hours.
        ///
        /// The delay is not politeness. Launch is when the popover has to paint and
        /// capture has to bootstrap, and both want the same database writer a prune would
        /// be holding — so the one job with no deadline waits for the two that do.
        public static let shipped = Schedule(launchDelay: 30, interval: 6 * 60 * 60)

        public let launchDelay: TimeInterval
        public let interval: TimeInterval
    }

    // MARK: - Trigger

    /// What asked for a pass, which is the only input to whether a full `VACUUM` may run.
    ///
    /// A repack briefly blocks writers, so it is allowed exactly where a pause is
    /// explainable: at launch, before the user is doing anything with the app, or because
    /// they pressed a button and are watching a spinner. From the six-hourly timer it
    /// would be an unexplained freeze in the middle of somebody's afternoon.
    public enum Trigger: Sendable, Equatable {
        case launch
        case timer
        case manual

        // MARK: Public

        public var allowsFullVacuum: Bool {
            self != .timer
        }
    }

    // MARK: - Report

    /// What one pass did. Counts only, which is what lets it be logged.
    public struct Report: Sendable, Equatable {
        public var softDeleted = 0
        public var hardDeleted = 0
        public var appsScanned = 0

        /// Whether the pass changed anything at all.
        public var isEmpty: Bool {
            softDeleted == 0 && hardDeleted == 0
        }

        /// Safe for a log line and for the diagnostics export.
        public var logDescription: String {
            "soft \(softDeleted) hard \(hardDeleted) apps \(appsScanned)"
        }
    }

    public static let batchSize = 500

    /// Starts the loop. Idempotent — a second call replaces the first rather than running
    /// two loops against the same archive.
    public func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            guard let schedule = await self?.schedule else {
                return
            }
            try? await Task.sleep(for: .seconds(schedule.launchDelay))
            // The first pass of a launch is the one allowed to repack: the user has just
            // started the app and is not yet doing anything with it. Every pass after it
            // is a timer tick in the middle of their day.
            var trigger = Trigger.launch
            while !Task.isCancelled {
                await self?.runOnce(trigger: trigger)
                trigger = .timer
                try? await Task.sleep(for: .seconds(schedule.interval))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Runs one pass. This is also "Run cleanup now".
    ///
    /// Never throws. A pass that fails — the archive closed underneath it because a panic
    /// wipe is running, the disk is full — is logged by count and retried on the next
    /// cycle. Propagating it would mean the settings button, the launch loop and the panic
    /// wipe each needed their own answer to "what does a failed prune mean", and the
    /// answer is the same in all three: try again later, delete nothing in the meantime.
    @discardableResult
    public func runOnce(trigger: Trigger = .manual) async -> Report {
        do {
            let report = try await prune(trigger: trigger)
            if !report.isEmpty {
                Log.archive.info("retention pass: \(report.logDescription)")
            }
            return report
        } catch {
            let detail = (error as? ArchiveError)?.logDescription ?? ArchiveError.detail(from: error)
            Log.archive.error("retention pass failed: \(detail)")
            return Report()
        }
    }

    // MARK: Internal

    /// One pass, as the thing that can throw. `runOnce(trigger:)` is the one that cannot.
    func prune(trigger: Trigger = .manual) async throws -> Report {
        let settings = RetentionSettings(defaults: defaults)
        let protected = await protectedIDs()
        var report = Report()

        report.hardDeleted = try await hardDeleteAlreadySoftDeleted(protecting: protected)

        let apps = try archive.allApps()
        let moment = now()
        for app in apps {
            report.appsScanned += 1
            guard
                let id = app.id,
                let cutoff = settings.cutoff(for: app, from: moment)
            else {
                continue
            }
            report.softDeleted += try await softDeleteExpired(appID: id, before: cutoff)
        }

        if !report.isEmpty {
            // `apps.notification_count` is what the privacy panes and the app filter show,
            // and a prune is the one thing that can make it wrong. Recomputing the whole
            // table is a single UPDATE over a few hundred rows — cheaper to do than to
            // reason about keeping incrementally correct across two delete phases.
            try archive.repairCounts()
        }

        // Housekeeping last, and never allowed to fail the pass: the rows are already
        // gone, and whether their pages came back to the filesystem is a separate question
        // from whether the prune worked.
        let maintenance = vacuum.apply(
            to: archive,
            hardDeleted: report.hardDeleted > 0,
            trigger: trigger,
            now: moment
        )
        if maintenance != VacuumPolicy.Outcome() {
            Log.archive.info("retention maintenance: \(maintenance.logDescription)")
        }
        return report
    }

    // MARK: Private

    private let archive: Archive
    private let defaults: UserDefaults
    private let schedule: Schedule
    private let protectedIDs: @Sendable () async -> Set<Int64>
    private let vacuum: VacuumPolicy
    private let now: @Sendable () -> Date

    private var loop: Task<Void, Never>?

    /// Phase 1. Rows already flagged, removed for real.
    ///
    /// The delete fires `notifications_ad`, which is what takes the row's postings out of
    /// the FTS index, and cascades into `redactions`, `digest_items` and `embeddings`
    /// through their foreign keys. That is why this is a `DELETE` on `notifications` and
    /// not a set of coordinated deletes: the schema already knows what a notification owns,
    /// and a hand-written cascade would be a second, drifting copy of that knowledge.
    ///
    /// `protecting` is the undo window. A row the user soft-deleted moments ago may still
    /// have a visible "Undo", and hard-deleting it would make that button lie. Nothing
    /// populates the set yet — manual delete is a later milestone — which is precisely why
    /// it is a parameter rather than an assumption: the seam is here, and tested, for the
    /// feature that will need it.
    private func hardDeleteAlreadySoftDeleted(protecting protected: Set<Int64>) async throws -> Int {
        var deleted = 0
        while true {
            let batch = try await archive.pool.write { db -> Int in
                let ids = try Int64.fetchAll(
                    db,
                    sql: "SELECT id FROM notifications WHERE is_deleted = 1 LIMIT ?",
                    arguments: [Self.batchSize + protected.count]
                )
                let removable = ids.filter { !protected.contains($0) }.prefix(Self.batchSize)
                guard !removable.isEmpty else {
                    return 0
                }
                let placeholders = databaseQuestionMarks(count: removable.count)
                try db.execute(
                    sql: "DELETE FROM notifications WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(Array(removable))
                )
                return db.changesCount
            }
            deleted += batch
            if batch < Self.batchSize {
                break
            }
            // The writer is shared with capture and the timeline. Letting go between
            // batches is what keeps a large prune from being something the user can feel.
            await Task.yield()
        }
        return deleted
    }

    /// Phase 2. Rows past their app's cutoff, flagged but still on disk.
    ///
    /// Pinned rows are exempt: pinning is the user saying "keep this", and a policy they
    /// set for an app in general does not override a decision they made about one
    /// notification in particular. Unpinning makes it eligible on the next pass.
    ///
    /// One indexed `UPDATE` per batch, touching no other table and firing no FTS trigger —
    /// `notifications_au` watches only the four indexed text columns — so this half is
    /// safe to run while the timeline is open.
    private func softDeleteExpired(appID: Int64, before cutoff: Date) async throws -> Int {
        var flagged = 0
        while true {
            let batch = try await archive.pool.write { db -> Int in
                try db.execute(
                    sql: """
                    UPDATE notifications SET is_deleted = 1
                     WHERE id IN (
                           SELECT id FROM notifications
                            WHERE app_id = ?
                              AND is_deleted = 0
                              AND is_pinned = 0
                              AND delivered_at < ?
                            LIMIT ?
                     )
                    """,
                    arguments: [appID, cutoff.timeIntervalSince1970, Self.batchSize]
                )
                return db.changesCount
            }
            flagged += batch
            if batch < Self.batchSize {
                break
            }
            await Task.yield()
        }
        return flagged
    }
}
