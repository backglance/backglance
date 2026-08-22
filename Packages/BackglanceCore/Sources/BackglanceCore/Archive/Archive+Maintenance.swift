import Foundation
import GRDB

// MARK: - Space and shape

public extension Archive {
    /// How the file is laid out right now: total pages, and how many of them are free.
    ///
    /// The ratio between the two is what decides whether a full `VACUUM` is worth its
    /// cost — a file that is a fifth empty is worth repacking, and one that is not is
    /// worth leaving alone.
    struct SpaceReport: Sendable, Equatable {
        // MARK: Lifecycle

        init(pageCount: Int, freelistCount: Int, pageSize: Int) {
            self.pageCount = pageCount
            self.freelistCount = freelistCount
            self.pageSize = pageSize
        }

        // MARK: Public

        public let pageCount: Int
        public let freelistCount: Int
        public let pageSize: Int

        /// Bytes the file occupies, free pages included.
        public var byteCount: Int64 {
            Int64(pageCount) * Int64(pageSize)
        }

        /// The fraction of the file that is free space. `0` for an empty database, which
        /// keeps the caller from having to guard a division it would otherwise repeat.
        public var freeRatio: Double {
            guard pageCount > 0 else {
                return 0
            }
            return Double(freelistCount) / Double(pageCount)
        }
    }

    func spaceReport() throws -> SpaceReport {
        do {
            return try pool.read { db in
                try SpaceReport(
                    pageCount: Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0,
                    freelistCount: Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0,
                    pageSize: Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4_096
                )
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// Whether this archive can reclaim free pages without rewriting the whole file.
    ///
    /// False for any archive created before `auto_vacuum = INCREMENTAL` was set on the
    /// connection, because the pragma only takes on a database with no tables yet. Worth
    /// asking rather than assuming: `PRAGMA incremental_vacuum` on such a file is a silent
    /// no-op, and a maintenance routine that could not tell the difference would report
    /// success for work it never did.
    func supportsIncrementalVacuum() throws -> Bool {
        do {
            return try pool.read { db in
                try Int.fetchOne(db, sql: "PRAGMA auto_vacuum") == 2
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }
}

// MARK: - The maintenance operations

public extension Archive {
    /// Returns up to `pages` free pages to the filesystem.
    ///
    /// Cheap and interruptible: an ordinary write, no exclusive lock beyond one, no file
    /// rewrite. A no-op on an archive that does not ``supportsIncrementalVacuum()``.
    func incrementalVacuum(pages: Int) throws {
        do {
            try pool.write { db in
                try db.execute(sql: "PRAGMA incremental_vacuum(\(max(0, pages)))")
            }
        } catch {
            throw ArchiveError.writeFailed(table: "pragma", underlying: ArchiveError.detail(from: error))
        }
    }

    /// Rewrites the file, repacking it and shrinking it to what it actually holds.
    ///
    /// Expensive, and the only maintenance operation that can fail for a reason outside
    /// the database: `VACUUM` builds the new file alongside the old one, so it needs room
    /// for a second copy. Rather than let SQLite discover that halfway through and leave
    /// the volume full, the space is checked first and
    /// ``ArchiveError/insufficientDiskSpace(needed:available:)`` is thrown before anything
    /// is written.
    ///
    /// It also sets `auto_vacuum = INCREMENTAL` first. That is what converts an archive
    /// created before the pragma was on the connection: the setting is recorded by the
    /// rewrite, so the cheap incremental path works from then on. On a file that already
    /// has it, the statement is a no-op.
    ///
    /// Outside `pool.write`: `VACUUM` cannot run inside a transaction, and every GRDB
    /// write closure is one.
    func vacuum() throws {
        let report = try spaceReport()
        if let available = Self.availableCapacity(forArchiveAt: pool.path), available < report.byteCount {
            throw ArchiveError.insufficientDiskSpace(needed: report.byteCount, available: available)
        }
        do {
            try pool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
                try db.execute(sql: "VACUUM")
            }
        } catch {
            throw ArchiveError.writeFailed(table: "vacuum", underlying: ArchiveError.detail(from: error))
        }
    }

    /// Merges the FTS index's b-tree segments.
    ///
    /// Every delete leaves the index with another segment, and a query has to visit all of
    /// them — so an archive that has been pruned many times gets slower at searching
    /// without getting any larger. This is the maintenance that keeps
    /// `docs/deployment/PERFORMANCE_GUIDE.md`'s p95 honest after a year of use.
    func optimizeSearchIndex() throws {
        do {
            try pool.write { db in
                try db.execute(sql: "INSERT INTO notifications_fts(notifications_fts) VALUES ('optimize')")
            }
        } catch {
            throw ArchiveError.writeFailed(table: "notifications_fts", underlying: ArchiveError.detail(from: error))
        }
    }

    /// Reads a `schema_meta` value, or `nil` when it has never been written.
    func metaValue(forKey key: String) throws -> String? {
        do {
            return try pool.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM schema_meta WHERE key = ?", arguments: [key])
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    func setMetaValue(_ value: String, forKey key: String) throws {
        do {
            try pool.write { db in
                try db.execute(
                    sql: "INSERT INTO schema_meta(key, value) VALUES (?, ?) " +
                        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key, value]
                )
            }
        } catch {
            throw ArchiveError.writeFailed(table: "schema_meta", underlying: ArchiveError.detail(from: error))
        }
    }

    // MARK: Internal

    /// Free space on the volume holding the archive, or `nil` when it cannot be
    /// determined.
    ///
    /// `nil` means "do not know", and the caller treats that as "go ahead" rather than
    /// "refuse". An in-memory archive reports `:memory:` as its path and has no volume at
    /// all; a check that blocked maintenance whenever it could not measure would turn an
    /// unknown into a permanent no, which is the wrong way for a maintenance routine to
    /// fail.
    static func availableCapacity(forArchiveAt path: String) -> Int64? {
        guard path != ":memory:", !path.isEmpty else {
            return nil
        }
        let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
