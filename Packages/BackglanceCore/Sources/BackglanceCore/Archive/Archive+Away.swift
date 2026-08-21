import Foundation
import GRDB

// MARK: - Archive + away sessions

public extension Archive {
    /// Records a finished away session and returns it with its `id` filled in.
    ///
    /// The tracker hands over sessions that are already complete — the merge gap has
    /// elapsed and no cause can reopen them — so this is a single insert rather than an
    /// open-then-close pair. Nothing depends on a row existing mid-session: the digest
    /// build is what stamps `notifications.away_session_id`, and it runs afterwards
    /// (docs/features/MISSED_DIGEST.md#archive-tables-involved).
    ///
    /// Sessions too short to earn a digest are still written. They cost one row and
    /// they are what makes `is:missed` answer honestly.
    @discardableResult
    func insertAwaySession(_ session: AwaySession) throws -> AwaySession {
        var stored = session
        do {
            try pool.write { db in
                try stored.insert(db)
            }
        } catch {
            throw ArchiveError.writeFailed(
                table: AwaySession.databaseTableName,
                underlying: ArchiveError.detail(from: error)
            )
        }
        return stored
    }

    /// Closes an away session that was left open — the app was killed mid-session, or
    /// the Mac lost power while asleep.
    ///
    /// An open row is not harmless forever: `lastAwaySessionEnd()` skips it, so an
    /// abandoned session would sit in the table looking like the user never came back.
    /// Returns the number of rows closed.
    @discardableResult
    func closeOpenAwaySessions(endedAt: Date) throws -> Int {
        do {
            return try pool.write { db in
                try AwaySession
                    .filter(Column("ended_at") == nil)
                    .updateAll(db, Column("ended_at").set(to: UnixDate(endedAt)))
            }
        } catch {
            throw ArchiveError.writeFailed(
                table: AwaySession.databaseTableName,
                underlying: ArchiveError.detail(from: error)
            )
        }
    }

    /// Stamps the notifications delivered during a session with its id.
    ///
    /// This is what makes `is:missed` answer for a session, and what the timeline uses to
    /// open "everything from while you were away". It runs when the session is
    /// **recorded**, not when a digest is built: sessions under the digest threshold
    /// produce no digest at all, and the reason the archive keeps them anyway is that
    /// they are still worth searching (docs/features/MISSED_DIGEST.md#session-merging-and-thresholds).
    /// Linking only at build time would leave exactly those sessions unlinked and quietly
    /// make that promise false.
    ///
    /// Two conditions keep it from claiming what is not its own:
    ///
    /// - `away_session_id IS NULL` — a notification belongs to the first session that
    ///   claimed it. Sessions the tracker produces cannot overlap, but a re-run over a
    ///   window that was already linked must not move rows between sessions.
    /// - `is_deleted = 0` — a row the user deleted is not part of what they missed.
    ///
    /// The window is exact. The ± 2 min skew allowance belongs to the digest's
    /// `presented = 0` clause, which is a *second* selection signal rather than a claim
    /// of membership in the session.
    ///
    /// - Returns: how many notifications were linked.
    @discardableResult
    func linkNotifications(toAwaySession sessionID: Int64, from start: Date, through end: Date) throws -> Int {
        do {
            return try pool.write { db in
                try ArchivedNotification
                    .filter(Column("away_session_id") == nil)
                    .filter(Column("is_deleted") == false)
                    .filter(Column("delivered_at") >= UnixDate(start))
                    .filter(Column("delivered_at") <= UnixDate(end))
                    .updateAll(db, Column("away_session_id").set(to: sessionID))
            }
        } catch {
            throw ArchiveError.writeFailed(
                table: ArchivedNotification.databaseTableName,
                underlying: ArchiveError.detail(from: error)
            )
        }
    }

    /// Links the notifications delivered during a session that has been persisted.
    ///
    /// A no-op for a session with no `id` (never inserted) or no `endedAt` (still open) —
    /// neither is a window that can be claimed.
    @discardableResult
    func linkNotifications(to session: AwaySession) throws -> Int {
        guard let sessionID = session.id, let endedAt = session.endedAt else {
            return 0
        }
        return try linkNotifications(
            toAwaySession: sessionID,
            from: session.startedAt.date,
            through: endedAt.date
        )
    }

    /// Away sessions that finished inside a window, newest first.
    ///
    /// The digest build's entry point, and the Settings ▸ Status "recent sessions" list.
    func awaySessions(since: Date, limit: Int = 50) throws -> [AwaySession] {
        do {
            return try pool.read { db in
                try AwaySession
                    .filter(Column("ended_at") != nil)
                    .filter(Column("ended_at") >= UnixDate(since))
                    .order(Column("ended_at").desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            throw ArchiveError.writeFailed(
                table: AwaySession.databaseTableName,
                underlying: ArchiveError.detail(from: error)
            )
        }
    }
}
