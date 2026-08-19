@testable import BackglanceCapture
import BackglanceCore
import Foundation
import XCTest

// MARK: - CaptureEnginePipelineTests

/// What happens to one store record on its way into the archive. The order of the stages
/// is the privacy model — exclusion before the payload is decoded, redaction before
/// anything is written — so most of these tests are about ordering rather than output.
final class CaptureEnginePipelineTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        let archive = try Archive(inMemory: true)
        let directory = try Self.temporaryDirectory()

        self.archive = archive
        self.directory = directory
        storeURL = directory.appendingPathComponent("db")
    }

    override func tearDownWithError() throws {
        watcher?.stop()
        watcher = nil
        archive = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Archiving

    func testAWellFormedRecordBecomesAnArchiveRow() async throws {
        let archive = try XCTUnwrap(archive)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [
            MiniatureStore.notification(recID: 1, bundleID: "com.example.chat", title: "Ada", body: "Landing at six"),
        ])
        let engine = try makeEngine()

        await engine.start()
        await engine.tick(reason: .manual)

        let fetched = try await archive.pool.read { db in try ArchivedNotification.fetchOne(db) }
        let stored = try XCTUnwrap(fetched)
        XCTAssertEqual(stored.title, "Ada")
        XCTAssertEqual(stored.body, "Landing at six")
        XCTAssertEqual(stored.storeRecId, 1)
        XCTAssertEqual(stored.source, .live)
        XCTAssertEqual(stored.deliveredAt.date, MiniatureStore.delivered)

        let archived = await engine.recordsArchived
        XCTAssertEqual(archived, 1)
    }

    func testAttachmentMetadataIsStoredAsJSON() async throws {
        let archive = try XCTUnwrap(archive)
        var row = MiniatureStore.Row(recID: 1)
        row.payload = MiniatureStore.payload(
            title: "Photo",
            body: nil,
            attachments: [["type": "public.jpeg", "name": "sunset.jpg", "size": 2_048]]
        )
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [row])
        let engine = try makeEngine()

        await engine.start()
        await engine.tick(reason: .manual)

        let fetched = try await archive.pool.read { db in try ArchivedNotification.fetchOne(db) }
        let stored = try XCTUnwrap(fetched)
        let json = try XCTUnwrap(stored.attachmentsJson)
        let decoded = try JSONDecoder().decode([AttachmentMeta].self, from: Data(json.utf8))
        XCTAssertEqual(decoded, [AttachmentMeta(type: "public.jpeg", name: "sunset.jpg", size: 2_048)])
    }

    /// One bad record must never cost the batch. The store contains rows that are not
    /// notifications, and a tick that gave up on the first would stall capture forever.
    func testARecordThatWillNotParseDoesNotStopTheBatch() async throws {
        let archive = try XCTUnwrap(archive)
        var corrupt = MiniatureStore.Row(recID: 2)
        corrupt.payload = Data("not a property list".utf8)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [
            MiniatureStore.notification(recID: 1),
            corrupt,
            MiniatureStore.notification(recID: 3),
        ])
        let engine = try makeEngine()

        await engine.start()
        await engine.tick(reason: .manual)

        let count = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        let cursor = await engine.currentCursor
        XCTAssertEqual(count, 2)
        XCTAssertEqual(cursor.lastRecID, 3, "the cursor must move past a record that will not parse")
    }

    /// The import and live capture overlap by design; matching on `store_rec_id` is what
    /// makes the overlap cost nothing.
    func testARowLiveCaptureAlreadyArchivedIsADuplicateForTheImport() async throws {
        let archive = try XCTUnwrap(archive)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [
            MiniatureStore.notification(recID: 1),
            MiniatureStore.notification(recID: 2),
        ])
        let engine = try makeEngine()
        await engine.start()
        await engine.tick(reason: .manual)

        let summary = try await engine.importExisting()

        let count = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(summary.archived, 0)
        XCTAssertEqual(summary.duplicates, 2)
    }

    /// The store rewrites rows in place: Messages replaces a conversation's banner under
    /// a new rec_id but the same uuid. That is one notification, refreshed — not two.
    func testAThreadUpdateRefreshesTheRowRatherThanAddingOne() async throws {
        let archive = try XCTUnwrap(archive)
        let storeURL = try XCTUnwrap(storeURL)
        let uuid = Data(UUID().rawBytes)
        var first = MiniatureStore.notification(recID: 1, body: "One message")
        first.uuidBlob = uuid
        var rewritten = MiniatureStore.notification(recID: 2, body: "Two messages")
        rewritten.uuidBlob = uuid
        try MiniatureStore.makeFile(at: storeURL, rows: [first, rewritten])
        let engine = try makeEngine()

        await engine.start()
        await engine.tick(reason: .manual)

        let stored = try await archive.pool.read { db in try ArchivedNotification.fetchAll(db) }
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.body, "Two messages")
        XCTAssertEqual(stored.first?.storeRecId, 2)
    }

    // MARK: - Exclusion

    /// 🔒 The invariant: exclusion runs on the store row, before the payload is decoded.
    /// The payload here names an app that *is* allowed — so if the check ran after the
    /// parse, this notification would be archived.
    func testAnExcludedAppsPayloadIsNeverDecoded() async throws {
        let archive = try XCTUnwrap(archive)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [
            MiniatureStore.notification(
                recID: 1,
                bundleID: "com.example.passwords",
                payloadBundleID: "com.example.chat"
            ),
        ])
        let exclusions = DenyList(["com.example.passwords"])
        let engine = try makeEngine(exclusions: exclusions)

        await engine.start()
        await engine.tick(reason: .manual)

        let count = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(exclusions.asked.first, "com.example.passwords")
    }

    /// Helper processes and iPhone Mirroring post on behalf of another bundle, so the
    /// payload's own app has to be checked too — that is the app the user excluded.
    func testAnAppExcludedByThePayloadsOwnBundleIDIsAlsoSkipped() async throws {
        let archive = try XCTUnwrap(archive)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [
            MiniatureStore.notification(
                recID: 1,
                bundleID: "com.apple.iphonemirroring",
                payloadBundleID: "com.example.passwords"
            ),
        ])
        let engine = try makeEngine(exclusions: DenyList(["com.example.passwords"]))

        await engine.start()
        await engine.tick(reason: .manual)

        let count = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        XCTAssertEqual(count, 0)
    }

    // MARK: - Redaction and enrichment

    /// 🔒 What reaches the archive is what the redactor returned, and the audit row lands
    /// in the same transaction.
    func testWhatIsArchivedIsWhatTheRedactorReturned() async throws {
        let archive = try XCTUnwrap(archive)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [
            MiniatureStore.notification(recID: 1, title: "Bank", body: "Your code is 449021"),
        ])
        let engine = try makeEngine(redactor: StubRedactor())

        await engine.start()
        await engine.tick(reason: .manual)

        let fetched = try await archive.pool.read { db in try ArchivedNotification.fetchOne(db) }
        let stored = try XCTUnwrap(fetched)
        let redactions = try await archive.pool.read { db in try RedactionEvent.fetchAll(db) }
        XCTAssertEqual(stored.body, "[code redacted]")
        XCTAssertEqual(redactions.count, 1)
        XCTAssertEqual(redactions.first?.patternId, "stub.pattern")
        XCTAssertEqual(redactions.first?.notificationId, stored.id)
    }

    func testEnrichmentRunsBeforeTheInsert() async throws {
        let archive = try XCTUnwrap(archive)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [MiniatureStore.notification(recID: 1)])
        let engine = try makeEngine(enrichment: StubEnricher())

        await engine.start()
        await engine.tick(reason: .manual)

        let fetched = try await archive.pool.read { db in try ArchivedNotification.fetchOne(db) }
        let stored = try XCTUnwrap(fetched)
        XCTAssertEqual(stored.deepLink, "messages://open?id=9")
    }

    func testTheOwningAppRowIsCreatedOnceForABatch() async throws {
        let archive = try XCTUnwrap(archive)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [
            MiniatureStore.notification(recID: 1, bundleID: "com.example.chat"),
            MiniatureStore.notification(recID: 2, bundleID: "com.example.chat"),
        ])
        let engine = try makeEngine()

        await engine.start()
        await engine.tick(reason: .manual)

        let apps = try await archive.pool.read { db in try AppRecord.fetchAll(db) }
        XCTAssertEqual(apps.map(\.bundleId), ["com.example.chat"])
    }

    // MARK: Private

    private var archive: Archive?
    private var watcher: StoreWatcher?
    private var directory: URL?
    private var storeURL: URL?

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureEnginePipelineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeEngine(
        exclusions: any AppExclusionList = AllowAllApps(),
        redactor: any NotificationRedactor = NoRedaction(),
        enrichment: any NotificationEnricher = NoEnrichment()
    ) throws -> CaptureEngine {
        let directory = try XCTUnwrap(directory)
        let storeURL = try XCTUnwrap(storeURL)
        let watcher = StoreWatcher(location: directory.appendingPathComponent("unused"), debounce: 0.01)
        self.watcher = watcher

        return try CaptureEngine(
            archive: XCTUnwrap(archive),
            watcher: watcher,
            exclusions: exclusions,
            redactor: redactor,
            enrichment: enrichment
        ) { storeURL }
    }
}

// MARK: - DenyList

/// An exclusion list that remembers what it was asked about, so a test can prove *when*
/// the question was put.
private final class DenyList: AppExclusionList, @unchecked Sendable {
    // MARK: Lifecycle

    init(_ excluded: Set<String>) {
        self.excluded = excluded
    }

    // MARK: Internal

    private(set) var asked: [String] = []

    func allows(_ bundleID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        asked.append(bundleID)
        return !excluded.contains(bundleID)
    }

    // MARK: Private

    private let excluded: Set<String>
    private let lock = NSLock()
}

// MARK: - StubRedactor

/// Stands in for `OTPRedactor` until the privacy milestone.
private struct StubRedactor: NotificationRedactor {
    func redact(_ notification: ParsedNotification) -> (ParsedNotification, RedactionEvent?) {
        var redacted = notification
        redacted.body = "[code redacted]"
        let event = RedactionEvent(patternId: "stub.pattern", redactedAt: UnixDate(Date()))
        return (redacted, event)
    }
}

// MARK: - StubEnricher

private struct StubEnricher: NotificationEnricher {
    func enrich(_ notification: ParsedNotification) async -> ParsedNotification {
        var enriched = notification
        enriched.deepLink = URL(string: "messages://open?id=9")
        return enriched
    }
}
