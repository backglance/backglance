@testable import BackglanceCore
import Foundation
import XCTest

final class ArchiveErrorTests: XCTestCase {
    // MARK: Internal

    // MARK: - Content-free, non-empty descriptions

    func testEveryCaseHasNonEmptyDescriptions() {
        for sample in Self.allSamples {
            XCTAssertFalse(sample.logDescription.isEmpty, "logDescription empty for \(sample)")
            XCTAssertFalse(sample.userMessage.isEmpty, "userMessage empty for \(sample)")
        }
    }

    func testUserMessageIsOnePlainSentenceWithNoPathsOrSQL() {
        for sample in Self.allSamples {
            let message = sample.userMessage
            XCTAssertTrue(message.hasSuffix("."), "userMessage should end with a period for \(sample)")
            XCTAssertFalse(message.contains("/"), "userMessage should contain no path for \(sample)")
            XCTAssertFalse(message.contains("SQL"), "userMessage should contain no SQL mention for \(sample)")
            XCTAssertFalse(message.contains("SELECT"), "userMessage should contain no SQL text for \(sample)")
            XCTAssertFalse(message.contains("INSERT"), "userMessage should contain no SQL text for \(sample)")
        }
    }

    // MARK: - logDescription carries the identifier that was passed in

    func testOpenFailedLogDescriptionIncludesPath() {
        let error = ArchiveError.openFailed(path: "/tmp/archive.sqlite", underlying: "disk full")
        XCTAssertTrue(error.logDescription.contains("/tmp/archive.sqlite"))
        XCTAssertTrue(error.logDescription.contains("disk full"))
    }

    func testMigrationFailedLogDescriptionIncludesName() {
        let error = ArchiveError.migrationFailed(name: "v3_add_redactions", underlying: "no such table")
        XCTAssertTrue(error.logDescription.contains("v3_add_redactions"))
        XCTAssertTrue(error.logDescription.contains("no such table"))
    }

    func testInsertFailedLogDescriptionIncludesUUID() {
        let uuid = UUID()
        let error = ArchiveError.insertFailed(uuid: uuid, underlying: "constraint failed")
        XCTAssertTrue(error.logDescription.contains(uuid.uuidString))
        XCTAssertTrue(error.logDescription.contains("constraint failed"))
    }

    func testWipeIncompleteLogDescriptionIncludesJoinedRemaining() {
        let error = ArchiveError.wipeIncomplete(remaining: ["archive.sqlite-wal", "icons"])
        XCTAssertTrue(error.logDescription.contains("archive.sqlite-wal, icons"))
    }

    // MARK: - duplicate is expected, not an error to be surfaced loudly

    func testDuplicateLogDescriptionIsShortAndNeutral() {
        XCTAssertEqual(ArchiveError.duplicate.logDescription, "duplicate")
    }

    // MARK: - unavailable (App Intents surface, see docs/api/API_DOCUMENTATION.md)

    func testUnavailableDescriptions() {
        XCTAssertEqual(ArchiveError.unavailable.logDescription, "unavailable")
        XCTAssertEqual(ArchiveError.unavailable.userMessage, "Backglance is busy, try again in a moment.")
    }

    // MARK: - LocalizedError conformance

    func testErrorDescriptionEqualsUserMessage() {
        for sample in Self.allSamples {
            XCTAssertEqual(sample.errorDescription, sample.userMessage)
        }
    }

    // MARK: Private

    /// One representative value per case. When a new case is added to
    /// ``ArchiveError``, add a sample here too — this list is what makes the tests
    /// above exhaustive, since ``ArchiveError`` does not conform to `CaseIterable`
    /// (several cases carry associated values).
    private static let allSamples: [ArchiveError] = [
        .openFailed(path: "/tmp/archive.sqlite", underlying: "disk full"),
        .migrationFailed(name: "v3_add_redactions", underlying: "no such table"),
        .duplicate,
        .insertFailed(uuid: UUID(), underlying: "constraint failed"),
        .integrityCheckFailed("page 12 checksum mismatch"),
        .observationFailed("observer cancelled"),
        .wipeIncomplete(remaining: ["archive.sqlite-wal", "icons"]),
        .unavailable,
    ]
}
