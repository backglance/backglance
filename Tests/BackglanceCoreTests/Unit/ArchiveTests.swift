@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

final class ArchiveTests: XCTestCase {
    // MARK: Internal

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Opening

    func testInMemoryArchiveAppliesEveryMigration() throws {
        let archive = try Archive(inMemory: true)

        let applied = try archive.pool.read { db in
            try ArchiveMigrations.migrator().appliedIdentifiers(db)
        }
        XCTAssertEqual(applied, ["v1_initial", "v1_fts", "v2_embeddings"])
    }

    func testInMemoryArchiveCreatesEveryTableInTheCanonicalDDL() throws {
        let archive = try Archive(inMemory: true)

        let tables = try archive.pool.read { db in
            try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        let expected: Set = [
            "apps", "away_sessions", "notifications", "rules",
            "digests", "digest_items", "redactions", "capture_state", "schema_meta",
            "notifications_fts",
        ]
        XCTAssertTrue(expected.isSubset(of: tables), "missing: \(expected.subtracting(tables).sorted())")
    }

    func testInMemoryArchiveCreatesTheThreeFTSSyncTriggers() throws {
        let archive = try Archive(inMemory: true)

        let triggers = try archive.pool.read { db in
            try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger'")
        }
        XCTAssertEqual(triggers, ["notifications_ai", "notifications_ad", "notifications_au"])
    }

    func testMigrationRecordsTheArchiveVersion() throws {
        let archive = try Archive(inMemory: true)

        let version = try archive.pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM schema_meta WHERE key = 'archive_version'")
        }
        XCTAssertEqual(version, String(ArchiveMigrations.currentArchiveVersion))
        XCTAssertEqual(BackglanceCore.archiveSchemaVersion, ArchiveMigrations.currentArchiveVersion)
    }

    func testOnDiskArchiveOpensInWALMode() throws {
        let archive = try Archive(path: makeTemporaryArchivePath())

        let journalMode = try archive.pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        XCTAssertEqual(journalMode?.lowercased(), "wal")
    }

    func testReopeningAnExistingArchiveIsIdempotent() throws {
        let path = makeTemporaryArchivePath()
        _ = try Archive(path: path)

        // The second open must re-apply nothing and must not fail on an already
        // migrated file — this is what every launch after the first one does.
        let reopened = try Archive(path: path)
        let applied = try reopened.pool.read { db in
            try ArchiveMigrations.migrator().appliedIdentifiers(db)
        }
        XCTAssertEqual(applied, ["v1_initial", "v1_fts", "v2_embeddings"])
    }

    // MARK: - PRAGMA set

    func testDocumentedPragmasAreAppliedToEveryConnection() throws {
        let archive = try Archive(path: makeTemporaryArchivePath())

        try archive.pool.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA foreign_keys"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA secure_delete"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA journal_size_limit"), 67_108_864)
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA temp_store"), 2) // 2 = MEMORY
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA synchronous"), 1) // 1 = NORMAL
        }
    }

    /// `PRAGMA foreign_keys` being on is only interesting if the cascade actually
    /// fires: deleting an app has to take its notifications with it, or a wipe of one
    /// app would leave orphaned notification text in the file.
    func testForeignKeyCascadeDeletesNotificationsWithTheirApp() throws {
        let archive = try Archive(inMemory: true)

        try archive.pool.write { db in
            try db.execute(
                sql: "INSERT INTO apps(bundle_id, first_seen_at, last_seen_at) VALUES ('com.example.demo', 0, 0)"
            )
            try db.execute(sql: """
            INSERT INTO notifications(uuid, app_id, delivered_at, captured_at)
            VALUES ('11111111-1111-1111-1111-111111111111', 1, 0, 0)
            """)
            try db.execute(sql: "DELETE FROM apps WHERE id = 1")
        }

        let remaining = try archive.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM notifications")
        }
        XCTAssertEqual(remaining, 0)
    }

    func testConfigurationLabelDistinguishesInMemoryFromOnDisk() {
        XCTAssertNotEqual(
            Archive.makeConfiguration(inMemory: true).label,
            Archive.makeConfiguration(inMemory: false).label
        )
    }

    // MARK: - Integrity of the FTS wiring

    /// The insert trigger is what makes a captured notification findable at all, so a
    /// broken trigger would look like "search returns nothing" rather than an error.
    func testInsertingANotificationPopulatesTheFTSIndex() throws {
        let archive = try Archive(inMemory: true)

        try archive.pool.write { db in
            try db.execute(
                sql: "INSERT INTO apps(bundle_id, first_seen_at, last_seen_at) VALUES ('com.example.demo', 0, 0)"
            )
            try db.execute(sql: """
            INSERT INTO notifications(uuid, app_id, title, delivered_at, captured_at)
            VALUES ('22222222-2222-2222-2222-222222222222', 1, 'quarterly invoice', 0, 0)
            """)
        }

        let hits = try archive.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM notifications_fts WHERE notifications_fts MATCH 'invoice'")
        }
        XCTAssertEqual(hits, 1)
    }

    // MARK: Private

    private var temporaryDirectory: URL?

    private func makeTemporaryArchivePath() -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backglance-archive-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory
        return directory.appendingPathComponent("archive.sqlite").path
    }
}
