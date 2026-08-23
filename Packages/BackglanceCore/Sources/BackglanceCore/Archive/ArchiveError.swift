import Foundation
import GRDB

// MARK: - ArchiveError

/// The one typed error for `BackglanceCore`, per
/// docs/architecture/ARCHITECTURE.md#error-handling-patterns.
///
/// Two views on every case: ``logDescription`` is safe for `os_log` with `privacy:
/// .public` and for the local file log — it may contain file paths, migration names,
/// UUIDs, counts, and underlying error strings, but never notification content.
/// ``userMessage`` (also exposed as `errorDescription` via `LocalizedError`, since
/// docs/api/API_DOCUMENTATION.md's App Intents rethrow this type as `LocalizedError`)
/// is one plain sentence for the UI: no paths, no SQL.
///
/// Surfaced as an `ArchiveHealth` banner in the timeline; a migration failure blocks
/// launch with a plain dialog instead.
public enum ArchiveError: Error, Sendable {
    /// The archive database could not be opened at `path`.
    case openFailed(path: String, underlying: String)

    /// The named migration failed to apply. Never edit a shipped migration to "fix"
    /// this — add a new one instead (see docs/architecture/DATABASE_SCHEMA.md).
    case migrationFailed(name: String, underlying: String)

    /// A record with this `store_rec_id` or `uuid` is already archived.
    ///
    /// This is an expected outcome of import/live overlap, not a failure: the cursor
    /// should advance silently past it. Per
    /// docs/architecture/ARCHITECTURE.md#error-handling-patterns, `.duplicate` must
    /// not be logged at error level.
    case duplicate

    /// Insert of the notification identified by `uuid` failed.
    case insertFailed(uuid: UUID, underlying: String)

    /// A write to `table` failed.
    ///
    /// The general case, for rows that have no `uuid` to name them — an away session,
    /// a digest, a retention prune. `table` is a schema identifier, never user data.
    case writeFailed(table: String, underlying: String)

    /// A `PRAGMA integrity_check` (or equivalent) turned up a problem.
    /// A `VACUUM` was declined because the volume does not hold a second copy of the
    /// archive. Rewriting the file needs room for both until it finishes.
    case insufficientDiskSpace(needed: Int64, available: Int64)

    case integrityCheckFailed(String)

    /// A `ValueObservation`/`DatabaseRegionObservation` stopped delivering updates.
    case observationFailed(String)

    /// Panic wipe finished but some paths listed in `remaining` could not be removed.
    case wipeIncomplete(remaining: [String])

    /// The archive's connection pool is held by a wipe or a migration and cannot
    /// currently serve reads or writes. Callers should retry shortly rather than
    /// treat this as a hard failure. See docs/api/API_DOCUMENTATION.md, "Intent
    /// error behavior".
    case unavailable

    // MARK: Public

    /// Safe for the file log and `os_log` with `privacy: .public`. Never notification
    /// title, subtitle, body, sender, thread id, deep link, or attachment names.
    public var logDescription: String {
        switch self {
        case let .openFailed(path, underlying):
            "open failed (\(path)): \(underlying)"

        case let .migrationFailed(name, underlying):
            "migration \(name) failed: \(underlying)"

        case .duplicate:
            "duplicate"

        case let .insertFailed(uuid, underlying):
            "insert \(uuid.uuidString) failed: \(underlying)"

        case let .writeFailed(table, underlying):
            "write to \(table) failed: \(underlying)"

        case let .insufficientDiskSpace(needed, available):
            "insufficientDiskSpace(needed: \(needed), available: \(available))"

        case let .integrityCheckFailed(detail):
            "integrity: \(detail)"

        case let .observationFailed(detail):
            "observation: \(detail)"

        case let .wipeIncomplete(remaining):
            "wipe incomplete: \(remaining.joined(separator: ", "))"

        case .unavailable:
            "unavailable"
        }
    }

    /// One plain sentence for the UI. No paths, no SQL.
    public var userMessage: String {
        switch self {
        case .openFailed:
            String(localized: "Backglance couldn't open its archive.")

        case .migrationFailed:
            String(localized: "Backglance couldn't upgrade its archive. Your data is untouched.")

        case .duplicate:
            String(localized: "Already archived.")

        case .insertFailed:
            String(localized: "A notification couldn't be saved.")

        case .writeFailed:
            String(localized: "Backglance couldn't save a change to its archive.")

        case .insufficientDiskSpace:
            String(localized: "There isn't enough free disk space to compact the archive. Nothing was changed.")

        case .integrityCheckFailed:
            String(localized: "The archive failed an integrity check.")

        case .observationFailed:
            String(localized: "The timeline stopped updating. Reopen the window to retry.")

        case .wipeIncomplete:
            String(localized: "Some files couldn't be removed. See the log for details.")

        case .unavailable:
            String(localized: "Backglance is busy, try again in a moment.")
        }
    }
}

// MARK: - Content-free underlying details

public extension ArchiveError {
    /// Renders an arbitrary thrown error into the `underlying:` string these cases
    /// carry, without letting notification content in.
    ///
    /// > 🔒 This exists because `String(describing:)` on a GRDB `DatabaseError` includes
    /// > the statement's *bound arguments* whenever `Configuration.publicStatementArguments`
    /// > is on — which ``Archive/makeConfiguration(inMemory:)`` enables in DEBUG builds so
    /// > that SQL is readable while developing. A failing insert binds the notification's
    /// > title, body and sender, so the convenient rendering is exactly the one that would
    /// > put a user's notification text into ``logDescription`` — the property documented
    /// > as safe for `os_log` with `privacy: .public`. A guarantee that holds only in
    /// > Release is not a guarantee.
    ///
    /// So the pieces are picked out by hand instead: SQLite's result code and its own
    /// message ("UNIQUE constraint failed: notifications.uuid", "database or disk is
    /// full") name columns and conditions, never values. `sql` and `arguments` are
    /// dropped — the statement is ours and adds nothing a result code does not.
    static func detail(from error: Error) -> String {
        guard let database = error as? DatabaseError else {
            // Not a database failure — the type name is all that can be said safely about
            // an error this module has never seen.
            return String(describing: type(of: error))
        }
        guard let message = database.message else {
            return "sqlite \(database.extendedResultCode.rawValue)"
        }
        return "sqlite \(database.extendedResultCode.rawValue): \(message)"
    }
}

// MARK: LocalizedError

extension ArchiveError: LocalizedError {
    /// App Intents rethrow ``ArchiveError`` as `LocalizedError`; Shortcuts reads this
    /// property for the message it shows the user, so it mirrors ``userMessage``
    /// exactly rather than duplicating the sentence.
    public var errorDescription: String? {
        userMessage
    }
}
