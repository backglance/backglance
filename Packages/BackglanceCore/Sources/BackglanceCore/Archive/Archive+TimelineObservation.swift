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
    func timelineSnapshots(
        unreadSince anchor: UnixDate,
        pageSize: Int = Archive.timelinePageSize
    ) -> AsyncThrowingStream<TimelineSnapshot, Error> {
        let observation = ValueObservation.tracking { db -> TimelineSnapshot in
            let rows = try ArchivedNotification.page(after: nil, limit: pageSize).fetchAll(db)
            let apps = try AppRecord.fetchAll(db)
            let unread = try Self.unreadBadgeCount(db, since: anchor)
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
    /// The subquery is what applies the cap — `LIMIT` on the rows being counted,
    /// not on the count — so SQLite stops scanning at 100 matches instead of
    /// walking the whole index to produce a number the UI immediately clamps.
    static func unreadBadgeCount(_ db: Database, since anchor: UnixDate) throws -> Int {
        let sql = """
            SELECT COUNT(*) FROM (
              SELECT 1 FROM notifications n
              JOIN apps a ON a.id = n.app_id
              WHERE n.is_deleted = 0 AND n.is_read = 0 AND a.is_muted = 0
                AND n.delivered_at > ?
              LIMIT \(unreadBadgeCap)
            )
            """
        return try Int.fetchOne(db, sql: sql, arguments: [anchor.date.timeIntervalSince1970]) ?? 0
    }
}
