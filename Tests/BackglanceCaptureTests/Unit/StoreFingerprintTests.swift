@testable import BackglanceCapture
import Foundation
import GRDB
import XCTest

/// ⚠️ These exercise the fingerprint of Apple's undocumented store schema. Every
/// database here is built by hand in the test — nothing reads `~/Library`, and no
/// fixture is required (see docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md).
final class StoreFingerprintTests: XCTestCase {
    // MARK: Internal

    // MARK: - Determinism

    func testTheSameSchemaAlwaysProducesTheSameHash() throws {
        let first = try schemaHash(of: Self.storeLikeSchema)
        let second = try schemaHash(of: Self.storeLikeSchema)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64, "SHA-256 hex is 64 characters")
    }

    /// Case and indentation are cosmetic. If they moved the hash, a store that Apple
    /// merely reformatted would read as an unknown schema and send every user into
    /// degraded mode for nothing.
    func testCaseAndWhitespaceDoNotChangeTheHash() throws {
        let canonical = "CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, data BLOB)"
        let reformatted = """
        create   table record
            (rec_id integer primary key,
             app_id integer,
             data blob)
        """

        XCTAssertEqual(try schemaHash(of: [canonical]), try schemaHash(of: [reformatted]))
    }

    /// The other half of the same property: a change that actually matters must move
    /// the hash, or degraded mode would never trigger and the parser would read a
    /// schema it does not understand.
    func testAnAddedColumnChangesTheHash() throws {
        let before = ["CREATE TABLE record (rec_id INTEGER PRIMARY KEY, data BLOB)"]
        let after = ["CREATE TABLE record (rec_id INTEGER PRIMARY KEY, data BLOB, presented INTEGER)"]

        XCTAssertNotEqual(try schemaHash(of: before), try schemaHash(of: after))
    }

    func testAnAddedTableChangesTheHash() throws {
        let before = ["CREATE TABLE record (rec_id INTEGER PRIMARY KEY)"]
        let after = before + ["CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier TEXT)"]

        XCTAssertNotEqual(try schemaHash(of: before), try schemaHash(of: after))
    }

    /// SQLite names and creates its own internal objects; including them would make
    /// the hash depend on SQLite's version rather than on Apple's schema.
    func testSQLiteInternalObjectsAreExcluded() throws {
        // A UNIQUE constraint makes SQLite create an `sqlite_autoindex_…` entry.
        let schema = ["CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier TEXT UNIQUE)"]
        let hash = try schemaHash(of: schema)

        let objects = try withDatabase(schema) { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master")
        }
        XCTAssertTrue(
            objects.contains { $0.hasPrefix("sqlite_") },
            "precondition: this schema should produce an internal object"
        )
        XCTAssertEqual(hash.count, 64)
        // Declaring the same table without the UNIQUE keyword must differ, proving the
        // exclusion did not simply drop the constraint from the hashed DDL.
        let withoutUnique = ["CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier TEXT)"]
        XCTAssertNotEqual(hash, try schemaHash(of: withoutUnique))
    }

    // MARK: - normalize

    func testNormalizeLowercasesAndCollapsesWhitespace() {
        XCTAssertEqual(
            StoreFingerprinter.normalize("CREATE   TABLE\n\tFoo  ( a\tINTEGER )"),
            "create table foo ( a integer )"
        )
    }

    // MARK: - dbinfo

    func testDbinfoVersionIsNilWhenTheTableIsAbsent() throws {
        let version = try withDatabase(Self.storeLikeSchema) { db in
            try StoreFingerprinter.dbinfoVersion(db)
        }
        XCTAssertNil(version)
    }

    func testDbinfoVersionPicksTheVersionLikeKey() throws {
        let version = try withDatabase(Self.storeLikeSchema + Self.dbinfoSchema) { db in
            try db.execute(sql: "INSERT INTO dbinfo(key, value) VALUES ('lastUsed', '17')")
            try db.execute(sql: "INSERT INTO dbinfo(key, value) VALUES ('schemaVersion', '42')")
            return try StoreFingerprinter.dbinfoVersion(db)
        }
        XCTAssertEqual(version, "42")
    }

    func testDbinfoVersionIsNilWhenNoKeyLooksVersionLike() throws {
        let version = try withDatabase(Self.storeLikeSchema + Self.dbinfoSchema) { db in
            try db.execute(sql: "INSERT INTO dbinfo(key, value) VALUES ('lastUsed', '17')")
            return try StoreFingerprinter.dbinfoVersion(db)
        }
        XCTAssertNil(version)
    }

    func testDbinfoVersionIsNilWhenTheValueIsNull() throws {
        let version = try withDatabase(Self.storeLikeSchema + Self.dbinfoSchema) { db in
            try db.execute(sql: "INSERT INTO dbinfo(key, value) VALUES ('schemaVersion', NULL)")
            return try StoreFingerprinter.dbinfoVersion(db)
        }
        XCTAssertNil(version)
    }

    /// Apple's own table, so the value's storage type is not ours to assume.
    func testDbinfoVersionReadsAnIntegerValue() throws {
        let version = try withDatabase(Self.storeLikeSchema + Self.dbinfoSchema) { db in
            try db.execute(sql: "INSERT INTO dbinfo(key, value) VALUES ('version', 26)")
            return try StoreFingerprinter.dbinfoVersion(db)
        }
        XCTAssertEqual(version, "26")
    }

    // MARK: - compute

    func testComputeFillsEveryPart() throws {
        let fingerprint = try withDatabase(Self.storeLikeSchema + Self.dbinfoSchema) { db in
            try db.execute(sql: "INSERT INTO dbinfo(key, value) VALUES ('schemaVersion', '42')")
            return try StoreFingerprint.compute(in: db)
        }

        XCTAssertEqual(fingerprint.schemaHash.count, 64)
        XCTAssertEqual(fingerprint.dbinfoVersion, "42")
        XCTAssertEqual(
            fingerprint.osVersion.majorVersion,
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    }

    // MARK: - Persistence and logging

    /// The fingerprint is persisted in `capture_state.fingerprint` as JSON, which
    /// `OperatingSystemVersion` does not support without the conformance this module
    /// adds.
    func testFingerprintRoundTripsThroughJSON() throws {
        let original = StoreFingerprint(
            schemaHash: String(repeating: "a", count: 64),
            dbinfoVersion: "42",
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 2)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StoreFingerprint.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testFingerprintWithoutDbinfoRoundTripsThroughJSON() throws {
        let original = StoreFingerprint(
            schemaHash: String(repeating: "b", count: 64),
            dbinfoVersion: nil,
            osVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        )

        let decoded = try JSONDecoder().decode(
            StoreFingerprint.self,
            from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.dbinfoVersion)
    }

    /// `shortDescription` is logged at `privacy: .public`, so it must carry only the
    /// hash prefix, the dbinfo value and the OS version.
    func testShortDescriptionIsShortAndContentFree() {
        let fingerprint = StoreFingerprint(
            schemaHash: "0123456789abcdef" + String(repeating: "0", count: 48),
            dbinfoVersion: "42",
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        )

        XCTAssertEqual(fingerprint.shortDescription, "01234567 dbinfo=42 os=26.1")
    }

    func testShortDescriptionMarksAMissingDbinfoVersion() {
        let fingerprint = StoreFingerprint(
            schemaHash: String(repeating: "c", count: 64),
            dbinfoVersion: nil,
            osVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)
        )

        XCTAssertEqual(fingerprint.shortDescription, "cccccccc dbinfo=- os=14.5")
    }

    // MARK: Private

    /// Shaped like what the playbook records of Apple's store, but entirely invented.
    private static let storeLikeSchema = [
        "CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB, delivered_date REAL)",
        "CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier TEXT)",
        "CREATE INDEX record_app ON record (app_id)",
    ]

    private static let dbinfoSchema = ["CREATE TABLE dbinfo (key TEXT PRIMARY KEY, value)"]

    private func withDatabase<T>(_ schema: [String], _ body: (Database) throws -> T) throws -> T {
        let queue = try DatabaseQueue()
        return try queue.write { db in
            for statement in schema {
                try db.execute(sql: statement)
            }
            return try body(db)
        }
    }

    private func schemaHash(of schema: [String]) throws -> String {
        try withDatabase(schema) { db in try StoreFingerprinter.schemaHash(db) }
    }
}
