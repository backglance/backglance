import Foundation

/// Where the archive lives on disk, and how to lock that location down.
///
/// The default location is `~/Library/Application Support/Backglance/archive.sqlite`,
/// alongside an `icons/` cache and a `tmp/` directory used for short-lived system-store
/// snapshots. Everything under the support directory is private to the user: the
/// directory is `0700`, the database files are `0600`. See
/// docs/architecture/DATABASE_SCHEMA.md#file-layout-and-permissions for the full layout
/// and the reasoning (FileVault + strict POSIX modes stand in for at-rest encryption
/// until v1.x's optional SQLCipher).
///
/// `BACKGLANCE_ARCHIVE_PATH` (see docs/getting-started/SETUP_GUIDE.md, "Environment
/// variables") relocates the whole support directory: pointing it at
/// `/some/place/archive.sqlite` moves `icons/` and `tmp/` to `/some/place/` too, because
/// both are derived from ``supportDirectory``, which is always the parent directory of
/// ``archiveURL``. Unlike `BACKGLANCE_STORE_PATH`, this override is honoured in both
/// Debug and Release builds.
public enum ArchivePaths {
    // MARK: Public

    /// The directory holding `archive.sqlite`, `icons/`, and `tmp/`.
    ///
    /// Always the parent of ``archiveURL``, so an override of the archive location
    /// carries the rest of the support directory with it.
    public static var supportDirectory: URL {
        archiveURL.deletingLastPathComponent()
    }

    /// The archive database file. Defaults to
    /// `~/Library/Application Support/Backglance/archive.sqlite`; overridable with
    /// `BACKGLANCE_ARCHIVE_PATH`.
    public static var archiveURL: URL {
        resolveArchiveURL(environment: ProcessInfo.processInfo.environment)
    }

    /// App icon cache, keyed by bundle id. `0700`, files inside are not otherwise
    /// restricted since they hold no notification content.
    public static var iconsDirectory: URL {
        supportDirectory.appendingPathComponent("icons", isDirectory: true)
    }

    /// Short-lived system-store snapshots taken for each capture pass. `0700`; emptied
    /// on launch and after each successful pass.
    public static var tmpDirectory: URL {
        supportDirectory.appendingPathComponent("tmp", isDirectory: true)
    }

    /// Creates the support, icons, and tmp directories (`0700`) and tightens the
    /// archive's database files (`0600`) if they already exist.
    ///
    /// `createDirectory(attributes:)` only sets permissions at creation time — it does
    /// not tighten a directory that already exists with a looser mode (e.g. left behind
    /// by a stray process umask) — so each directory's permissions are re-applied
    /// explicitly after creation.
    public static func prepare() throws {
        try prepare(archiveURL: archiveURL)
    }

    // MARK: Internal

    /// Resolves the archive location from the environment.
    ///
    /// `BACKGLANCE_ARCHIVE_PATH` is honoured only when it is a non-empty, absolute
    /// path; a relative or empty value is silently ignored rather than trapped, so a
    /// misconfigured environment degrades to the default location instead of crashing
    /// the app.
    ///
    /// Exposed as an internal seam (rather than reading `ProcessInfo` inline in
    /// ``archiveURL``) so tests can exercise the resolution logic without mutating the
    /// real process environment.
    static func resolveArchiveURL(environment: [String: String]) -> URL {
        if
            let override = environment["BACKGLANCE_ARCHIVE_PATH"],
            !override.isEmpty,
            (override as NSString).isAbsolutePath
        {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Backglance", isDirectory: true)
            .appendingPathComponent("archive.sqlite")
    }

    /// Testable seam for ``prepare()``: performs the same work against an arbitrary
    /// archive location instead of reading ``archiveURL`` (and therefore the real
    /// process environment).
    static func prepare(archiveURL: URL) throws {
        let fileManager = FileManager.default
        let supportDirectory = archiveURL.deletingLastPathComponent()
        let iconsDirectory = supportDirectory.appendingPathComponent("icons", isDirectory: true)
        let tmpDirectory = supportDirectory.appendingPathComponent("tmp", isDirectory: true)

        for directory in [supportDirectory, iconsDirectory, tmpDirectory] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        for suffix in ["", "-wal", "-shm"] {
            let path = archiveURL.path + suffix
            if fileManager.fileExists(atPath: path) {
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
    }
}
