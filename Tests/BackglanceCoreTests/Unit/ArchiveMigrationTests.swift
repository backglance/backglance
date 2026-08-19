@testable import BackglanceCore
import BackglanceTestSupport
import CryptoKit
import Foundation
import GRDB
import XCTest

/// Migration tests, in three parts:
///
/// 1. a fresh database reaches the current schema,
/// 2. every archive under `Tests/Fixtures/Archive/v*.sqlite` — each one a database
///    written by an earlier build — still migrates and keeps its rows,
/// 3. no *shipped* migration has been edited.
///
/// The third one is the reason this file exists. A migration that has reached a user's
/// machine is recorded in their `grdb_migrations` table as applied, so editing it means
/// their archive silently never receives the correction while a fresh install does —
/// two different schemas under one version number, with nothing to detect the split.
/// ``testShippedMigrationsHaveNotBeenEdited`` pins the schema each shipped migration
/// produces so that editing one fails here instead.
///
/// See docs/testing/TESTING.md#migration-tests and
/// docs/architecture/DATABASE_SCHEMA.md#rules-for-writing-migrations.
final class ArchiveMigrationTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("bg-migrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        try super.tearDownWithError()
    }

    // MARK: - A fresh database

    func testFreshDatabaseReachesTheCurrentSchema() throws {
        let archive = try Archive(path: scratch.appendingPathComponent("fresh.sqlite").path)

        let applied = try archive.pool.read { db in
            try ArchiveMigrations.migrator().appliedMigrations(db)
        }
        XCTAssertEqual(applied, ArchiveMigrations.migrator().migrations)

        let version = try archive.pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM schema_meta WHERE key = 'archive_version'")
        }
        XCTAssertEqual(version, String(ArchiveMigrations.currentArchiveVersion))
    }

    // MARK: - Archives written by earlier builds

    func testCheckedInArchivesMigrateAndKeepTheirRows() throws {
        let fixtures = try archivedFixtures()
        XCTAssertFalse(fixtures.isEmpty, "no v*.sqlite under Tests/Fixtures/Archive — the resource is not bundled")

        for fixture in fixtures {
            let name = fixture.lastPathComponent
            let copy = scratch.appendingPathComponent(name)
            try FileManager.default.copyItem(at: fixture, to: copy)

            let before = try countNotifications(at: copy)
            XCTAssertGreaterThan(before, 0, "\(name): fixture has no rows, so it proves nothing")

            let archive = try Archive(path: copy.path)

            let applied = try archive.pool.read { db in
                try ArchiveMigrations.migrator().appliedMigrations(db)
            }
            XCTAssertEqual(applied, ArchiveMigrations.migrator().migrations, name)

            let after = try archive.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM notifications") ?? -1
            }
            XCTAssertEqual(after, before, "\(name): rows lost in migration")

            // An FTS index that fell out of step with its content table is the failure
            // mode a migration is most likely to introduce, and it presents as "search
            // quietly returns nothing" rather than as an error.
            let indexed = try archive.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM notifications_fts") ?? -1
            }
            XCTAssertEqual(indexed, after, "\(name): FTS out of sync after migration")
        }
    }

    func testMigratingAnArchiveTwiceIsIdempotent() throws {
        for fixture in try archivedFixtures() {
            let copy = scratch.appendingPathComponent("twice-\(fixture.lastPathComponent)")
            try FileManager.default.copyItem(at: fixture, to: copy)

            _ = try Archive(path: copy.path)
            XCTAssertNoThrow(try Archive(path: copy.path), fixture.lastPathComponent)
        }
    }

    // MARK: - Shipped migrations are frozen

    /// Migrating a fresh database up to each shipped migration in turn and comparing
    /// the schema it produces against a pinned fingerprint.
    ///
    /// Pinning per migration rather than pinning the final schema is what lets a *new*
    /// migration be added freely: `v2_…` changes the final schema but not the schema at
    /// `v1_fts`, so only an edit to an already-shipped migration trips this.
    func testShippedMigrationsHaveNotBeenEdited() throws {
        let registered = ArchiveMigrations.migrator().migrations
        XCTAssertEqual(
            Array(registered.prefix(Self.shippedSchemaFingerprints.count)),
            Self.shippedSchemaFingerprints.map(\.migration),
            "a shipped migration was renamed, reordered, or removed"
        )

        for (index, pinned) in Self.shippedSchemaFingerprints.enumerated() {
            let path = scratch.appendingPathComponent("pinned-\(index).sqlite").path
            let queue = try DatabaseQueue(path: path)
            var migrator = ArchiveMigrations.migrator()
            // eraseDatabaseOnSchemaChange is on in DEBUG and would paper over exactly
            // the change this test exists to catch.
            migrator.eraseDatabaseOnSchemaChange = false
            try migrator.migrate(queue, upTo: pinned.migration)

            let actual = try queue.read { db in try Self.schemaFingerprint(db) }
            XCTAssertEqual(
                actual,
                pinned.fingerprint,
                """
                Migration "\(pinned.migration)" no longer produces the schema it shipped with.
                A shipped migration is already recorded as applied in every existing archive, so \
                editing it gives new installs one schema and existing users another. Add a new \
                migration instead. If this migration has genuinely never shipped, update its \
                pinned fingerprint here to \(actual).
                """
            )
        }
    }

    // MARK: Private

    /// One entry per migration that has shipped, in registration order. Append to this
    /// list when a release goes out; never edit an existing entry.
    private static let shippedSchemaFingerprints: [(migration: String, fingerprint: String)] = [
        ("v1_initial", "9d21b5efcdf69f485e088afd4bd7948b3a09dc6434919769d1ad3d494c228855"),
        ("v1_fts", "5c61074292628f5a47591b7fa467de28ec4ccecbaa673f898049752a6826e25f"),
    ]

    private var scratch: URL!

    /// SHA-256 over every object in `sqlite_master`, ordered so the digest depends on
    /// the schema and not on the order SQLite happens to return rows in.
    ///
    /// `grdb_migrations` is excluded: its *contents* differ by how far the migration ran,
    /// and its definition is GRDB's, not ours to freeze.
    private static func schemaFingerprint(_ db: Database) throws -> String {
        let rows = try Row.fetchAll(db, sql: """
        SELECT type, name, coalesce(sql, '') AS sql FROM sqlite_master
        WHERE name <> 'grdb_migrations' AND name NOT LIKE 'sqlite_%'
        ORDER BY type, name
        """)
        let canonical = rows
            .map { "\($0["type"] as String)\u{1}\($0["name"] as String)\u{1}\($0["sql"] as String)" }
            .joined(separator: "\u{2}")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func archivedFixtures() throws -> [URL] {
        let root = Fixtures.archive
        guard Fixtures.exists(root) else {
            return []
        }
        let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return contents
            .filter { $0.lastPathComponent.hasPrefix("v") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Counts rows without going through `Archive`, so the count is taken *before* any
    /// migration runs.
    private func countNotifications(at url: URL) throws -> Int {
        var config = Configuration()
        config.readonly = true
        return try DatabaseQueue(path: url.path, configuration: config).read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM notifications") ?? -1
        }
    }
}
