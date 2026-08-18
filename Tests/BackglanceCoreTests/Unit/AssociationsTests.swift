@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

/// Covers `AwaySession`, `Digest`, `DigestItem`, `RedactionEvent`, and
/// `Rule` — in particular that every property and association maps onto the
/// real `ArchiveMigrations` schema, and that the `ArchivedNotification`
/// associations deferred from BACKGLANCE-34 (`awaySession`, `redactions`)
/// are wired correctly now that their target types exist.
///
/// The cascade / `SET NULL` tests need foreign keys enforced, which is
/// `Archive`'s configuration (`PRAGMA foreign_keys = ON`), not a bare
/// `DatabaseQueue()` — hence `Archive(inMemory: true)` throughout rather
/// than the raw `DatabaseQueue` used by `ModelsTests`.
///
/// Timestamps here are fixed, whole-second `UnixDate`s rather than `.now`
/// (see `ModelsTests`, which does the same). `.now` wraps `Date()`, whose
/// sub-microsecond fractional seconds do not always survive the round trip
/// through `timeIntervalSince1970` → SQLite `REAL` → `timeIntervalSince1970`
/// intact — adding and subtracting the ~978,307,200-second Cocoa/Unix epoch
/// offset can round the last bit or two of precision away. That is a
/// property of `Foundation.Date` arithmetic, not a bug in these models, but
/// it makes `.now` a flaky choice whenever a test asserts exact struct
/// equality after a fetch.
final class AssociationsTests: XCTestCase {
    // MARK: Internal

    // MARK: - AwaySession round trip

    func testAwaySessionRoundTripsThroughTheRealSchema() throws {
        let archive = try Archive(inMemory: true)
        let startedAt = UnixDate(Date(timeIntervalSince1970: 1_755_600_000))

        var session = AwaySession(startedAt: startedAt, endedAt: nil, reason: .locked)
        XCTAssertNil(session.id)
        try archive.pool.write { db in try session.insert(db) }
        XCTAssertNotNil(session.id, "didInsert should have captured the rowID")

        let fetched = try archive.pool.read { db in try AwaySession.fetchOne(db, key: session.id) }
        XCTAssertEqual(fetched, session)
        XCTAssertEqual(fetched?.reason, .locked)
    }

    func testAwaySessionIsOpenTracksEndedAt() {
        let startedAt = UnixDate(Date(timeIntervalSince1970: 1_755_600_100))
        var session = AwaySession(startedAt: startedAt, endedAt: nil, reason: .asleep)
        XCTAssertTrue(session.isOpen)

        session.endedAt = UnixDate(Date(timeIntervalSince1970: 1_755_600_200))
        XCTAssertFalse(session.isOpen)
    }

    // MARK: - Digest + DigestItem round trip and associations

    func testDigestRoundTripsAndFetchesItsAwaySessionAndItems() throws {
        let archive = try Archive(inMemory: true)
        let appID = try insertApp(archive)
        let sessionID = try insertAwaySession(archive)
        let notificationID = try insertNotification(archive, appId: appID, awaySessionId: sessionID)

        var digest = Digest(
            awaySessionId: sessionID,
            createdAt: fixedDate(1_755_700_000),
            shownAt: nil,
            dismissedAt: nil,
            itemCount: 1
        )
        XCTAssertNil(digest.id)
        try archive.pool.write { db in try digest.insert(db) }
        XCTAssertNotNil(digest.id, "didInsert should have captured the rowID")

        var item = try DigestItem(digestId: XCTUnwrap(digest.id), notificationId: notificationID, rank: 0)
        try archive.pool.write { db in try item.insert(db) }

        let fetchedDigest = try archive.pool.read { db in try Digest.fetchOne(db, key: digest.id) }
        XCTAssertEqual(fetchedDigest, digest)

        let fetchedSession = try archive.pool.read { db in
            try digest.request(for: Digest.awaySession).fetchOne(db)
        }
        XCTAssertEqual(fetchedSession?.id, sessionID)

        let fetchedItems = try archive.pool.read { db in
            try digest.request(for: Digest.items).fetchAll(db)
        }
        XCTAssertEqual(fetchedItems, [item])
    }

    func testDigestItemCompositePrimaryKeyRejectsDuplicate() throws {
        let archive = try Archive(inMemory: true)
        let appID = try insertApp(archive)
        let sessionID = try insertAwaySession(archive)
        let notificationID = try insertNotification(archive, appId: appID, awaySessionId: sessionID)
        let digestID = try insertDigest(archive, awaySessionId: sessionID)

        var first = DigestItem(digestId: digestID, notificationId: notificationID, rank: 0)
        try archive.pool.write { db in try first.insert(db) }

        var duplicate = DigestItem(digestId: digestID, notificationId: notificationID, rank: 1)
        XCTAssertThrowsError(try archive.pool.write { db in try duplicate.insert(db) }) { error in
            XCTAssertTrue(error is DatabaseError, "expected a primary-key violation, got \(error)")
        }
    }

    // MARK: - RedactionEvent round trip

    func testRedactionEventRoundTripsThroughTheRealSchema() throws {
        let archive = try Archive(inMemory: true)
        let appID = try insertApp(archive)
        let notificationID = try insertNotification(archive, appId: appID, awaySessionId: nil)

        var event = RedactionEvent(
            notificationId: notificationID,
            kind: .otp,
            patternId: "otp.keyword.en",
            redactedAt: fixedDate(1_755_800_000)
        )
        XCTAssertNil(event.id)
        try archive.pool.write { db in try event.insert(db) }
        XCTAssertNotNil(event.id, "didInsert should have captured the rowID")

        let fetched = try archive.pool.read { db in try RedactionEvent.fetchOne(db, key: event.id) }
        XCTAssertEqual(fetched, event)
        XCTAssertEqual(fetched?.kind, .otp)
        XCTAssertEqual(fetched?.patternId, "otp.keyword.en")
    }

    // MARK: - Rule round trip

    func testRuleRoundTripsThroughTheRealSchema() throws {
        let archive = try Archive(inMemory: true)

        var rule = Rule(
            kind: .highlight,
            pattern: "invoice",
            matchField: .body,
            appBundleId: "com.apple.mail",
            color: "amber",
            priority: 5,
            isEnabled: true,
            createdAt: fixedDate(1_755_900_000)
        )
        XCTAssertNil(rule.id)
        try archive.pool.write { db in try rule.insert(db) }
        XCTAssertNotNil(rule.id, "didInsert should have captured the rowID")

        let fetched = try archive.pool.read { db in try Rule.fetchOne(db, key: rule.id) }
        XCTAssertEqual(fetched, rule)
        XCTAssertEqual(fetched?.kind, .highlight)
        XCTAssertEqual(fetched?.matchField, .body)
    }

    // MARK: - ArchivedNotification's newly wired associations

    func testArchivedNotificationFetchesItsAwaySessionAndRedactions() throws {
        let archive = try Archive(inMemory: true)
        let appID = try insertApp(archive)
        let sessionID = try insertAwaySession(archive)
        let notificationID = try insertNotification(archive, appId: appID, awaySessionId: sessionID)

        var redaction = RedactionEvent(
            notificationId: notificationID,
            kind: .otp,
            patternId: "otp.body-only",
            redactedAt: fixedDate(1_756_000_000)
        )
        try archive.pool.write { db in try redaction.insert(db) }

        let notification = try archive.pool.read { db in
            try ArchivedNotification.fetchOne(db, key: notificationID)
        }
        let notificationRow = try XCTUnwrap(notification)

        let fetchedSession = try archive.pool.read { db in
            try notificationRow.request(for: ArchivedNotification.awaySession).fetchOne(db)
        }
        XCTAssertEqual(fetchedSession?.id, sessionID)

        let fetchedRedactions = try archive.pool.read { db in
            try notificationRow.request(for: ArchivedNotification.redactions).fetchAll(db)
        }
        XCTAssertEqual(fetchedRedactions, [redaction])
    }

    // MARK: - Cascade / SET NULL behavior

    func testDeletingAwaySessionSetsNotificationsAwaySessionIdToNull() throws {
        let archive = try Archive(inMemory: true)
        let appID = try insertApp(archive)
        let sessionID = try insertAwaySession(archive)
        let notificationID = try insertNotification(archive, appId: appID, awaySessionId: sessionID)

        try archive.pool.write { db in
            _ = try AwaySession.deleteOne(db, key: sessionID)
        }

        let survivor = try archive.pool.read { db in
            try ArchivedNotification.fetchOne(db, key: notificationID)
        }
        XCTAssertNotNil(survivor, "deleting the away session must not delete the notification")
        XCTAssertNil(survivor?.awaySessionId, "away_session_id must be set to NULL, not left dangling")
    }

    func testDeletingDigestCascadesToItsDigestItems() throws {
        let archive = try Archive(inMemory: true)
        let appID = try insertApp(archive)
        let sessionID = try insertAwaySession(archive)
        let notificationID = try insertNotification(archive, appId: appID, awaySessionId: sessionID)
        let digestID = try insertDigest(archive, awaySessionId: sessionID)

        var item = DigestItem(digestId: digestID, notificationId: notificationID, rank: 0)
        try archive.pool.write { db in try item.insert(db) }

        try archive.pool.write { db in
            _ = try Digest.deleteOne(db, key: digestID)
        }

        let remainingItems = try archive.pool.read { db in
            try DigestItem.filter(Column("digest_id") == digestID).fetchAll(db)
        }
        XCTAssertTrue(remainingItems.isEmpty, "deleting a digest must cascade to its digest_items")
    }

    func testDeletingNotificationCascadesToItsRedactionEvents() throws {
        let archive = try Archive(inMemory: true)
        let appID = try insertApp(archive)
        let notificationID = try insertNotification(archive, appId: appID, awaySessionId: nil)

        var event = RedactionEvent(
            notificationId: notificationID,
            kind: .otp,
            patternId: "otp.keyword.en",
            redactedAt: fixedDate(1_756_100_000)
        )
        try archive.pool.write { db in try event.insert(db) }

        try archive.pool.write { db in
            _ = try ArchivedNotification.deleteOne(db, key: notificationID)
        }

        let remainingEvents = try archive.pool.read { db in
            try RedactionEvent.filter(Column("notification_id") == notificationID).fetchAll(db)
        }
        XCTAssertTrue(remainingEvents.isEmpty, "deleting a notification must cascade to its redactions")
    }

    // MARK: Private

    /// A whole-second `UnixDate`, used instead of `.now` wherever a test
    /// asserts exact equality after a round trip through the archive — see
    /// the type-level doc comment for why `.now` is unsafe there. Each call
    /// site passes a distinct epoch so unrelated timestamps in the same
    /// test are never accidentally equal.
    private func fixedDate(_ epochSeconds: TimeInterval) -> UnixDate {
        UnixDate(Date(timeIntervalSince1970: epochSeconds))
    }

    @discardableResult
    private func insertApp(_ archive: Archive, bundleId: String = "com.example.app") throws -> Int64 {
        let seenAt = fixedDate(1_755_000_000)
        var app = AppRecord(bundleId: bundleId, firstSeenAt: seenAt, lastSeenAt: seenAt)
        try archive.pool.write { db in try app.insert(db) }
        return try XCTUnwrap(app.id)
    }

    @discardableResult
    private func insertAwaySession(
        _ archive: Archive,
        startedAt: UnixDate? = nil,
        reason: AwaySession.Reason = .locked
    ) throws -> Int64 {
        var session = AwaySession(startedAt: startedAt ?? fixedDate(1_755_500_000), endedAt: nil, reason: reason)
        try archive.pool.write { db in try session.insert(db) }
        return try XCTUnwrap(session.id)
    }

    @discardableResult
    private func insertNotification(_ archive: Archive, appId: Int64, awaySessionId: Int64?) throws -> Int64 {
        var notification = ArchivedNotification(
            uuid: UUID().uuidString,
            appId: appId,
            deliveredAt: fixedDate(1_755_650_000),
            capturedAt: fixedDate(1_755_650_001),
            awaySessionId: awaySessionId
        )
        try archive.pool.write { db in try notification.insert(db) }
        return try XCTUnwrap(notification.id)
    }

    @discardableResult
    private func insertDigest(_ archive: Archive, awaySessionId: Int64) throws -> Int64 {
        var digest = Digest(
            awaySessionId: awaySessionId,
            createdAt: fixedDate(1_755_750_000),
            shownAt: nil,
            dismissedAt: nil,
            itemCount: 0
        )
        try archive.pool.write { db in try digest.insert(db) }
        return try XCTUnwrap(digest.id)
    }
}
