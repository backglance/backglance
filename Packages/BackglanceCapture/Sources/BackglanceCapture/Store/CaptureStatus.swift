import Foundation

// MARK: - CaptureStatus

/// What the capture loop is doing right now, as a value the UI can render.
///
/// The status item icon, the popover's banner and Settings ▸ Capture all read this and
/// nothing else, which is what keeps `BackglanceUI` free of any system-store code (see
/// docs/architecture/ARCHITECTURE.md#dependency-graph).
///
/// Note that ``degraded(_:)`` is a *state*, not an error. `CaptureEngine` never throws a
/// degraded condition out to a caller: it sets the status, keeps listening to the
/// watcher, and retries bootstrap on the next wake. That is what lets a user grant Full
/// Disk Access in System Settings and have capture resume within one poll interval
/// without relaunching, and why the archive, timeline, search and export keep working
/// on whatever was already captured.
///
/// See docs/architecture/ARCHITECTURE.md#degraded-mode.
public enum CaptureStatus: Sendable, Equatable {
    /// Bootstrapped, watching the store, archiving new records.
    case running

    /// Deliberately not archiving. `until` is the automatic resume time, or `nil` when
    /// the user paused indefinitely. Notifications delivered while paused are never
    /// archived — resuming fast-forwards the cursor rather than backfilling (see
    /// docs/features/CAPTURE.md#pause-semantics).
    case paused(until: Date?)

    /// Capture cannot run, for a reason the UI can explain in one sentence. The engine
    /// is still alive and still retrying.
    case degraded(DegradedReason)

    /// The engine has not been started, or has been stopped. The resting state before
    /// `start()` and after `stop()`.
    case stopped
}

// MARK: - DegradedReason

/// Why capture is not running.
///
/// Every case is a condition Backglance can state plainly and retry out of; none of them
/// is a bug report. An unrecognised store schema in particular is an expected outcome of
/// Apple shipping a macOS update, not a failure — Backglance stops capturing rather than
/// guessing at a schema it does not understand, and says so. See
/// docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md.
///
/// > 🔒 No case carries notification content. ``unknownSchema(_:)`` carries a
/// > ``StoreFingerprint``, which is a hash of Apple's *schema* plus version numbers —
/// > deliberately content-free — and ``readError(_:)`` carries an errno-style reason
/// > string from the file system or SQLite, never a decoded record.
public enum DegradedReason: Sendable, Equatable {
    /// The store exists but Backglance cannot read it. Resolved by granting Full Disk
    /// Access; picked up on the next wake with no relaunch.
    case noFullDiskAccess

    /// The store's containing directory is not where it has been on macOS 11–26.
    case storeNotFound

    /// The store's schema fingerprint matched no known adapter, and the OS-major
    /// fallback did not produce one that passed its probe.
    case unknownSchema(StoreFingerprint)

    /// Snapshotting or reading the store failed for some other reason. The string is a
    /// file-system or SQLite error description.
    case readError(String)

    // MARK: Public

    /// Safe for the file log and `os_log` with `privacy: .public`.
    ///
    /// ``unknownSchema(_:)`` renders through ``StoreFingerprint/shortDescription`` rather
    /// than interpolating the fingerprint whole: the short form is the purpose-built
    /// content-free one, and it keeps the line to a hash prefix and two version numbers
    /// instead of a nested struct dump.
    public var logDescription: String {
        switch self {
        case .noFullDiskAccess:
            "no full disk access"

        case .storeNotFound:
            "store not found"

        case let .unknownSchema(fingerprint):
            "unknown schema \(fingerprint.shortDescription)"

        case let .readError(detail):
            "read error: \(detail)"
        }
    }

    /// One plain sentence for Settings ▸ Capture and the popover banner. No paths, no
    /// hashes, no errnos — those belong in ``logDescription``.
    public var userMessage: String {
        switch self {
        case .noFullDiskAccess:
            "Backglance needs Full Disk Access to read new notifications."

        case .storeNotFound:
            "Backglance couldn't find the system's notification database."

        case .unknownSchema:
            "This version of macOS stores notifications in a format Backglance doesn't recognize yet."

        case .readError:
            "Backglance couldn't read the system's notification database."
        }
    }
}
