import Foundation
import GRDB

// MARK: - TimelineSnapshot

/// Everything the timeline needs to render its newest page, as one consistent
/// read.
///
/// The three parts arrive together on purpose. Fetching rows, apps and the badge
/// count separately would let the popover show a row whose app name came from
/// before a rename, or a badge that disagrees with the rows under it — one
/// `ValueObservation` block means one transaction and one truth.
public struct TimelineSnapshot: Equatable, Sendable {
    // MARK: Lifecycle

    public init(rows: [ArchivedNotification], apps: [Int64: AppRecord], unreadCount: Int) {
        self.rows = rows
        self.apps = apps
        self.unreadCount = unreadCount
    }

    // MARK: Public

    /// The newest page, `delivered_at DESC, id DESC`, soft-deleted rows excluded.
    public var rows: [ArchivedNotification]

    /// Every app row, keyed by `apps.id`, for display names and mute state.
    public var apps: [Int64: AppRecord]

    /// Unread, unmuted notifications delivered after the caller's anchor, counted
    /// no further than ``Archive/unreadBadgeCap`` — the badge renders anything at
    /// the cap as "99+", so counting the other 40,000 would be work nobody sees.
    public var unreadCount: Int
}

// MARK: - Archive + live timeline

public extension Archive {
    /// Where the unread badge stops counting. The UI renders this value as "99+".
    static let unreadBadgeCap = 100

    /// How many candidate rows `unreadBadgeCount(_:since:triage:)` will decode when it
    /// has to evaluate `mute` rules in Swift rather than count in SQL.
    ///
    /// Three times the cap, not the cap itself: the rows this scan throws away are the
    /// muted ones, so a scan bounded at exactly ``unreadBadgeCap`` would under-report the
    /// moment a single rule matched. Three times leaves room for two thirds of a capped
    /// backlog to be muted before the number visibly moves, while still bounding the work
    /// this does on every write to a few hundred row decodes.
    static let unreadBadgeScanCap = unreadBadgeCap * 3

    /// A stream of ``TimelineSnapshot`` values: one now, one after every change to
    /// `notifications` or `apps`.
    ///
    /// This is the timeline's live wire. It exists here, in `BackglanceCore`,
    /// rather than in the view layer so that `BackglanceUI` never imports GRDB —
    /// the dependency direction in
    /// docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction — while
    /// still getting GRDB's real observation semantics: values are delivered on
    /// the main queue, coalesced, and the first one arrives without waiting for a
    /// write.
    ///
    /// `anchor` is fixed for the lifetime of the stream because it is the badge's
    /// definition of "new". When the user looks at the timeline the anchor moves,
    /// and the caller starts a new stream rather than mutating this one — an
    /// observation whose meaning changed underneath it would emit counts that
    /// cannot be compared with the ones before.
    ///
    /// The stream finishes on the first error, carrying it to the caller, who
    /// shows a banner and offers a retry. It never crashes and never silently
    /// stops: a timeline that quietly stopped updating is worse than one that says
    /// so.
    /// - Parameter triage: how the badge decides whether a row is muted. Defaults to
    ///   ``NoTriage`` — the badge then counts exactly what it always did — because most
    ///   callers of this stream are tests asserting paging, not muting. The app passes
    ///   its one `RulesEngine`, which is what makes a `mute` rule reach the badge and not
    ///   only the day's Muted group (BACKGLANCE-240).
    func timelineSnapshots(
        unreadSince anchor: UnixDate,
        pageSize: Int = Archive.timelinePageSize,
        triage: any TriageEvaluating = NoTriage()
    ) -> AsyncThrowingStream<TimelineSnapshot, Error> {
        let observation = ValueObservation.tracking { db -> TimelineSnapshot in
            let rows = try ArchivedNotification.page(after: nil, limit: pageSize).fetchAll(db)
            let apps = try AppRecord.fetchAll(db)
            let unread = try Self.unreadBadgeCount(db, since: anchor, triage: triage)
            return TimelineSnapshot(
                rows: rows,
                apps: Dictionary(uniqueKeysWithValues: apps.compactMap { app in app.id.map { ($0, app) } }),
                unreadCount: unread
            )
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await snapshot in observation.values(in: pool) {
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ArchiveError.observationFailed(ArchiveError.detail(from: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - The badge query

extension Archive {
    /// Unread, unmuted, delivered after `anchor`, counted to the cap.
    ///
    /// Muted apps are excluded here rather than after the fact: a muted app is one
    /// the user asked not to be nagged about, so counting it and then hiding it
    /// would still light the badge up for it.
    ///
    /// "Muted" has two sources and SQL can only see one of them. `apps.is_muted` is a
    /// column, written by `RulesEngine.setAppMuted(bundleID:muted:)`. A `mute` *rule* is
    /// not: it produces `Triage.muted` in Swift, at read time. Until BACKGLANCE-240 this
    /// method knew only about the column, so a `mute` rule collapsed its rows into the
    /// day's Muted group and then went on counting them in the badge — half of the
    /// behaviour docs/features/RULES.md promises, and the confusing half.
    ///
    /// So there are two paths, and which one runs is decided by
    /// ``TriageEvaluating/hasMuteRules``:
    ///
    /// - **No `mute` rules** — the default install, since Backglance ships with no rules
    ///   at all. The original index-only `COUNT` runs, exact and unchanged. The subquery
    ///   is what applies the cap — `LIMIT` on the rows being counted, not on the count —
    ///   so SQLite stops scanning at 100 matches instead of walking the whole index to
    ///   produce a number the UI immediately clamps.
    /// - **At least one `mute` rule** — candidates are fetched and evaluated in Swift,
    ///   stopping as soon as ``unreadBadgeCap`` survivors are found.
    ///
    /// The scan is bounded twice over: at most ``unreadBadgeScanCap`` rows are ever
    /// decoded, and counting stops early at the cap. A user whose rules mute more than
    /// `unreadBadgeScanCap - unreadBadgeCap` of their unread backlog can see the badge
    /// under-report, which is accepted deliberately: at those volumes the badge already
    /// reads "99+", and an unbounded scan on every write is a worse answer than an
    /// approximate one on a number that is itself displayed approximately.
    static func unreadBadgeCount(
        _ db: Database,
        since anchor: UnixDate,
        triage: any TriageEvaluating = NoTriage()
    ) throws -> Int {
        let since = anchor.date.timeIntervalSince1970
        guard triage.hasMuteRules else {
            let sql = """
            SELECT COUNT(*) FROM (
              SELECT 1 FROM notifications n
              JOIN apps a ON a.id = n.app_id
              WHERE n.is_deleted = 0 AND n.is_read = 0 AND a.is_muted = 0
                AND n.delivered_at > ?
              LIMIT \(unreadBadgeCap)
            )
            """
            return try Int.fetchOne(db, sql: sql, arguments: [since]) ?? 0
        }

        // Same predicate as above, but the rows rather than their count, newest first so
        // an early stop keeps the most recent ones — the badge answers "what have I not
        // looked at", and the newest unread is the part of that a user acts on.
        let sql = """
        SELECT n.* FROM notifications n
        JOIN apps a ON a.id = n.app_id
        WHERE n.is_deleted = 0 AND n.is_read = 0 AND a.is_muted = 0
          AND n.delivered_at > ?
        ORDER BY n.delivered_at DESC
        LIMIT \(unreadBadgeScanCap)
        """
        var count = 0
        let cursor = try ArchivedNotification.fetchCursor(db, sql: sql, arguments: [since])
        while let row = try cursor.next() {
            if !triage.evaluate(row).muted {
                count += 1
                if count >= unreadBadgeCap {
                    break
                }
            }
        }
        return count
    }
}
