import Foundation

// MARK: - FocusAssertionWatcher

/// Watches macOS's Focus assertions and reports whether one is active.
///
/// ⚠️ **This rides a private file.** `~/Library/DoNotDisturb/DB/Assertions.json` is
/// Apple's own business: there is no public API for "is a Focus on" on macOS, the file's
/// location and shape have already changed once (Monterey introduced it), and nothing
/// promises it will survive the next release. Backglance can read it only because it
/// already holds Full Disk Access for capture.
///
/// The posture is the same as the store adapters': observed behaviour, never a guess. Any
/// structural surprise — a root that is not an object, a missing `data` array — reports
/// ``Status/unavailable(_:)`` and **stops the watcher for the session** rather than
/// interpreting a shape nobody has seen. Losing Focus detection costs granularity and
/// nothing else: sessions still form from lock and sleep, and the store's own
/// `presented = 0` flag still marks the notifications a Focus swallowed, so they are
/// still selected into the next digest.
///
/// See docs/features/MISSED_DIGEST.md#focusassertionwatcher.
public final class FocusAssertionWatcher: @unchecked Sendable {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - url: injectable so tests can point at a file they wrote themselves. Nothing in
    ///     the test suite reads the real one.
    ///   - onChange: called on the watcher's own queue, once with the initial state and
    ///     again on every change.
    public init(
        url: URL = FocusAssertionWatcher.defaultURL,
        onChange: @escaping @Sendable (Status) -> Void
    ) {
        self.url = url
        self.onChange = onChange
    }

    deinit {
        // Direct, not dispatched: the event handler holds only a weak reference, so there
        // is no cycle keeping this alive and no queued block that could resurrect it.
        // Without it, a watcher released without `stop()` leaks its `O_EVTONLY`
        // descriptor for the lifetime of the process.
        source?.cancel()
    }

    // MARK: Public

    /// What the watcher can currently say about Focus.
    public enum Status: Sendable, Equatable {
        /// At least one Focus assertion is active.
        case active

        /// The file was read and holds no active assertion.
        case inactive

        /// Nothing can be said. Feeding focus events stops; Settings ▸ Status shows the
        /// reason.
        case unavailable(Unavailable)
    }

    /// Why Focus detection is off.
    ///
    /// A fixed vocabulary rather than a free string: these render into the file log and
    /// into a Settings row, and an `Error`'s description would put the user's home
    /// directory in both.
    public enum Unavailable: Sendable, Equatable {
        /// The file could not be opened. `code` is `errno`. `ENOENT` is the ordinary
        /// case — a Mac on which no Focus was ever configured has no file — and is not a
        /// failure worth surfacing loudly.
        case notReadable(code: Int32)

        /// The file opened but could not be read, or held bytes that are not JSON.
        /// Usually a torn read of an atomic replace, so the next event may well succeed.
        case readFailed

        /// The file is larger than anything this format plausibly produces.
        case tooLarge(bytes: Int)

        /// The JSON root is not an object. The format moved.
        case unexpectedRoot

        /// No top-level `data` array of objects. The format moved.
        case missingDataArray

        // MARK: Public

        /// Whether this is a shape nobody has seen, as opposed to a file that is simply
        /// not there or was caught mid-write. Structural surprises stop the watcher.
        public var isStructural: Bool {
            switch self {
            case .unexpectedRoot,
                 .missingDataArray,
                 .tooLarge: true
            case .notReadable,
                 .readFailed: false
            }
        }

        /// Safe for the file log and `os_log` with `privacy: .public`. No paths.
        public var logDescription: String {
            switch self {
            case let .notReadable(code): "assertions not readable (errno \(code))"
            case .readFailed: "assertions unreadable or not JSON"
            case let .tooLarge(bytes): "assertions implausibly large (\(bytes) bytes)"
            case .unexpectedRoot: "assertions root is not an object"
            case .missingDataArray: "assertions have no 'data' array"
            }
        }

        /// One plain sentence for Settings ▸ Status. No paths, no errno.
        public var userMessage: String {
            switch self {
            case .notReadable:
                "Backglance can't read your Focus settings, so Focus won't start an away session."

            case .readFailed,
                 .tooLarge,
                 .unexpectedRoot,
                 .missingDataArray:
                "This version of macOS stores Focus differently than Backglance expects, "
                    + "so Focus won't start an away session."
            }
        }
    }

    /// ⚠️ Apple's, undocumented, and subject to change without notice.
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")

    /// Anything past this is not the format we know. The real file is a few kilobytes.
    public static let sizeLimit = 4 * 1_024 * 1_024

    /// Begins watching. Idempotent: re-arming replaces the source rather than adding one,
    /// so a file replaced twice never leaves two descriptors open.
    ///
    /// Reports the initial state before returning control to the queue, so a caller that
    /// starts the watcher while a Focus is already on learns about it immediately rather
    /// than at the next change.
    public func start() {
        queue.async { [self] in
            arm()
        }
    }

    /// Stops watching. The watcher can be started again; a structural failure is what
    /// makes stopping permanent for the session.
    public func stop() {
        queue.async { [self] in
            source?.cancel()
            source = nil
        }
    }

    // MARK: Internal

    /// Reads the file and decides what can be said about it.
    ///
    /// Tolerant by construction: it looks for a top-level `data` array whose entries
    /// carry a non-empty `storeAssertionRecords` array — the shape observed on macOS
    /// 13–26 — and treats everything else as "cannot say". No `NSKeyedUnarchiver`, no
    /// assumptions about key order, no crash on any input.
    ///
    /// Internal rather than private so the tests can drive it against files they wrote.
    func readStatus() -> Status {
        let size: Int
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            size = values.fileSize ?? 0
        } catch {
            return .unavailable(.notReadable(code: Self.errnoCode(from: error)))
        }
        guard size <= Self.sizeLimit else {
            return .unavailable(.tooLarge(bytes: size))
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unavailable(.notReadable(code: Self.errnoCode(from: error)))
        }

        // The two failures are worth telling apart: bytes that are not JSON at all are a
        // torn read of an atomic replace far more often than a format change, and that
        // must not latch the watcher off. A JSON value that is not an object is the
        // format actually moving, and that must.
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .unavailable(.readFailed)
        }
        guard let root = parsed as? [String: Any] else {
            return .unavailable(.unexpectedRoot)
        }

        guard let entries = root["data"] as? [[String: Any]] else {
            return .unavailable(.missingDataArray)
        }

        for entry in entries {
            if let records = entry["storeAssertionRecords"] as? [[String: Any]], !records.isEmpty {
                return .active
            }
        }
        return .inactive
    }

    // MARK: Private

    private let url: URL
    private let onChange: @Sendable (Status) -> Void
    private let queue = DispatchQueue(label: "app.backglance.Backglance.focuswatch")

    /// Only touched on ``queue``, except in `deinit` where nothing can race.
    private var source: DispatchSourceFileSystemObject?

    /// Maps a Cocoa file error back to the `errno` it came from, so the log line carries
    /// a number rather than a localized sentence containing the user's home directory.
    private static func errnoCode(from error: Error) -> Int32 {
        let nsError = error as NSError
        if
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSPOSIXErrorDomain
        {
            return Int32(underlying.code)
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return Int32(nsError.code)
        }
        // Cocoa's "no such file" and "not permitted" are the two that matter, and both
        // have a POSIX equivalent worth naming.
        switch nsError.code {
        case NSFileReadNoSuchFileError,
             NSFileNoSuchFileError: return ENOENT
        case NSFileReadNoPermissionError: return EACCES
        default: return 0
        }
    }

    /// Opens the file, arms a source on it, and reports the initial state. Must run on
    /// ``queue``.
    private func arm() {
        source?.cancel()
        source = nil

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // No file is the ordinary case on a Mac where no Focus was ever configured.
            // It is not an error, and it is not worth retrying on a timer: a Focus being
            // configured for the first time is rare, and the next launch picks it up.
            report(.unavailable(.notReadable(code: errno)))
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else {
                return
            }
            handleEvent()
        }
        // Captured by value at creation, so the cancel handler closes *this* descriptor
        // even after `self.source` has been replaced by a re-arm.
        source.setCancelHandler { close(descriptor) }

        self.source = source
        source.resume()
        report(readStatus())
    }

    /// Must run on ``queue`` — the source delivers its events there.
    private func handleEvent() {
        // Settings writes this file by replacing it, which leaves the source watching a
        // descriptor for an unlinked inode. Re-arming is the only way to keep seeing
        // changes, and `arm()` reports the fresh state itself.
        if let data = source?.data, data.contains(.delete) || data.contains(.rename) {
            arm()
            return
        }
        report(readStatus())
    }

    /// Emits a status, and turns the watcher off if the file's shape is one nobody has
    /// seen. Must run on ``queue``.
    private func report(_ status: Status) {
        if case let .unavailable(reason) = status {
            Log.digest.notice("Focus detection unavailable: \(reason.logDescription)")
            if reason.isStructural {
                // Deliberately one-way for the session. A format we do not recognise is
                // exactly the situation in which continuing to parse means guessing.
                source?.cancel()
                source = nil
            }
        }
        onChange(status)
    }
}
