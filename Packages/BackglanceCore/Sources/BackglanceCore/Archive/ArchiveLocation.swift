import Foundation

// MARK: - Archive.Location

public extension Archive {
    /// Where an archive's bytes are.
    ///
    /// The distinction only matters to the two operations that act on the file rather than
    /// on its rows: ``PanicWipe`` (which unlinks it) and the maintenance vacuum (which
    /// needs to know how much room a rewrite would take). Everything else goes through
    /// ``Archive/pool`` and neither knows nor cares.
    enum Location: Sendable, Equatable {
        /// The test archive. Nothing to unlink; emptying its tables is the whole of a wipe.
        case memory

        /// `archive.sqlite` on disk. SQLite's `-wal` and `-shm` sit beside it, and the
        /// support directory around it holds `icons/` and `tmp/`.
        case file(URL)

        // MARK: Public

        /// The database file, or `nil` for an in-memory archive.
        public var fileURL: URL? {
            switch self {
            case .memory: nil
            case let .file(url): url
            }
        }

        /// Every file and directory Backglance owns at this location, in the order a wipe
        /// should remove them.
        ///
        /// Derived from the archive's own path rather than read from ``ArchivePaths``, so
        /// a wipe removes the files belonging to *this* archive. A test that builds one in
        /// a temporary directory can therefore wipe it without the user's archive ever
        /// entering the picture.
        ///
        /// `-wal` and `-shm` are named as path suffixes, which is how SQLite names them:
        /// `appendingPathExtension` would produce `archive.sqlite.wal`, a file that does
        /// not exist and whose absence would be silently reported as "already gone".
        public var ownedPaths: [URL] {
            guard let url = fileURL else {
                return []
            }
            let directory = url.deletingLastPathComponent()
            return [
                url,
                URL(fileURLWithPath: url.path + "-wal"),
                URL(fileURLWithPath: url.path + "-shm"),
                directory.appendingPathComponent("icons", isDirectory: true),
                directory.appendingPathComponent("tmp", isDirectory: true),
            ]
        }
    }
}
