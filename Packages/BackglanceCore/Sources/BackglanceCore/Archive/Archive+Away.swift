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
