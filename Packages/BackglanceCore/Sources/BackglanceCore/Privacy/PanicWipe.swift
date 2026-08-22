import Foundation
import GRDB
import os

// MARK: - PanicWipe

/// Deletes everything Backglance has stored, and starts over.
///
/// The one operation in the app that is meant to lose data. Everything else — retention,
/// per-app forget, exclusions — removes some rows and leaves the archive standing; this
/// removes the archive. It exists because "delete my history" has to be a single action a
/// frightened person can take in a hurry and trust afterwards, not a settings expedition.
///
/// > 🔒 Order matters, and the order is: zero the pages, *then* unlink. Unlinking first
/// > would leave every notification's text sitting in the blocks the file used to occupy,
/// > readable by anything that undeletes a file — which is precisely the threat this
/// > feature is meant to answer. `secure_delete` overwrites freed pages with zeros as the
/// > rows go, the checkpoint folds the WAL back in, and `VACUUM` rewrites the file
/// > compactly, so what the unlink releases is zeros.
///
/// What it does **not** do is documented in
/// docs/features/PRIVACY_CONTROLS.md#what-the-wipe-does-not-do and shown to the user
/// verbatim in the confirmation sheet: Apple's store, Time Machine backups, APFS local
/// snapshots and exports the user saved are not Backglance's files, and the wipe says so
/// rather than implying a reach it does not have.
///
/// The caller owns consent. This function assumes it: the typed "wipe", the optional Touch
/// ID, and stopping capture first are all the sheet's job, because a function that asks its
/// own questions cannot be driven from a URL scheme, a test, or a future App Intent.
///
/// See docs/api/API_DOCUMENTATION.md#panicwipe.
public enum PanicWipe {
    // MARK: Public

    /// What a wipe managed to remove, by file name.
    ///
    /// Names, never paths: this crosses into log lines and the diagnostics export, and a
    /// path carries the user's account name. `archive.sqlite` is all anyone needs to know
    /// which file did not go.
    public struct Report: Sendable, Equatable {
        // MARK: Lifecycle

        public init(removed: [String] = [], failed: [String] = []) {
            self.removed = removed
            self.failed = failed
        }

        // MARK: Public

        /// Files and directories that no longer exist. Ones that were already absent are
        /// not listed: a wipe that ran on a Mac with no icon cache removed nothing there
        /// and should not claim otherwise.
        public var removed: [String]

        /// Files the wipe could not remove. Non-empty means
        /// ``ArchiveError/wipeIncomplete(remaining:)`` was thrown.
        public var failed: [String]
    }

    /// What a wipe should carry across, and what it should not.
    public struct Options: Sendable, Equatable {
        // MARK: Lifecycle

        public init(forgetPerAppSettings: Bool = false) {
            self.forgetPerAppSettings = forgetPerAppSettings
        }

        // MARK: Public

        /// Whether excluded apps, retention overrides and redaction toggles go with the
        /// notifications.
        ///
        /// Off by default, and deliberately so: those rows are bundle identifiers and
        /// flags, not content, and someone who excluded their password manager did not
        /// ask for that to be undone by a wipe — an exclusion silently disappearing is how
        /// the next notification from that app ends up archived. The confirmation sheet
        /// offers the switch for the people who do want a completely fresh start.
        public var forgetPerAppSettings: Bool
    }

    /// Empties the archive, unlinks every file Backglance owns beside it, and recreates an
    /// empty one at the same path.
    ///
    /// The `Archive` passed in stays valid throughout and is the same object afterwards:
    /// its writer is swapped, not its identity. That is what lets the timeline store,
    /// search and the digest presenter keep the reference they were given at launch —
    /// there is no reopening to coordinate and no window in which some component still
    /// holds the deleted file open.
    ///
    /// - Throws: ``ArchiveError/wipeIncomplete(remaining:)`` if any file survived. The
    ///   empty archive is recreated first either way, so a Mac whose `icons/` directory
    ///   could not be removed still has a working, empty Backglance rather than none.
    @MainActor
    @discardableResult
    public static func execute(archive: Archive, options: Options = Options()) async throws -> Report {
        log.notice("panic wipe: begin")

        // Read before anything is destroyed; written back after the new archive exists.
        let preserved = options.forgetPerAppSettings ? [] : try archive.perAppPrivacySettings()

        try zeroPages(of: archive.pool)

        guard case .file = archive.location else {
            // Nothing on disk to unlink, and nothing to recreate: emptying the tables was
            // the whole of the wipe. The test archive takes this path.
            try archive.restorePerAppPrivacySettings(preserved)
            log.notice("panic wipe: done, in-memory archive")
            return Report()
        }

        // Hand every existing reader something valid to read before the file goes. An
        // empty, migrated in-memory database answers "no notifications" rather than "no
        // such table", so a `ValueObservation` that fires mid-wipe redraws an empty
        // timeline instead of surfacing an error the user cannot act on.
        let discarded = try archive.replaceWriter(with: makePlaceholder())
        try? discarded.close()

        let report = removeFiles(at: archive.location.ownedPaths)
        try reopen(archive)
        try archive.restorePerAppPrivacySettings(preserved)

        if report.failed.isEmpty {
            log.notice("panic wipe: done, removed \(report.removed.count, privacy: .public) paths")
        } else {
            log.error("panic wipe: \(report.failed.count, privacy: .public) paths could not be removed")
            throw ArchiveError.wipeIncomplete(remaining: report.failed)
        }
        return report
    }

    // MARK: Internal

    /// Overwrites every row's pages with zeros and rewrites the file compactly.
    ///
    /// The tables are read from `sqlite_master` rather than listed here, so a migration
    /// that adds one does not quietly leave its contents behind — the failure mode of a
    /// hardcoded list is a table nobody remembered, full of exactly the data the user asked
    /// to destroy.
    ///
    /// `notifications_fts`'s shadow tables are skipped and left to the `notifications_ad`
    /// trigger, which is the only supported way to take a row out of an FTS5 index;
    /// deleting from a shadow table directly corrupts the index and would abort the wipe
    /// partway through.
    ///
    /// Internal rather than private so `PanicWipeTests` can run it against an on-disk
    /// archive and read the file's raw bytes afterwards. That test is the only proof the
    /// 🔒 invariant above holds; through ``execute(archive:)`` alone the file is already
    /// unlinked by the time anything could look at it.
    static func zeroPages(of writer: any DatabaseWriter) throws {
        do {
            try writer.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA secure_delete = ON")
                let tables = try String.fetchAll(db, sql: """
                    SELECT name FROM sqlite_master
                     WHERE type = 'table'
                       AND name NOT LIKE 'sqlite_%'
                       AND name NOT LIKE 'notifications_fts%'
                     ORDER BY name
                """)
                // Foreign keys off for the duration: with them on, the order tables are
                // emptied in decides whether a delete succeeds or trips a constraint, and
                // "every table" has no order that satisfies every future schema.
                try db.execute(sql: "PRAGMA foreign_keys = OFF")
                defer { try? db.execute(sql: "PRAGMA foreign_keys = ON") }
                try db.inTransaction {
                    for table in tables {
                        try db.execute(sql: "DELETE FROM \(table.quotedDatabaseIdentifier)")
                    }
                    return .commit
                }
                // The WAL holds the old pages until it is folded back in, and `VACUUM`
                // rewrites what is left. Both are what make the unlink release zeros.
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                try db.execute(sql: "VACUUM")
            }
        } catch {
            throw ArchiveError.writeFailed(table: "wipe", underlying: ArchiveError.detail(from: error))
        }
    }

    // MARK: Private

    private static let log = Logger(subsystem: "app.backglance.Backglance", category: "archive")

    /// A migrated, empty in-memory database for readers to hold during the unlink.
    private static func makePlaceholder() throws -> any DatabaseWriter {
        try Archive(inMemory: true).pool
    }

    private static func removeFiles(at urls: [URL]) -> Report {
        var report = Report()
        let fileManager = FileManager.default
        for url in urls {
            do {
                try fileManager.removeItem(at: url)
                report.removed.append(url.lastPathComponent)
            } catch CocoaError.fileNoSuchFile {
                continue // Already gone. A Mac with no icon cache has nothing to remove.
            } catch {
                // The name, never the path: a path carries the user's account name into
                // the log (Privacy Invariant #1).
                log.error("panic wipe: could not remove \(url.lastPathComponent, privacy: .public)")
                report.failed.append(url.lastPathComponent)
            }
        }
        return report
    }

    /// Puts a fresh, migrated archive back at the same path.
    ///
    /// The path comes from the archive that was passed in rather than from
    /// ``ArchivePaths/archiveURL``, so a test wipes its own temporary file; the directory
    /// and permission work is `ArchivePaths`' either way, which is why it takes an explicit
    /// URL. It runs twice for the same reason ``Archive/open()`` does: once to put back
    /// `icons/` and `tmp/` at `0700`, and once more afterwards to tighten the `-wal` and
    /// `-shm` files SQLite creates on open with the process umask.
    private static func reopen(_ archive: Archive) throws {
        guard let url = archive.location.fileURL else {
            return
        }
        // The support directory is the one part that has to succeed — without it there is
        // nowhere to put the new file. `prepare` is best-effort around it: a leftover
        // `icons/` that could not be removed also cannot be recreated, and that is already
        // being reported as an incomplete wipe. Failing here on top of it would turn "one
        // directory survived" into "the app has no archive".
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? ArchivePaths.prepare(archiveURL: url)
        let fresh = try Archive(path: url.path)
        try? ArchivePaths.prepare(archiveURL: url)
        let placeholder = archive.replaceWriter(with: fresh.pool)
        try? placeholder.close()
    }
}
