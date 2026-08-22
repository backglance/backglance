import Darwin
import Foundation

// MARK: - FullDiskAccessState

/// Whether this process can read Apple's notification store, and why not when it cannot.
///
/// Three states rather than a `Bool`, because the two failures need different sentences and
/// different buttons. "You have not granted Full Disk Access" is a thing the user can fix in
/// thirty seconds; "the store is not where it has been on every macOS since 11" is not, and
/// showing the first message for the second condition sends people to System Settings to
/// toggle a switch that was never the problem.
public enum FullDiskAccessState: Equatable, Sendable {
    /// The store opened read-only. Capture can run.
    case granted

    /// TCC is refusing. Resolved by granting Full Disk Access, and picked up on the next
    /// probe with no relaunch.
    case denied

    /// The store is not there, and we can see that it is not there. Notification Center has
    /// never run for this account, or Apple moved it. **Not** a permission problem, and the
    /// UI must not nag about one.
    case storeMissing
}

// MARK: - FullDiskAccessProbe

/// Asks the only question that gets an honest answer: can this process open the file?
///
/// `FileManager.isReadableFile(atPath:)` cannot be used here, and the reason is worth stating
/// because the API looks exactly right. It consults `access(2)`, which reports POSIX
/// permissions — and the store's POSIX permissions say yes to everyone. TCC is a separate
/// layer that only refuses at `open(2)`. So a probe built on `isReadableFile` returns `true`
/// on a Mac that has never granted Full Disk Access, and Backglance would report that capture
/// is fine while archiving nothing.
///
/// One `open`/`close` per call, synchronous and cheap enough to run on whatever thread is
/// asking. There is no cached answer: the grant can change while the app is running — that is
/// the whole point of the probe — and a cache would be the thing that made "grant it and come
/// back" not work.
///
/// See docs/features/PERMISSIONS_PRIVACY.md#runtime-detection-fulldiskaccessprobe.
public struct FullDiskAccessProbe: Sendable {
    // MARK: Lifecycle

    /// - Parameter storeLocation: resolves the store's path. Injected so a test can point the
    ///   probe at a file it controls rather than at the machine's real store.
    public init(storeLocation: @escaping @Sendable () throws -> URL = { StoreLocation.expected() }) {
        self.storeLocation = storeLocation
    }

    // MARK: Public

    /// The probe against an explicit path.
    ///
    /// `O_NONBLOCK` so a path that turns out to be a FIFO — which nothing should ever put
    /// there, but a hostile or broken environment could — cannot hang the caller waiting for
    /// a writer that never arrives.
    public static func probe(at url: URL) -> FullDiskAccessState {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK)
        if descriptor >= 0 {
            close(descriptor)
            return .granted
        }

        return switch errno {
        case EPERM,
             EACCES:
            .denied

        case ENOTDIR:
            // A component of the path is not a directory, so nothing can exist there. Nobody
            // is being denied anything — this is a wrong path, which is the same user-facing
            // condition as a store that is not there.
            .storeMissing

        case ENOENT:
            // "Not found" is ambiguous under TCC: a denied process is told the file is not
            // there rather than that it may not look. The container directory settles it —
            // without the grant, opening *that* fails too, and a process that can list the
            // directory and still finds no file is looking at a Mac where Notification
            // Center has genuinely never written one.
            containerState(of: url)

        default:
            // EINTR, EBUSY, a full descriptor table. Not an answer, and reporting `.granted`
            // on a maybe would start capture into a store it cannot read. `.denied` is the
            // conservative reading, and every caller retries.
            .denied
        }
    }

    /// Whether the store can be read right now.
    public func probe() -> FullDiskAccessState {
        guard let url = try? storeLocation() else {
            return .storeMissing
        }
        return Self.probe(at: url)
    }

    // MARK: Private

    private let storeLocation: @Sendable () throws -> URL

    private static func containerState(of url: URL) -> FullDiskAccessState {
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
        if directory >= 0 {
            close(directory)
            return .storeMissing
        }
        return errno == EPERM || errno == EACCES ? .denied : .storeMissing
    }
}
