import Foundation
import GRDB

// MARK: - ArchiveHealth

/// The result of `Archive.checkIntegrity(level:)`.
///
/// docs/architecture/ARCHITECTURE.md#error-handling-patterns names this the surfaced
/// type — the timeline shows a non-modal banner built from it. Early drafts of
/// docs/architecture/DATABASE_SCHEMA.md#integrity-checks called the same shape
/// `IntegrityReport` with a separate `IntegrityLevel`; `ArchiveHealth` with a nested
/// `Level` is the name that won, and both documents now say so. Do not "fix" this
/// file back to `IntegrityReport`.
///
/// A failed check is a *value*, not a thrown error: `ok == false` with an explanatory
/// message is an expected outcome of running the check, in the same sense that
/// `ArchiveError.duplicate` is an expected outcome of inserting a record that is
/// already archived (see docs/architecture/ARCHITECTURE.md#error-handling-patterns).
/// Only a failure to run the check at all — the read itself throwing, which means the
/// pool could not be read from — becomes an ``ArchiveError/integrityCheckFailed(_:)``.
public struct ArchiveHealth: Sendable {
    // MARK: Lifecycle

    public init(ok: Bool, messages: [String]) {
        self.ok = ok
        self.messages = messages
    }

    // MARK: Public

    /// How thorough a check to run. See ``Archive/checkIntegrity(level:)`` for the
    /// cost of each at 100k notifications.
    public enum Level: Sendable {
        /// `PRAGMA quick_check`. Safe to run on every launch.
        case quick

        /// `PRAGMA integrity_check`. Reserved for on-demand use (Settings ▸ Advanced
        /// ▸ "Check archive") or after crash recovery — it walks every page.
        case full
    }

    /// `true` when every check below turned up nothing. `false` means at least one of
    /// `messages` describes a real problem, not that the check itself failed to run.
    public let ok: Bool

    /// Diagnostic text from SQLite: `quick_check`/`integrity_check` result rows that
    /// were not `"ok"`, a `foreign_key_check` violation count, and/or an FTS
    /// integrity-check failure description.
    ///
    /// > Important: These strings originate from SQLite's own integrity machinery, not
    /// > from notification content, but they are not vetted against the privacy
    /// > invariant that content never reaches a log. Do not pass `messages` to
    /// > `Logger`/`os_log` — with `privacy: .public` or otherwise — anywhere in this
    /// > module. A caller that persists a health report writes it to the local
    /// > `backglance.log` file only, per
    /// > docs/architecture/DATABASE_SCHEMA.md#integrity-checks; it must never reach
    /// > structured system logging.
    public let messages: [String]
}

public extension Archive {
    /// Runs SQLite's own integrity machinery against the archive and reports the
    /// result as a value, never by throwing for a failed check.
    ///
    /// Four checks:
    ///
    /// 1. `PRAGMA quick_check` (``ArchiveHealth/Level/quick``) or `PRAGMA
    ///    integrity_check` (``ArchiveHealth/Level/full``) — every result row other
    ///    than `"ok"` becomes a message.
    /// 2. `PRAGMA foreign_key_check` — any violation rows become one summary message,
    ///    since the row-level detail is not actionable outside `sqlite3`.
    /// 3. An FTS5 external-content self-check
    ///    (`INSERT INTO notifications_fts(notifications_fts, rank) VALUES
    ///    ('integrity-check', 1)`), which compares the index against `notifications`
    ///    and throws if they disagree. The throw is caught locally and turned into a
    ///    message — it is a finding, not a reason to abort the other checks.
    /// 4. ``ArchiveHealth/ok`` is `messages.isEmpty`.
    ///
    /// > Note: the FTS check runs in its own `pool.write`, and cannot be folded back
    /// > into the read alongside the other three. SQLite treats the FTS5
    /// > `'integrity-check'` special command as an INSERT against the virtual table
    /// > (its `xUpdate` hook fires even though nothing is persisted), and GRDB's read
    /// > access — a `DatabasePool` reader opened `SQLITE_OPEN_READONLY`, or a
    /// > `DatabaseQueue` read wrapped in `PRAGMA query_only` — refuses any statement
    /// > that looks like a write with "attempt to write a readonly database". Verified
    /// > directly before writing this: checks 1 and 2 stay inside `pool.read`, since
    /// > both are genuinely read-only; check 3 runs in its own `pool.write` so the
    /// > virtual table command is allowed to execute. This costs a moment of the
    /// > single writer lock on a diagnostic call, which is already the case's
    /// > documented ~100–300 ms — an acceptable trade against the two blocks not
    /// > sharing one atomic snapshot, since a health check does not need snapshot
    /// > isolation across its own checks.
    ///
    /// Rough cost at 100k notifications, from
    /// docs/architecture/DATABASE_SCHEMA.md#integrity-checks — use this to decide
    /// which level is safe to run where:
    ///
    /// | Check | Cost |
    /// |---|---|
    /// | `PRAGMA quick_check` | ~50–150 ms |
    /// | `PRAGMA integrity_check` | ~1–3 s |
    /// | `PRAGMA foreign_key_check` | ~20 ms |
    /// | FTS `integrity-check` | ~100–300 ms |
    ///
    /// `.quick` is cheap enough to run on every launch; `.full` walks every page and
    /// is reserved for an explicit "Check archive" action or post-crash recovery.
    /// Both levels always run the foreign-key and FTS checks — only the first check
    /// changes with `level`.
    ///
    /// - Throws: ``ArchiveError/integrityCheckFailed(_:)`` if the read itself could
    ///   not be performed (for example the pool is unavailable). This is distinct
    ///   from a failed check, which is reported as ``ArchiveHealth/ok`` `== false`
    ///   rather than thrown — see ``ArchiveHealth``.
    func checkIntegrity(level: ArchiveHealth.Level) throws -> ArchiveHealth {
        do {
            var messages = try pool.read { db -> [String] in
                let sql = level == .quick ? "PRAGMA quick_check" : "PRAGMA integrity_check"
                let rows = try String.fetchAll(db, sql: sql)
                var messages = rows.filter { $0 != "ok" }

                let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
                if !violations.isEmpty {
                    messages.append("foreign_key_check: \(violations.count) violation(s)")
                }
                return messages
            }

            // Needs a write-capable connection — see the note above.
            do {
                try pool.write { db in
                    try db.execute(
                        sql: "INSERT INTO notifications_fts(notifications_fts, rank) VALUES ('integrity-check', 1)"
                    )
                }
            } catch {
                messages.append("fts integrity-check failed: \(ArchiveError.detail(from: error))")
            }

            return ArchiveHealth(ok: messages.isEmpty, messages: messages)
        } catch {
            throw ArchiveError.integrityCheckFailed(ArchiveError.detail(from: error))
        }
    }
}
