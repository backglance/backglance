import Foundation

// MARK: - VacuumPolicy

/// What to do about the space a prune leaves behind, and when it is worth doing.
///
/// Deleting rows from SQLite does not shrink the file; it marks pages free for reuse. That
/// is usually the right trade — but an archive that has been pruned for a year and never
/// repacked is a file whose size stopped meaning anything, and a user who set retention to
/// seven days and watched the file stay at 400 MB has been told something untrue by their
/// disk.
///
/// > 🔒 The privacy argument is the stronger one. `secure_delete` overwrites a freed page
/// > with zeros, so notification text does not survive in the free list — but only for
/// > pages SQLite actually frees. Repacking is what returns them to the filesystem, and
/// > until it happens the archive stays as large as the most it ever held, which is itself
/// > a fact about the user nobody asked to publish.
///
/// Three operations, in ascending cost:
///
/// | Operation | When | Cost |
/// |---|---|---|
/// | FTS `optimize` | After a pass that hard-deleted anything | One write; merges index segments |
/// | `incremental_vacuum(N)` | Same, bounded to `N` pages | Milliseconds, no file rewrite |
/// | `VACUUM` | Monthly, or when a fifth of the file is free — and never from the timer | Seconds; rewrites the file;
/// needs a second copy's worth of disk |
///
/// The `VACUUM` restriction is the load-bearing one. It briefly blocks writers, so it runs
/// only where a pause is explainable — at launch, before the user is doing anything, or
/// because they pressed a button and are watching — never from the six-hourly timer, where
/// it would be an unexplained freeze in the middle of someone's afternoon.
///
/// See docs/operations/MAINTENANCE.md#vacuum-policy.
public struct VacuumPolicy: Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        incrementalPagesPerRun: Int = 256,
        fullVacuumInterval: TimeInterval = 30 * 24 * 60 * 60,
        freePageRatioThreshold: Double = 0.20
    ) {
        self.incrementalPagesPerRun = incrementalPagesPerRun
        self.fullVacuumInterval = fullVacuumInterval
        self.freePageRatioThreshold = freePageRatioThreshold
    }

    // MARK: Public

    // MARK: - Outcome

    /// What maintenance actually did. Counts and flags only, so it can be logged.
    public struct Outcome: Sendable, Equatable {
        public var optimizedIndex = false
        public var incrementalVacuum = false
        public var fullVacuum = false

        /// Set when a full `VACUUM` was wanted but the volume could not hold a second
        /// copy of the archive. Not an error the caller has to handle — the archive is
        /// intact, just larger than it needs to be — but worth a line in the log, because
        /// it is the one maintenance failure a user can do something about.
        public var declinedForDiskSpace = false

        public var logDescription: String {
            "optimize \(optimizedIndex) incremental \(incrementalVacuum) full \(fullVacuum)"
                + (declinedForDiskSpace ? " declined-disk" : "")
        }
    }

    /// `schema_meta` key holding the Unix seconds of the last successful full `VACUUM`.
    public static let lastVacuumKey = "last_vacuum_at"

    public static let `default` = VacuumPolicy()

    /// How many free pages one incremental run returns. Bounded on purpose: the point is
    /// to keep the free list from growing without ever being something the user waits for.
    public let incrementalPagesPerRun: Int

    public let fullVacuumInterval: TimeInterval

    /// The share of the file that has to be free before a repack is worth its cost.
    public let freePageRatioThreshold: Double

    /// Whether a full `VACUUM` is due, given what the file looks like and when one last
    /// ran.
    ///
    /// Pure, so the decision can be tested without a database and read without running
    /// one. `lastVacuumAt == nil` — an archive that has never been vacuumed — counts as
    /// due, which is what gives an archive created before this policy existed its first
    /// repack rather than making it wait a month for one.
    public func isFullVacuumDue(space: Archive.SpaceReport, lastVacuumAt: Date?, now: Date) -> Bool {
        guard let lastVacuumAt else {
            return true
        }
        if now.timeIntervalSince(lastVacuumAt) >= fullVacuumInterval {
            return true
        }
        return space.freeRatio > freePageRatioThreshold
    }

    /// Runs the maintenance this trigger allows.
    ///
    /// Never throws. Every operation here is housekeeping: the archive is correct and
    /// complete whether or not any of it runs, and a caller that had to handle a failed
    /// repack would only be able to do what this already does — log it and try again next
    /// time.
    ///
    /// - Parameters:
    ///   - hardDeleted: whether the pass that preceded this removed any rows. The index
    ///     merge and the page trim are answers to a delete; running them after a pass that
    ///     deleted nothing is work with nothing to do.
    ///   - trigger: what asked. Only ``RetentionJob/Trigger/launch`` and
    ///     ``RetentionJob/Trigger/manual`` may repack.
    @discardableResult
    public func apply(
        to archive: Archive,
        hardDeleted: Bool,
        trigger: RetentionJob.Trigger,
        now: Date = Date()
    ) -> Outcome {
        var outcome = Outcome()

        if hardDeleted {
            outcome.optimizedIndex = Self.attempt("fts optimize") { try archive.optimizeSearchIndex() }
            // Skipped rather than attempted on an archive that cannot do it: the pragma
            // would succeed and reclaim nothing, and reporting that as work done is how a
            // maintenance routine ends up trusted for something it never did.
            if (try? archive.supportsIncrementalVacuum()) == true {
                outcome.incrementalVacuum = Self.attempt("incremental vacuum") {
                    try archive.incrementalVacuum(pages: incrementalPagesPerRun)
                }
            }
        }

        guard trigger.allowsFullVacuum else {
            return outcome
        }
        guard
            let space = try? archive.spaceReport(),
            isFullVacuumDue(space: space, lastVacuumAt: lastVacuum(in: archive), now: now)
        else {
            return outcome
        }

        do {
            try archive.vacuum()
            try? archive.setMetaValue(String(now.timeIntervalSince1970), forKey: Self.lastVacuumKey)
            outcome.fullVacuum = true
            Log.archive.notice("vacuum ok pages \(space.pageCount) free \(space.freelistCount)")
        } catch let error as ArchiveError {
            if case .insufficientDiskSpace = error {
                outcome.declinedForDiskSpace = true
            }
            Log.archive.error("vacuum failed: \(error.logDescription)")
        } catch {
            Log.archive.error("vacuum failed: \(ArchiveError.detail(from: error))")
        }
        return outcome
    }

    // MARK: Private

    private static func attempt(_ label: String, _ body: () throws -> Void) -> Bool {
        do {
            try body()
            return true
        } catch {
            let detail = (error as? ArchiveError)?.logDescription ?? ArchiveError.detail(from: error)
            Log.archive.error("\(label) failed: \(detail)")
            return false
        }
    }

    private func lastVacuum(in archive: Archive) -> Date? {
        guard
            let raw = try? archive.metaValue(forKey: Self.lastVacuumKey),
            let seconds = TimeInterval(raw)
        else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }
}
