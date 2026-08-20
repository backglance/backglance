@testable import BackglanceCapture
import BackglanceCore
import Foundation
import GRDB
import XCTest

/// The whole path, end to end: a store on disk, a watcher wake, and rows in the archive.
///
/// The unit tests each hold one piece still. This one holds none of them: it starts an
/// engine the way the app does, lets the watcher drive it, and checks what a person would
/// check — that everything in the store arrived, that a second run adds nothing, and that
/// a relaunch resumes rather than re-reads.
///
/// The per-macOS fixture stores under `Tests/Fixtures/SystemStore/` get their own harness
/// (`FixtureStoreTests`); this store is generated here so the pipeline can be exercised
/// before those exist, and so its contents are visible in this file.
final class CapturePipelineTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try Self.temporaryDirectory()
        storeURL = try XCTUnwrap(directory).appendingPathComponent("db")
    }

    override func tearDownWithError() throws {
        watcher?.stop()
        watcher = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        storeURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Store to archive

    func testEverythingInTheStoreReachesTheArchive() async throws {
        let storeURL = try XCTUnwrap(storeURL)
        try Self.makeStore(at: storeURL, count: 12)
        let archive = try Archive(inMemory: true)
        let engine = try makeEngine(archive: archive)

        try archive.captureFromTheStartOfTheStore()

        await engine.start()
        await engine.tick(reason: .manual)

        let stored = try await archive.pool.read { db in
            try ArchivedNotification.order(Column("store_rec_id")).fetchAll(db)
        }
        XCTAssertEqual(stored.count, 12)
        XCTAssertEqual(stored.map(\.storeRecId), Array(1 ... 12))
        XCTAssertEqual(stored.first?.title, "Ada")
        XCTAssertEqual(stored.first?.body, "Body 1")

        let cursor = await engine.currentCursor
        XCTAssertEqual(cursor.lastRecID, 12)
        XCTAssertEqual(cursor.lastDeliveredDate, MiniatureStore.delivered)
    }

    /// The app's own arrangement: nothing calls `tick` directly, the watcher does.
    func testAWatcherWakeDrivesTheWholePipeline() async throws {
        let storeURL = try XCTUnwrap(storeURL)
        try Self.makeStore(at: storeURL, count: 3)
        let archive = try Archive(inMemory: true)
        let watcher = StoreWatcher(location: storeURL, debounce: 0.01)
        self.watcher = watcher
        let engine = CaptureEngine(archive: archive, watcher: watcher) { storeURL }

        try archive.captureFromTheStartOfTheStore()

        await engine.start()
        watcher.poke()

        try await Self.waitUntil {
            let count = try? await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
            return count == 3
        }
    }

    /// A tick that finds nothing new must cost nothing. This is the common case on a Mac
    /// that is not receiving notifications: the watcher polls every fifteen seconds.
    func testASecondTickOverTheSameStoreArchivesNothingNew() async throws {
        let storeURL = try XCTUnwrap(storeURL)
        try Self.makeStore(at: storeURL, count: 5)
        let archive = try Archive(inMemory: true)
        let engine = try makeEngine(archive: archive)

        try archive.captureFromTheStartOfTheStore()

        await engine.start()
        await engine.tick(reason: .manual)
        await engine.tick(reason: .poll)

        let count = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        let read = await engine.recordsRead
        XCTAssertEqual(count, 5)
        XCTAssertEqual(read, 5, "the second tick read nothing, rather than reading and discarding")
    }

    /// A relaunch: a new engine over the same archive resumes from the persisted cursor
    /// instead of walking the store again.
    func testARelaunchResumesFromWhereTheLastRunStopped() async throws {
        let storeURL = try XCTUnwrap(storeURL)
        try Self.makeStore(at: storeURL, count: 4)
        let archive = try Archive(inMemory: true)
        let first = try makeEngine(archive: archive)
        try archive.captureFromTheStartOfTheStore()
        await first.start()
        await first.tick(reason: .manual)
        await first.stop()

        try MiniatureStore.append(
            (5 ... 6).map { MiniatureStore.notification(recID: Int64($0), body: "Body \($0)") },
            to: storeURL
        )
        let second = try makeEngine(archive: archive)
        await second.start()
        await second.tick(reason: .manual)

        let count = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        let read = await second.recordsRead
        XCTAssertEqual(count, 6)
        XCTAssertEqual(read, 2, "the relaunched engine read only what arrived while it was gone")
    }

    /// Import then live, the way onboarding runs them. The overlap is absorbed rather
    /// than duplicated.
    func testImportFollowedByLiveCaptureLeavesOneRowPerNotification() async throws {
        let storeURL = try XCTUnwrap(storeURL)
        try Self.makeStore(at: storeURL, count: 6)
        let archive = try Archive(inMemory: true)
        let engine = try makeEngine(archive: archive)
        try archive.captureFromTheStartOfTheStore()
        await engine.start()

        let summary = try await engine.importExisting()
        try MiniatureStore.append([MiniatureStore.notification(recID: 7, body: "Body 7")], to: storeURL)
        await engine.tick(reason: .fileChanged)

        let stored = try await archive.pool.read { db in try ArchivedNotification.fetchAll(db) }
        XCTAssertEqual(summary.archived, 6)
        XCTAssertEqual(stored.count, 7)
        XCTAssertEqual(stored.filter { $0.source == .imports }.count, 6)
        XCTAssertEqual(stored.filter { $0.source == .live }.count, 1)
    }

    /// The archive's own bookkeeping, which Settings ▸ Apps reads.
    func testTheOwningAppsCountsMatchWhatWasArchived() async throws {
        let storeURL = try XCTUnwrap(storeURL)
        try MiniatureStore.makeFile(at: storeURL, rows: [
            MiniatureStore.notification(recID: 1, bundleID: "com.example.chat"),
            MiniatureStore.notification(recID: 2, bundleID: "com.example.chat"),
            MiniatureStore.notification(recID: 3, bundleID: "com.example.ci"),
        ])
        let archive = try Archive(inMemory: true)
        let engine = try makeEngine(archive: archive)

        try archive.captureFromTheStartOfTheStore()

        await engine.start()
        await engine.tick(reason: .manual)

        let apps = try await archive.pool.read { db in try AppRecord.order(Column("bundle_id")).fetchAll(db) }
        XCTAssertEqual(apps.map(\.bundleId), ["com.example.chat", "com.example.ci"])
        XCTAssertEqual(apps.map(\.notificationCount), [2, 1])
    }

    // MARK: Private

    private var watcher: StoreWatcher?
    private var directory: URL?
    private var storeURL: URL?

    private static func makeStore(at url: URL, count: Int) throws {
        let rows = (1 ... count).map { MiniatureStore.notification(recID: Int64($0), body: "Body \($0)") }
        try MiniatureStore.makeFile(at: url, rows: rows)
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CapturePipelineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
    }

    private func makeEngine(archive: Archive) throws -> CaptureEngine {
        let directory = try XCTUnwrap(directory)
        let storeURL = try XCTUnwrap(storeURL)
        // A watcher on a path nothing writes: these tests drive `tick` themselves, except
        // the one that deliberately does not.
        let watcher = StoreWatcher(location: directory.appendingPathComponent("unused"), debounce: 0.01)
        self.watcher = watcher
        return CaptureEngine(archive: archive, watcher: watcher) { storeURL }
    }
}
