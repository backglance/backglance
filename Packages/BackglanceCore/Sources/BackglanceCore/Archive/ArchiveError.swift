import Foundation

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

    /// A `PRAGMA integrity_check` (or equivalent) turned up a problem.
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
            "Backglance couldn't open its archive."

        case .migrationFailed:
            "Backglance couldn't upgrade its archive. Your data is untouched."

        case .duplicate:
            "Already archived."

        case .insertFailed:
            "A notification couldn't be saved."

        case .integrityCheckFailed:
            "The archive failed an integrity check."

        case .observationFailed:
            "The timeline stopped updating. Reopen the window to retry."

        case .wipeIncomplete:
            "Some files couldn't be removed. See the log for details."

        case .unavailable:
            "Backglance is busy, try again in a moment."
        }
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
