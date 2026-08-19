import Foundation

// MARK: - CaptureMetrics

/// What capture has done, as numbers.
///
/// 🔒 Counts only. Never a title, a body, a sender, the bundle id of an excluded app, or a
/// value from a payload. That is what makes this safe to log at every tick, to show in
/// Settings ▸ Capture, and to include in a diagnostics export that a user is about to
/// email to a stranger.
///
/// It exists because "capture stopped working" is otherwise unanswerable. A tick that
/// reads forty records and archives three is doing exactly what it should if thirty-seven
/// of them were excluded — and is a bug if they failed. The difference is these fields.
///
/// See docs/features/CAPTURE.md#metrics-and-logging.
public struct CaptureMetrics: Sendable, Equatable {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    /// One tick's tally, or the sum of all of them.
    public struct Tally: Sendable, Equatable {
        // MARK: Lifecycle

        public init() {}

        // MARK: Public

        /// Records read from the store, whatever became of them.
        public var read = 0

        /// New rows in the archive.
        public var archived = 0

        /// Existing rows refreshed — the store rewriting a notification in place.
        public var updated = 0

        /// Records the archive already had. Expected while an import overlaps live capture.
        public var duplicates = 0

        /// Records whose app is excluded. Their payloads were never decoded.
        public var excluded = 0

        /// Records that could not be parsed or written. The number worth investigating.
        public var failed = 0

        /// Safe for a log line and for the diagnostics export.
        public var summary: String {
            "read \(read) archived \(archived) updated \(updated) "
                + "dup \(duplicates) excluded \(excluded) failed \(failed)"
        }

        /// Counts one record's outcome.
        public mutating func record(_ outcome: ArchiveOutcome) {
            read += 1
            switch outcome {
            case .archived:
                archived += 1

            case .updated:
                updated += 1

            case .duplicate:
                duplicates += 1

            case .excluded:
                excluded += 1

            case .failed:
                failed += 1
            }
        }

        /// Adds another tally into this one.
        public mutating func add(_ other: Tally) {
            read += other.read
            archived += other.archived
            updated += other.updated
            duplicates += other.duplicates
            excluded += other.excluded
            failed += other.failed
        }
    }

    /// How many ticks have run since launch. A tick count that stops climbing while the
    /// Mac is awake is the symptom of a watcher that stopped waking.
    public var ticks = 0

    /// Everything the ticks did, added up.
    public var totals = Tally()

    /// Reads that failed and were retried rather than degraded. A handful is ordinary —
    /// the store is busy, a snapshot caught a checkpoint — and a rising count is not.
    public var transientFailures = 0

    /// Times the store's `rec_id` went backwards, meaning it was replaced under us.
    public var storeResets = 0

    /// When the last tick finished. What Settings shows as "last checked".
    public var lastTickAt: Date?

    /// Why capture is not running, if it is not. Content-free by construction — see
    /// ``DegradedReason``.
    public var degradedReason: DegradedReason?

    /// Safe for a log line and for the diagnostics export.
    public var summary: String {
        let degraded = degradedReason.map { " degraded=\($0.logDescription)" } ?? ""
        return "ticks \(ticks) \(totals.summary) transient \(transientFailures) resets \(storeResets)\(degraded)"
    }

    /// Folds one tick's tally into the totals.
    public mutating func add(_ tally: Tally, at date: Date = Date()) {
        ticks += 1
        totals.add(tally)
        lastTickAt = date
    }
}
