import Foundation
import GRDB

/// The one door to `archive.sqlite`.
///
/// Backglance's own database — never Apple's system store, which is read through
/// `BackglanceCapture` from a copied snapshot and is never opened by this type. The
/// distinction is worth keeping in the vocabulary: this is the *archive*, that is the
/// *store*.
///
/// Everything the app knows lives behind this class: the timeline, search, digests,
/// rules and per-app settings all read from it, and capture is the only writer. It
/// wraps one GRDB writer in WAL mode — many concurrent readers, a single writer — so
/// the UI can page through the timeline while capture inserts, without either
/// blocking the other.
///
/// ```swift
/// let archive = try Archive(inMemory: true)   // tests
/// let archive = Archive.shared                // the app
/// ```
///
/// > Important: Do not open `archive.sqlite` with a second connection in the same
/// > process. Two WAL connections technically work, but the migrator, the FTS sync
/// > triggers and panic wipe all assume exactly one pool.
///
/// See docs/architecture/DATABASE_SCHEMA.md#part-a-the-archive-backglances-sqlite.
public final class Archive: Sendable {
    // MARK: Lifecycle

    /// Designated initializer. Takes an already-migrated writer.
    ///
    /// Internal because callers should go through ``open()`` or ``init(inMemory:)``,
    /// which guarantee the migration chain has run. Tests that need a hand-built
    /// writer can still reach it from inside the module.
    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// An in-memory archive with the full migration chain applied. For tests.
    ///
    /// `inMemory` reads as a label rather than a flag — passing `false` is a
    /// programmer error, not a request for an on-disk archive, because the on-disk
    /// path needs ``ArchivePaths/prepare()`` and belongs to ``open()``.
    public convenience init(inMemory: Bool) throws {
        precondition(inMemory, "Use Archive.open() for on-disk archives")
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(configuration: Self.makeConfiguration(inMemory: true))
        } catch {
            throw ArchiveError.openFailed(path: ":memory:", underlying: ArchiveError.detail(from: error))
        }
        try Self.migrate(queue)
        self.init(writer: queue)
    }

    /// An on-disk archive at an explicit path, with migrations applied.
    ///
    /// Used by the fixture and migration tests, and by anything that needs a real
    /// file without disturbing the user's archive. The directory must already exist;
    /// this does not run ``ArchivePaths/prepare()``, because the path is not
    /// necessarily inside the support directory.
    public convenience init(path: String) throws {
        let pool = try Self.makePool(path: path)
        try Self.migrate(pool)
        self.init(writer: pool)
    }

    // MARK: Public

    /// The app's archive, at `~/Library/Application Support/Backglance/archive.sqlite`.
    ///
    /// Opening is fatal on failure by design. An archive that cannot be opened leaves
    /// the app with nothing to show and nowhere to write, and every *recoverable*
    /// cause — missing Full Disk Access, an unreadable support directory — is caught
    /// during onboarding, before anything touches this property. What is left is a
    /// corrupt or unwritable file, which needs the user's attention rather than a
    /// silently half-working app.
    public static let shared: Archive = {
        do {
            return try Archive.open()
        } catch {
            let description = (error as? ArchiveError)?.logDescription ?? ArchiveError.detail(from: error)
            fatalError("Archive cannot open: \(description)")
        }
    }()

    /// The underlying GRDB writer.
    ///
    /// `any DatabaseWriter` rather than `DatabasePool` so the in-memory `DatabaseQueue`
    /// used by tests and the on-disk pool used by the app share one code path — both
    /// provide `read` and `write`.
    ///
    /// Exposed so the UI can build `ValueObservation.tracking { … }.values(in:)` and
    /// so search can stream large result sets, which a fixed set of typed helpers
    /// cannot express. Prefer a typed helper on `Archive` where one exists.
    public var pool: any DatabaseWriter {
        writer
    }

    /// Opens (creating if needed) the archive at ``ArchivePaths/archiveURL`` and
    /// applies every migration.
    ///
    /// `ArchivePaths.prepare()` runs first so the support directory exists at `0700`,
    /// and again afterwards so the `-wal` and `-shm` files SQLite creates on open are
    /// tightened to `0600` — they hold notification text just as the main file does,
    /// and SQLite creates them with the process umask.
    public static func open() throws -> Archive {
        try ArchivePaths.prepare()
        let path = ArchivePaths.archiveURL.path
        let pool = try makePool(path: path)
        try migrate(pool)
        try? ArchivePaths.prepare()
        return Archive(writer: pool)
    }

    // MARK: Internal

    /// The PRAGMA set every connection in the pool gets, applied through
    /// `prepareDatabase` so a connection opened later cannot miss one.
    ///
    /// Each is documented in docs/architecture/DATABASE_SCHEMA.md#pragma-settings;
    /// the two that are not merely performance tuning:
    ///
    /// - `foreign_keys = ON` is what makes the cascades real. Deleting an app row has
    ///   to take its notifications with it, and a digest has to take its items.
    /// - `secure_delete = ON` overwrites freed pages with zeros, so the text of a
    ///   notification deleted by retention or by the user does not linger in the
    ///   file's free list. Without it, "delete" would only mean "unlink".
    ///
    /// The same PRAGMAs are applied to an in-memory database even though a few of
    /// them (the journal size cap, `secure_delete`) have nothing to act on there —
    /// one code path means a test exercises the configuration the app actually ships.
    /// `inMemory` only changes the connection label, so a GRDB trace or a crash log
    /// says which kind of archive it came from.
    static func makeConfiguration(inMemory: Bool) -> Configuration {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.foreignKeysEnabled = true
        config.label = inMemory
            ? "app.backglance.Backglance.archive.memory"
            : "app.backglance.Backglance.archive"
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA secure_delete = ON")
            try db.execute(sql: "PRAGMA journal_size_limit = 67108864")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
        }
        #if DEBUG
            // Readable SQL in debug logs. Must stay DEBUG-only: in Release, GRDB redacts
            // bound values from error messages, which is what keeps notification text out
            // of backglance.log when a statement fails.
            config.publicStatementArguments = true
        #endif
        return config
    }

    // MARK: Private

    private let writer: any DatabaseWriter

    private static func makePool(path: String) throws -> DatabasePool {
        do {
            // DatabasePool sets journal_mode = WAL on open; it is the only journal
            // mode it supports, which is why WAL is not in the PRAGMA set above.
            return try DatabasePool(path: path, configuration: makeConfiguration(inMemory: false))
        } catch {
            throw ArchiveError.openFailed(path: path, underlying: ArchiveError.detail(from: error))
        }
    }

    /// Applies the migration chain, mapping any failure to ``ArchiveError``.
    ///
    /// GRDB reports which migration failed inside its own error; the name is repeated
    /// in `ArchiveError.migrationFailed` so the log line names it without needing the
    /// underlying string parsed. A failure here leaves the archive at the last
    /// successfully applied migration — each runs in its own transaction — so the
    /// user's data survives a bad upgrade.
    private static func migrate(_ writer: some DatabaseWriter) throws {
        let migrator = ArchiveMigrations.migrator()
        do {
            try migrator.migrate(writer)
        } catch {
            let applied = (try? writer.read { db in try migrator.appliedIdentifiers(db) }) ?? []
            let failed = migrator.migrations.first { !applied.contains($0) } ?? "unknown"
            throw ArchiveError.migrationFailed(name: failed, underlying: ArchiveError.detail(from: error))
        }
    }
}
