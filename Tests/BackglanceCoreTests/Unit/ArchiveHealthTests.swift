@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

final class ArchiveHealthTests: XCTestCase {
    // MARK: Internal

    // MARK: - A freshly migrated archive is healthy

    func testFreshInMemoryArchiveIsHealthyAtQuickLevel() throws {
        let archive = try Archive(inMemory: true)

        let health = try archive.checkIntegrity(level: .quick)

        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.messages, [])
    }

    func testFreshInMemoryArchiveIsHealthyAtFullLevel() throws {
        let archive = try Archive(inMemory: true)

        let health = try archive.checkIntegrity(level: .full)

        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.messages, [])
    }

    // MARK: - Populated archive stays healthy

    func testArchiveWithRowsStaysHealthy() throws {
        let archive = try Archive(inMemory: true)
        try insertAppAndNotification(into: archive)

        let quick = try archive.checkIntegrity(level: .quick)
        let full = try archive.checkIntegrity(level: .full)

        XCTAssertTrue(quick.ok)
        XCTAssertTrue(full.ok)
    }

    // MARK: - Foreign-key violation

    func testForeignKeyViolationIsReportedAtQuickLevel() throws {
        let archive = try Archive(inMemory: true)

        // Turn foreign keys off for this one connection only, so an orphaned
        // notification can actually be inserted without SQLite refusing it up front.
        // `PRAGMA foreign_keys` is a documented no-op inside a transaction, and
        // `pool.write` opens one implicitly, so this needs `writeWithoutTransaction`.
        try archive.pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: """
            INSERT INTO notifications(uuid, app_id, delivered_at, captured_at)
            VALUES ('33333333-3333-3333-3333-333333333333', 999, 0, 0)
            """)
        }

        let health = try archive.checkIntegrity(level: .quick)

        XCTAssertFalse(health.ok)
        XCTAssertTrue(
            health.messages.contains { $0.contains("foreign_key_check") },
            "expected a foreign_key_check message, got \(health.messages)"
        )
    }

    func testForeignKeyViolationIsReportedAtFullLevelToo() throws {
        let archive = try Archive(inMemory: true)

        try archive.pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: """
            INSERT INTO notifications(uuid, app_id, delivered_at, captured_at)
            VALUES ('44444444-4444-4444-4444-444444444444', 999, 0, 0)
            """)
        }

        let health = try archive.checkIntegrity(level: .full)

        XCTAssertFalse(health.ok)
        XCTAssertTrue(health.messages.contains { $0.contains("foreign_key_check") })
    }

    // MARK: - Corrupted FTS index

    /// A "ghost" posting — an FTS row with no backing `notifications` row — is exactly
    /// what the external-content self-check exists to catch: the index and the
    /// content table disagree. Confirmed by direct probe (see task report) that this
    /// trips `INSERT INTO notifications_fts(notifications_fts, rank) VALUES
    /// ('integrity-check', 1)` before writing this assertion.
    func testGhostFTSPostingIsDetected() throws {
        let archive = try Archive(inMemory: true)
        try insertAppAndNotification(into: archive)

        try archive.pool.write { db in
            try db.execute(sql: """
            INSERT INTO notifications_fts(rowid, title, subtitle, body, sender)
            VALUES (999, 'ghost', NULL, NULL, NULL)
            """)
        }

        let health = try archive.checkIntegrity(level: .quick)

        XCTAssertFalse(health.ok)
        XCTAssertTrue(
            health.messages.contains { $0.contains("fts integrity-check failed") },
            "expected an fts integrity-check message, got \(health.messages)"
        )
    }

    // MARK: Private

    private func insertAppAndNotification(into archive: Archive) throws {
        try archive.pool.write { db in
            try db.execute(
                sql: "INSERT INTO apps(bundle_id, first_seen_at, last_seen_at) VALUES ('com.example.demo', 0, 0)"
            )
            try db.execute(sql: """
            INSERT INTO notifications(uuid, app_id, title, delivered_at, captured_at)
            VALUES ('55555555-5555-5555-5555-555555555555', 1, 'quarterly invoice', 0, 0)
            """)
        }
    }
}
