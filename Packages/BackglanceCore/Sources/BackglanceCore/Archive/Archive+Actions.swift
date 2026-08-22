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

// MARK: - Archive + pin / read toggles

/// Pin/unpin and read/unread — see docs/features/ACTIONS.md#pin-unpin-read-unread.
///
/// Both are single-column flag flips on `notifications`, the same shape as
/// `softDelete(_:)`/`restore(_:)` above and `markRead(ids:)` in
/// `Archive+Digest.swift` (which now delegates to ``setRead(_:_:)`` rather than
/// keeping its own copy of the statement). Pinning changes where a row sorts
/// (`TimelineStore.buildSections` puts pinned rows — manual before VIP, then
/// `delivered_at DESC` — at the top of their day); marking read changes only the
/// unread badge. Neither toggle touches `is_deleted`: a soft-deleted row is not in
/// front of the user, so pinning or reading it would be acting on something the
/// timeline is not even showing, the same reasoning `markRead(ids:)` already
/// applied to its own guard.
public extension Archive {
    /// Pins or unpins `ids`.
    ///
    /// - Parameters:
    ///   - ids: candidate notification ids. An empty array short-circuits before
    ///     opening a transaction.
    ///   - pinned: the new value. Rows already at that value are left alone, so a
    ///     redundant pin (or unpin) of an already-pinned row touches nothing.
    /// - Returns: how many rows actually changed.
    /// - Throws: ``ArchiveError/writeFailed(table:underlying:)`` if the write itself
    ///   failed.
    @discardableResult
    func setPinned(_ ids: [Int64], _ pinned: Bool) throws -> Int {
        guard !ids.isEmpty else {
            return 0
        }
        return try setFlag("is_pinned", ids: ids, to: pinned)
    }

    /// Marks `ids` read or unread.
    ///
    /// Unread is not a lesser-used mirror of read: docs/features/ACTIONS.md is
    /// explicit that marking a row unread again is allowed, and puts it back into
    /// the badge count if it was delivered since the last popover open. Nothing
    /// about the statement below distinguishes the two directions — the `pinned`/
    /// `read` argument is the only difference between "mark read" and "mark
    /// unread", which is exactly why both go through one ``setFlag(_:ids:to:)``
    /// helper instead of two near-identical hand-written statements.
    ///
    /// - Parameters:
    ///   - ids: candidate notification ids. An empty array short-circuits before
    ///     opening a transaction.
    ///   - read: the new value. Rows already at that value are left alone.
    /// - Returns: how many rows actually changed.
    /// - Throws: ``ArchiveError/writeFailed(table:underlying:)`` if the write itself
    ///   failed.
    @discardableResult
    func setRead(_ ids: [Int64], _ read: Bool) throws -> Int {
        guard !ids.isEmpty else {
            return 0
        }
        return try setFlag("is_read", ids: ids, to: read)
    }
}

private extension Archive {
    /// The one statement both toggles above share.
    ///
    /// - Parameter column: a literal from this file only — `"is_pinned"` or
    ///   `"is_read"` — never caller input, so the interpolation cannot carry
    ///   anything but one of those two names (the same rule
    ///   `Archive+Digest.swift`'s `stamp(column:onDigest:at:)` documents; see
    ///   docs/security/SECURITY.md#parameterized-sql-only). Every value that could
    ///   vary at the call site — the ids, the old value, the new value — is a `?`
    ///   placeholder, never interpolated.
    ///
    /// The `<column> = ? (old value)` predicate is what keeps an already-correct
    /// row out of the write: flipping ten rows and asking to pin the same ten
    /// again should change nothing on disk, both because it is not what happened
    /// (nothing about those rows is different) and because every write here wakes
    /// the timeline's live observation — touching rows that would not actually
    /// change is a redraw for nothing. `is_deleted = 0` keeps a soft-deleted row
    /// out of the write entirely, matching `markRead(ids:)`'s own guard: a row the
    /// user cannot currently see is not a row a pin or a read/unread click could
    /// have been aimed at.
    func setFlag(_ column: String, ids: [Int64], to value: Bool) throws -> Int {
        do {
            return try pool.write { db in
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: """
                    UPDATE notifications SET \(column) = ?
                    WHERE \(column) = ? AND is_deleted = 0 AND id IN (\(placeholders))
                    """,
                    arguments: StatementArguments([value, !value]) + StatementArguments(ids)
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
