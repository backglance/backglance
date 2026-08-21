import Foundation
import GRDB

// MARK: - Archive + digest reads

public extension Archive {
    /// The digest waiting to be presented, if there is one.
    ///
    /// "Waiting" means built and not dismissed — `shown_at` is deliberately not part of
    /// the predicate. A digest the user saw but never dismissed is still theirs: closing
    /// the popover mid-read must not count as an answer
    /// (docs/features/MISSED_DIGEST.md#never-nagging-rules, rule 3, which makes
    /// `dismissed_at` the only thing that retires a digest).
    ///
    /// Newest first, because a second away session while the first digest sat unread
    /// means the older one has been overtaken by events.
    func pendingDigest() throws -> Digest? {
        do {
            return try pool.read { db in
                try Digest
                    .filter(Column("dismissed_at") == nil)
                    .order(Column("created_at").desc)
                    .fetchOne(db)
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// The most recent digest whatever its state — what the "Last digest" menu item
    /// reopens, read-only, without disturbing `dismissed_at`.
    func lastDigest() throws -> Digest? {
        do {
            return try pool.read { db in
                try Digest.order(Column("created_at").desc).fetchOne(db)
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// The away session a digest summarises. `nil` if it was pruned out from under the
    /// digest, which `ON DELETE CASCADE` makes impossible in practice but which the
    /// header must still be able to render without it.
    func awaySession(id: Int64) throws -> AwaySession? {
        do {
            return try pool.read { db in
                try AwaySession.fetchOne(db, key: id)
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// The digest's shown notifications, in the rank `DigestEngine` assigned.
    ///
    /// Only the rows `digest_items` actually holds — at most
    /// ``DigestEngine/shownCap`` of them. The tail lives on `digests.item_count`, which
    /// is what "and *n* more" counts, so the view never fetches rows it will not draw.
    ///
    /// Soft-deleted rows are filtered out: a notification the user deleted after the
    /// digest was built is not part of what they missed any more.
    func digestNotifications(digestID: Int64) throws -> [ArchivedNotification] {
        do {
            return try pool.read { db in
                try ArchivedNotification.fetchAll(
                    db,
                    sql: """
                    SELECT n.* FROM notifications n
                    JOIN digest_items i ON i.notification_id = n.id
                    WHERE i.digest_id = ? AND n.is_deleted = 0
                    ORDER BY i.rank
                    """,
                    arguments: [digestID]
                )
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// The delivery timestamps of everything the session claimed, oldest first.
    ///
    /// A multi-day session's header summarises per day ("Fri 34 · Sat 12 · Sun 41"), and
    /// that count has to cover the whole session rather than the 50 rows the digest
    /// shows — a three-day trip would otherwise report the last afternoon as the trip.
    /// Timestamps only, because "which local day" is a `Calendar` question the caller's
    /// timezone answers, not one SQL should be guessing at.
    func deliveryDates(inAwaySession sessionID: Int64) throws -> [Date] {
        do {
            return try pool.read { db in
                try Double.fetchAll(
                    db,
                    sql: """
                    SELECT delivered_at FROM notifications
                    WHERE away_session_id = ? AND is_deleted = 0
                    ORDER BY delivered_at
                    """,
                    arguments: [sessionID]
                )
                .map(Date.init(timeIntervalSince1970:))
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }
}

// MARK: - Archive + digest writes

public extension Archive {
    /// Stamps `shown_at` the first time a digest reaches the screen.
    ///
    /// The `IS NULL` predicate is the point: the column records when the user *first*
    /// saw this digest, and reopening it later must not rewrite that. Returns whether
    /// this call was the first.
    @discardableResult
    func markDigestShown(_ id: Int64, at date: Date = Date()) throws -> Bool {
        try stamp(column: "shown_at", onDigest: id, at: date)
    }

    /// Retires a digest. Once `dismissed_at` is set it is never presented again — not on
    /// relaunch, not on the next popover open — though it stays queryable through the
    /// timeline's "Missed" filter and `is:missed`.
    @discardableResult
    func dismissDigest(_ id: Int64, at date: Date = Date()) throws -> Bool {
        try stamp(column: "dismissed_at", onDigest: id, at: date)
    }

    /// Marks a specific set of notifications read, in one statement.
    ///
    /// The digest's "Mark all read" — which means *these* notifications, not the whole
    /// timeline. Already-read and deleted rows are skipped so the write touches only
    /// what changes, because every write here wakes the timeline's observation.
    ///
    /// - Returns: how many rows changed.
    @discardableResult
    func markRead(ids: [Int64]) throws -> Int {
        guard !ids.isEmpty else {
            return 0
        }
        do {
            return try pool.write { db in
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: """
                    UPDATE notifications SET is_read = 1
                    WHERE is_read = 0 AND is_deleted = 0 AND id IN (\(placeholders))
                    """,
                    arguments: StatementArguments(ids)
                )
                return db.changesCount
            }
        } catch {
            throw ArchiveError.writeFailed(
                table: ArchivedNotification.databaseTableName,
                underlying: ArchiveError.detail(from: error)
            )
        }
    }
}

// MARK: - Archive + digest private

private extension Archive {
    /// Writes a once-only timestamp column, leaving an already-stamped row alone.
    ///
    /// - Parameter column: a literal from this file only — never caller input, so the
    ///   interpolation cannot carry anything but one of the two names above
    ///   (docs/security/SECURITY.md#parameterized-sql-only).
    func stamp(column: String, onDigest id: Int64, at date: Date) throws -> Bool {
        do {
            return try pool.write { db in
                try db.execute(
                    sql: "UPDATE digests SET \(column) = ? WHERE id = ? AND \(column) IS NULL",
                    arguments: [date.timeIntervalSince1970, id]
                )
                return db.changesCount > 0
            }
        } catch {
            throw ArchiveError.writeFailed(
                table: Digest.databaseTableName,
                underlying: ArchiveError.detail(from: error)
            )
        }
    }
}
