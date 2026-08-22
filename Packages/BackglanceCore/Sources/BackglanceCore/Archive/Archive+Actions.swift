import Foundation
import GRDB

// MARK: - Archive + delete / undo

/// Soft delete and its undo — see docs/features/ACTIONS.md#delete-and-undo.
///
/// Both are ordinary `notifications.is_deleted` flag flips, the same shape as
/// `markRead(ids:)` in `Archive+Digest.swift`: a single `UPDATE` with a placeholder
/// list built the same manual way (never string-interpolated values — see
/// docs/security/SECURITY.md#parameterized-sql-only), reporting a changed-count or the
/// exact ids touched rather than a bare success flag, and wrapping any failure in
/// ``ArchiveError`` like every other write here.
///
/// This is not the whole delete lifecycle by itself. ``RetentionJob`` already
/// hard-prunes every `is_deleted = 1` row on its own schedule
/// (`RetentionJob.hardDeleteAlreadySoftDeleted`, run at launch and every 15 minutes)
/// regardless of how it got flagged — by these two methods, by a future bulk action, or
/// by a row this code has not been written yet. Nothing here needs to know that the
/// prune exists; the two sides only ever meet through the one column both read and
/// write, which is what makes undo "cheap": restoring is nothing more than flipping the
/// same flag back before the next prune pass gets to it.
public extension Archive {
    /// Flips `is_deleted` to `1` for whichever of `ids` are currently live, and returns
    /// only those — never the caller's full input.
    ///
    /// The read that decides which ids are live and the write that flips them happen
    /// inside one `pool.write` transaction, not two separate calls, so the result is
    /// exact even when something else touches the same rows between a caller deciding
    /// to delete and this method running: a row already soft-deleted by another window,
    /// or one no longer here at all, is silently excluded rather than reported as if it
    /// had just been deleted. That precision is what lets undo be *this array*, not the
    /// ids the caller happened to ask for — restoring a row that was already gone before
    /// this call would resurrect something the user never touched.
    ///
    /// - Parameter ids: candidate notification ids. An empty array short-circuits
    ///   before opening a transaction — nothing to flip, and nothing that would build a
    ///   malformed `IN ()`.
    /// - Returns: the ids that were `is_deleted = 0` immediately beforehand and are `1`
    ///   immediately after. Hand this array, and only this array, to ``restore(_:)``.
    /// - Throws: ``ArchiveError/writeFailed(table:underlying:)`` if the transaction
    ///   itself failed.
    @discardableResult
    func softDelete(_ ids: [Int64]) throws -> [Int64] {
        guard !ids.isEmpty else {
            return []
        }
        do {
            return try pool.write { db in
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                let live = try Int64.fetchAll(
                    db,
                    sql: "SELECT id FROM notifications WHERE is_deleted = 0 AND id IN (\(placeholders))",
                    arguments: StatementArguments(ids)
                )
                guard !live.isEmpty else {
                    return []
                }
                let livePlaceholders = live.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "UPDATE notifications SET is_deleted = 1 WHERE id IN (\(livePlaceholders))",
                    arguments: StatementArguments(live)
                )
                return live
            }
        } catch {
            throw ArchiveError.writeFailed(
                table: ArchivedNotification.databaseTableName,
                underlying: ArchiveError.detail(from: error)
            )
        }
    }

    /// Flips `is_deleted` back to `0` for whichever of `ids` are currently soft-deleted.
    ///
    /// Zero rows changed is the ordinary outcome of a late undo, not a failure worth
    /// throwing over: the 5-second toast is a UI convenience, not a lock on the rows it
    /// names, and ``RetentionJob`` hard-prunes `is_deleted = 1` rows on its own
    /// 15-minute-or-launch schedule with no notion of "an undo might still be coming".
    /// An app that slept across a prune window and only then resumed to run the undo
    /// finds nothing left to restore — the toast is long gone anyway by that point — and
    /// this reports that plainly as `0` rather than manufacturing an error for a race
    /// the user did nothing to cause (docs/features/ACTIONS.md's edge case table,
    /// "Undo after the retention job already hard-pruned").
    ///
    /// - Parameter ids: candidate notification ids — normally exactly what a prior
    ///   ``softDelete(_:)`` call returned. An empty array short-circuits before opening
    ///   a transaction.
    /// - Returns: how many rows actually changed.
    /// - Throws: ``ArchiveError/writeFailed(table:underlying:)`` if the write itself
    ///   failed.
    @discardableResult
    func restore(_ ids: [Int64]) throws -> Int {
        guard !ids.isEmpty else {
            return 0
        }
        do {
            return try pool.write { db in
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: """
                    UPDATE notifications SET is_deleted = 0
                    WHERE is_deleted = 1 AND id IN (\(placeholders))
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
