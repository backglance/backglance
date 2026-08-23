import Foundation
import GRDB

// MARK: - TimelineCursor

/// Where one timeline page ended, so the next can start exactly there.
///
/// The pair, not just the date: two notifications delivered in the same second
/// are common (a burst from one app shares a `delivered_at`), so `id` is the
/// tiebreaker that makes `(deliveredAt, id)` a total order. Ordering and the
/// page predicate both use the pair, which is what lets pages join without
/// skipping or repeating a row while capture keeps inserting at the head.
///
/// See docs/features/TIMELINE.md#keyset-pagination.
public struct TimelineCursor: Equatable, Hashable, Sendable {
    // MARK: Lifecycle

    public init(deliveredAt: UnixDate, id: Int64) {
        self.deliveredAt = deliveredAt
        self.id = id
    }

    /// The cursor that points *at* an already-fetched row.
    ///
    /// Fails for a row that was never inserted: without `id` there is no
    /// tiebreaker, and a date-only cursor would silently drop every other row
    /// sharing that second. A caller holding an unsaved row has a bug, not a
    /// pagination problem, so this is `nil` rather than a lenient fallback.
    public init?(row: ArchivedNotification) {
        guard let id = row.id else {
            return nil
        }
        self.init(deliveredAt: row.deliveredAt, id: id)
    }

    // MARK: Public

    public let deliveredAt: UnixDate
    public let id: Int64
}

// MARK: - Archive + timeline reads

public extension Archive {
    /// Rows per timeline page.
    ///
    /// Big enough that the popover and the window both open on one page of
    /// scrollback, small enough that a page fetch stays well inside a frame at
    /// 100k notifications — measured in
    /// docs/deployment/PERFORMANCE_GUIDE.md#timeline-pagination.
    static let timelinePageSize = 200

    /// One page of the timeline, newest first, starting after `cursor`.
    ///
    /// Pass `nil` for the first page. An empty result means the caller has
    /// reached the oldest archived notification — there is no separate "is
    /// there more" query, because a short page already answers it.
    ///
    /// Soft-deleted rows are filtered out here rather than by the caller, so a
    /// row the user deleted can never reappear because one call site forgot the
    /// predicate.
    func timelinePage(after cursor: TimelineCursor? = nil,
                      limit: Int = Archive.timelinePageSize) throws -> [ArchivedNotification]
    {
        do {
            return try pool.read { db in
                try ArchivedNotification
                    .page(after: cursor.map { (deliveredAt: $0.deliveredAt, id: $0.id) }, limit: limit)
                    .fetchAll(db)
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// The apps referenced by the timeline, keyed by `apps.id`.
    ///
    /// The timeline joins app metadata onto every row (display name, mute
    /// state), and the app table is tiny compared with the notification table —
    /// a few hundred rows at most — so it is cheaper to fetch it whole once per
    /// refresh than to join per page and re-decode the same app hundreds of
    /// times.
    func appsByID() throws -> [Int64: AppRecord] {
        do {
            return try pool.read { db in
                let apps = try AppRecord.fetchAll(db)
                return Dictionary(uniqueKeysWithValues: apps.compactMap { app in
                    app.id.map { ($0, app) }
                })
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }
}

// MARK: - Archive + timeline writes

public extension Archive {
    /// Marks one notification read. A no-op if it already was.
    ///
    /// Called from the visibility timer, so it runs far more often than it
    /// changes anything: the `is_read = 0` predicate keeps the repeats from
    /// touching a page, which matters because every write here wakes the
    /// timeline's observation.
    ///
    /// - Returns: whether the row changed.
    @discardableResult
    func markRead(_ id: Int64) throws -> Bool {
        do {
            return try pool.write { db in
                try db.execute(
                    sql: "UPDATE notifications SET is_read = 1 WHERE id = ? AND is_read = 0",
                    arguments: [id]
                )
                return db.changesCount > 0
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// Marks every visible notification read, in one statement.
    ///
    /// Deleted rows are left alone: "mark all read" is about the timeline in
    /// front of the user, and a soft-deleted row is not in it.
    ///
    /// - Returns: how many rows changed.
    @discardableResult
    func markAllRead() throws -> Int {
        do {
            return try pool.write { db in
                try db.execute(sql: "UPDATE notifications SET is_read = 1 WHERE is_read = 0 AND is_deleted = 0")
                return db.changesCount
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// When the most recent finished away session ended.
    ///
    /// Half of the unread anchor: the timeline treats the later of "you last
    /// opened the popover" and "you last came back" as the moment you looked.
    /// An away session that is still open has no end yet and is skipped — the
    /// user has not come back.
    func lastAwaySessionEnd() throws -> UnixDate? {
        do {
            return try pool.read { db in
                try AwaySession
                    .filter(Column("ended_at") != nil)
                    .order(Column("ended_at").desc)
                    .fetchOne(db)?
                    .endedAt
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }
}

// MARK: - Archive + hydration

public extension Archive {
    /// The notifications behind a set of ids, keyed by id.
    ///
    /// Search returns identifiers and scores; this is what turns them back into
    /// rows, and only for the ones about to be drawn. Ids that no longer exist
    /// — deleted while the results were on screen — are simply absent from the
    /// result rather than an error: a stale hit is an ordinary consequence of a
    /// live archive.
    func notifications(ids: [Int64]) throws -> [Int64: ArchivedNotification] {
        guard !ids.isEmpty else {
            return [:]
        }
        do {
            return try pool.read { db in
                let rows = try ArchivedNotification.filter(ids.contains(Column("id"))).fetchAll(db)
                return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                    row.id.map { ($0, row) }
                })
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// The archived row for `uuid`, or `nil` when it was never captured, or was
    /// soft-deleted since.
    ///
    /// The same lookup ``insertOrUpdate(_:redaction:)`` already runs internally to
    /// detect a thread update (`Archive+Upsert.swift`), exposed here for
    /// `backglance://open?id=` (docs/api/API_DOCUMENTATION.md#url-scheme-backglance),
    /// the one other caller that needs to resolve a uuid without paging through
    /// the timeline to find it. A soft-deleted row counts as "not here": it is not
    /// in the timeline either, and revealing one would show a row `TimelineStore`
    /// has already filtered out everywhere else.
    func notification(uuid: String) throws -> ArchivedNotification? {
        do {
            return try pool.read { db in
                try ArchivedNotification
                    .filter(Column("uuid") == uuid)
                    .filter(Column("is_deleted") == false)
                    .fetchOne(db)
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }
}
