import Foundation

/// Where Apple's Notification Center database lives.
///
/// ⚠️ `~/Library/Group Containers/group.com.apple.usernoted/db2/db` is an undocumented
/// path owned by `usernoted`. It is what has been observed on macOS 11–26, not an API,
/// and reading it requires Full Disk Access. This type only *resolves* the path —
/// everything that opens it goes through `StoreSnapshot`, which copies the file first
/// and never opens Apple's live database (see docs/features/CAPTURE.md#storelocation).
///
/// `BACKGLANCE_STORE_PATH` points capture at a fixture instead, so the capture layer can
/// be developed without granting a debug build Full Disk Access. It is honoured in
/// **DEBUG builds only** — a release build ignores it entirely, so no shipped Backglance
/// can be talked into reading a store someone else chose (see
/// docs/getting-started/SETUP_GUIDE.md, "Environment variables"). Unlike
/// `BACKGLANCE_ARCHIVE_PATH`, which `ArchivePaths` honours in both configurations, this
/// one is a debugging affordance rather than a supported deployment option.
public enum StoreLocation {
    // MARK: Public

    /// The system store to read, or ``CaptureError/storeNotFound(_:)`` if it is not
    /// where it should be.
    ///
    /// A thrown error here is not a crash-worthy condition: `CaptureEngine` turns it
    /// into `DegradedReason.storeNotFound` and retries on the next wake, which is what
    /// makes a fresh user account (where `usernoted` has not created its database yet)
    /// resolve itself as soon as the first notification arrives.
    public static func current() throws -> URL {
        try resolve(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    /// Where the store *would* be, whether or not anything is there yet.
    ///
    /// ``current()`` throws when the store's directory is missing, which is the right
    /// answer for a reader: there is nothing to read. A watcher needs the opposite. On a
    /// fresh account, `usernoted` has not created its database yet, and the whole point
    /// of arming a watcher there is to notice the moment it does — a watcher that refused
    /// to arm would leave capture waiting for a relaunch. ``StoreWatcher`` already treats
    /// a file it cannot open as expected rather than exceptional (it logs an errno and
    /// keeps its poll timer running), so it takes this path and does not need it to exist.
    ///
    /// Honours `BACKGLANCE_STORE_PATH` on the same DEBUG-only terms as ``current()``, and
    /// deliberately does *not* fall back to the real store when the override names a file
    /// that is not there: a debug build pointed at a fixture must never quietly end up
    /// watching the developer's own notifications instead.
    public static func expected() -> URL {
        expected(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    // MARK: Internal

    /// The store's path relative to the user's home directory.
    ///
    /// ⚠️ Undocumented. If a future macOS moves it, this constant and a fixture change
    /// together — see docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md.
    static let relativePath = "Library/Group Containers/group.com.apple.usernoted/db2/db"

    /// Whether `BACKGLANCE_STORE_PATH` is consulted at all. False in release builds.
    static let honoursStorePathOverride: Bool = {
        #if DEBUG
            true
        #else
            false
        #endif
    }()

    /// ``expected()``'s logic, as an internal seam for the same reasons as ``resolve``.
    static func expected(
        environment: [String: String],
        homeDirectory: URL,
        honoursOverride: Bool = honoursStorePathOverride
    ) -> URL {
        if
            honoursOverride,
            let override = environment["BACKGLANCE_STORE_PATH"],
            !override.isEmpty,
            (override as NSString).isAbsolutePath
        {
            return URL(fileURLWithPath: override)
        }
        return homeDirectory.appendingPathComponent(relativePath)
    }

    /// Resolution logic, as an internal seam so tests can exercise both the override and
    /// the default branch — and both build configurations — without mutating the real
    /// process environment or depending on what exists under the test runner's `~`.
    static func resolve(
        environment: [String: String],
        homeDirectory: URL,
        honoursOverride: Bool = honoursStorePathOverride,
        fileManager: FileManager = .default
    ) throws -> URL {
        if
            honoursOverride,
            let override = environment["BACKGLANCE_STORE_PATH"],
            !override.isEmpty,
            (override as NSString).isAbsolutePath
        {
            // A fixture is Backglance's own file, so unlike the real store its existence
            // can be checked directly: no Full Disk Access stands between us and it, and
            // a typo in the env var should say so rather than surface later as an
            // unreadable snapshot.
            let url = URL(fileURLWithPath: override)
            guard fileManager.fileExists(atPath: url.path) else {
                throw CaptureError.storeNotFound(url)
            }
            return url
        }

        let url = homeDirectory.appendingPathComponent(relativePath)

        // Only the *directory* is checked. `fileExists` on the database file itself is
        // unreliable without Full Disk Access — TCC can make it report false for a file
        // that is plainly there — so a check on `db` would report `storeNotFound` for
        // what is really a permissions problem, and send the user to the wrong fix. The
        // snapshot copy returns a precise errno, and that is what distinguishes
        // `noFullDiskAccess` from `storeNotFound`.
        var isDirectory: ObjCBool = false
        let directory = url.deletingLastPathComponent()
        guard
            fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw CaptureError.storeNotFound(url)
        }
        return url
    }
}
