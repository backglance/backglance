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

    // MARK: - Content-free underlying details

    /// 🔒 Privacy Invariant #1, at the one place it is easiest to break by accident.
    ///
    /// `Archive` turns on `Configuration.publicStatementArguments` in DEBUG so that SQL
    /// is readable while developing, and that makes GRDB spell a failing statement's
    /// *bound arguments* into the error it throws. The notification insert binds the
    /// title, subtitle, body and sender — so rendering that error with
    /// `String(describing:)` would put a user's notification text straight into
    /// ``ArchiveError/logDescription``, the property documented as safe to log with
    /// `privacy: .public`. A guarantee that only holds in Release is not a guarantee,
    /// which is why ``ArchiveError/detail(from:)`` exists and why this test runs in
    /// whatever configuration the suite was built with.
    func testDatabaseErrorDetailsNeverCarryBoundArguments() throws {
        let archive = try Archive(inMemory: true)
        let secret = "Ada is landing at six"

        // A foreign-key failure specifically, *not* a duplicate: `.duplicate` carries no
        // associated value at all, so it would pass this test without ever reaching the
        // renderer under test. An app id no row has takes the generic catch, which is the
        // path that builds `insertFailed(underlying:)` out of GRDB's error — with the
        // body bound to the failing statement.
        do {
            try archive.insert(Self.notification(appID: 999, uuid: uuidC, body: secret))
            XCTFail("expected the unknown app id to be rejected")
        } catch let error as ArchiveError {
            guard case let .insertFailed(_, underlying) = error else {
                return XCTFail("expected .insertFailed, got \(error.logDescription)")
            }
            XCTAssertFalse(underlying.contains(secret), "notification body reached the error detail")
            XCTAssertFalse(underlying.contains("Ada"), "notification title reached the error detail")
            XCTAssertFalse(error.logDescription.contains(secret), "notification body reached logDescription")
            XCTAssertFalse(error.logDescription.contains("Ada"), "notification title reached logDescription")
            XCTAssertTrue(underlying.hasPrefix("sqlite "), "the result code is what survives: \(underlying)")
        }
    }

    /// The renderer keeps what is diagnostically useful — SQLite's result code and its own
    /// message, which name columns and conditions — and drops the statement and its
    /// arguments, which are the only parts that can carry content.
    func testDetailFromANonDatabaseErrorNamesOnlyTheType() {
        struct Confidential: Error {
            let body = "Ada is landing at six"
        }

        let detail = ArchiveError.detail(from: Confidential())

        XCTAssertEqual(detail, "Confidential")
        XCTAssertFalse(detail.contains("Ada"))
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

    private let uuidC = "CCCCCCCC-0000-4000-8000-000000000003"

    private static func notification(appID: Int64, uuid: String, body: String) -> ArchivedNotification {
        ArchivedNotification(
            id: nil,
            uuid: uuid,
            appId: appID,
            title: "Ada",
            subtitle: nil,
            body: body,
            sender: nil,
            threadId: nil,
            category: nil,
            deliveredAt: UnixDate(Date(timeIntervalSince1970: 1_755_421_200)),
            capturedAt: UnixDate(Date(timeIntervalSince1970: 1_755_421_200)),
            source: .live,
            presented: true,
            awaySessionId: nil,
            deepLink: nil,
            attachmentsJson: nil,
            redaction: .none,
            isRead: false,
            isPinned: false,
            isDeleted: false,
            storeRecId: nil
        )
    }
}
