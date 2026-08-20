import Foundation

// MARK: - CaptureError

/// The one typed error for `BackglanceCapture`, per
/// docs/architecture/ARCHITECTURE.md#error-handling-patterns.
///
/// Capture failures almost never reach the user as errors. They are thrown inside the
/// engine, converted to a ``DegradedReason`` through ``degradedReason``, and surfaced as
/// a ``CaptureStatus`` the UI can render — so this type's job is to carry enough context
/// for that conversion and for a log line, and nothing more.
///
/// > 🔒 No case carries notification content: no title, subtitle, body, sender, thread
/// > id, deep link, attachment name, or byte of the store's `record.data`. That is what
/// > makes ``logDescription`` safe for `os_log` with `privacy: .public` and for the
/// > diagnostics export. Adding a case that carries a payload is a security bug, not a
/// > style question (see docs/security/SECURITY.md).
///
/// Deliberately *not* `LocalizedError`: per
/// docs/getting-started/DEVELOPMENT_GUIDE.md#errors, only errors shown directly to the
/// user conform, and a capture failure reaches the user as a ``DegradedReason`` state
/// with its own `userMessage` instead.
public enum CaptureError: Error, Sendable {
    /// The store could not be read because Backglance has no Full Disk Access. Mapped
    /// from `NSFileReadNoPermissionError` by the snapshot copy, which is where the
    /// precise errno actually shows up.
    case fullDiskAccessDenied

    /// The store's containing directory was not at the expected path. The URL is the
    /// path that was searched — only its last component is ever logged, since the full
    /// path contains the user's home directory name.
    case storeNotFound(URL)

    /// Copying `db` + `-wal` into the per-tick snapshot directory failed. The string is
    /// the underlying file-system error's description.
    case snapshotFailed(underlying: String)

    /// A condition that is already expressed as a state, thrown so that it unwinds the
    /// current tick. ``degradedReason`` passes it straight through.
    case degraded(DegradedReason)

    /// A single record's payload could not be decoded. Identified by `rec_id` only.
    ///
    /// `reason` is one of a small fixed set of strings — "not a property list", "root is
    /// not a dictionary", "empty payload" — never a fragment of the payload itself. One
    /// bad record must never abort the batch: the engine logs this and moves on.
    case parseFailed(recID: Int64, reason: String)

    /// Reading from the read-only snapshot failed. The string is the SQLite error
    /// description.
    case readFailed(String)

    // MARK: Public

    /// Whether this failure is worth retrying before telling the user anything.
    ///
    /// Copying a live SQLite database races the process writing it: `usernoted`
    /// checkpointing mid-copy yields a torn snapshot that opens as `SQLITE_CORRUPT` or
    /// `SQLITE_NOTADB`, and the copy itself can fail on a busy file. Both are ordinary
    /// and both fix themselves on the next tick — the poll guarantees one within 15
    /// seconds — so degrading on the first one would put "Backglance couldn't read the
    /// system's notification database" in front of a user whose Mac is working fine.
    ///
    /// Permission and schema failures are the opposite: they are standing conditions
    /// that will not resolve by waiting, and the user can act on them. Those degrade at
    /// once. See docs/features/CAPTURE.md#edge-cases-and-error-handling.
    public var isTransient: Bool {
        switch self {
        case .snapshotFailed,
             .readFailed:
            true

        case .fullDiskAccessDenied,
             .storeNotFound,
             .degraded,
             .parseFailed:
            false
        }
    }

    /// The state the engine moves into. Content-free by construction.
    public var degradedReason: DegradedReason {
        switch self {
        case .fullDiskAccessDenied:
            .noFullDiskAccess

        case .storeNotFound:
            .storeNotFound

        case let .snapshotFailed(detail),
             let .readFailed(detail):
            .readError(detail)

        case let .degraded(reason):
            reason

        case let .parseFailed(recID, reason):
            .readError("rec \(recID): \(reason)")
        }
    }

    /// Safe for the file log and `os_log` with `privacy: .public` — identifiers, counts
    /// and fixed reason strings only.
    ///
    /// ``storeNotFound(_:)`` logs `lastPathComponent` rather than the URL: the full path
    /// runs through `~`, which is the user's account name.
    public var logDescription: String {
        switch self {
        case .fullDiskAccessDenied:
            "full disk access denied"

        case let .storeNotFound(url):
            "store not found at \(url.lastPathComponent)"

        case let .snapshotFailed(detail):
            "snapshot failed: \(detail)"

        case let .degraded(reason):
            "degraded: \(reason.logDescription)"

        case let .parseFailed(recID, reason):
            "parse failed rec \(recID): \(reason)"

        case let .readFailed(detail):
            "read failed: \(detail)"
        }
    }
}
