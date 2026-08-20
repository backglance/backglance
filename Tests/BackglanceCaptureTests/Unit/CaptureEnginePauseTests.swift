@testable import BackglanceCapture
import BackglanceCore
import Foundation
import XCTest

/// Pause is a promise: nothing delivered while paused is archived. The system keeps
/// delivering and the store keeps growing regardless, so keeping that promise is entirely
/// about what capture reads afterwards — which is what these tests are about.
final class CaptureEnginePauseTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        let archive = try Archive(inMemory: true)
        let directory = try Self.temporaryDirectory()
        let storeURL = directory.appendingPathComponent("db")
        let watcher = StoreWatcher(location: directory.appendingPathComponent("unused"), debounce: 0.01)

        self.archive = archive
        self.directory = directory
        self.storeURL = storeURL
        self.watcher = watcher
        engine = CaptureEngine(archive: archive, watcher: watcher) { storeURL }
    }

    override func tearDownWithError() throws {
        watcher?.stop()
        watcher = nil
        engine = nil
        archive = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Pausing

    func testPausingReportsWhenItWillResume() async throws {
        let engine = try XCTUnwrap(engine)
        let until = Date().addingTimeInterval(1_800)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [MiniatureStore.notification(recID: 1)])
        await engine.start()

        await engine.pause(until: until)

        let status = await engine.status
        XCTAssertEqual(status, .paused(until: until))
    }

    func testPausingIndefinitelyHasNoEndTime() async throws {
        let engine = try XCTUnwrap(engine)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [MiniatureStore.notification(recID: 1)])
        await engine.start()

        await engine.pause()

        let status = await engine.status
        XCTAssertEqual(status, .paused(until: nil))
    }

    /// The watcher keeps running while paused — it costs nothing and makes resume
    /// instant — so the guard that actually stops archiving is in the tick.
    func testAWakeWhilePausedArchivesNothing() async throws {
        let engine = try XCTUnwrap(engine)
        let archive = try XCTUnwrap(archive)
        let storeURL = try XCTUnwrap(storeURL)
        try MiniatureStore.makeFile(at: storeURL, rows: [MiniatureStore.notification(recID: 1)])
        try archive.captureFromTheStartOfTheStore()
        await engine.start()
        await engine.pause()

        try MiniatureStore.append([MiniatureStore.notification(recID: 2)], to: storeURL)
        await engine.tick(reason: .fileChanged)

        let count = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        let cursor = await engine.currentCursor
        XCTAssertEqual(count, 0)
        XCTAssertEqual(cursor, .start, "the cursor is frozen while paused")
    }

    // MARK: - Resuming

    /// 🔒 The promise. Everything delivered during the pause is skipped for good, rather
    /// than arriving all at once days later.
    func testResumingSkipsEverythingThatArrivedWhilePaused() async throws {
        let engine = try XCTUnwrap(engine)
        let archive = try XCTUnwrap(archive)
        let storeURL = try XCTUnwrap(storeURL)
        try MiniatureStore.makeFile(at: storeURL, rows: [MiniatureStore.notification(recID: 1)])
        try archive.captureFromTheStartOfTheStore()
        await engine.start()
        await engine.tick(reason: .manual)
        await engine.pause()

        try MiniatureStore.append((2 ... 5).map { MiniatureStore.notification(recID: Int64($0)) }, to: storeURL)
        await engine.resume()
        await engine.tick(reason: .manual)

        let count = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        let cursor = await engine.currentCursor
        XCTAssertEqual(count, 1, "only the notification from before the pause")
        XCTAssertEqual(cursor.lastRecID, 5, "the cursor jumped the pause rather than reading it")
    }

    /// The fast-forward is persisted, so a relaunch during the pause cannot resurrect
    /// what the pause excluded.
    func testTheFastForwardedCursorIsPersisted() async throws {
        let engine = try XCTUnwrap(engine)
        let archive = try XCTUnwrap(archive)
        let storeURL = try XCTUnwrap(storeURL)
        try MiniatureStore.makeFile(at: storeURL, rows: [MiniatureStore.notification(recID: 1)])
        await engine.start()
        await engine.pause()

        try MiniatureStore.append([MiniatureStore.notification(recID: 2)], to: storeURL)
        await engine.resume()

        try XCTAssertEqual(archive.loadCursor()?.lastRecID, 2)
    }

    func testResumingRunsAgain() async throws {
        let engine = try XCTUnwrap(engine)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [MiniatureStore.notification(recID: 1)])
        await engine.start()
        await engine.pause()

        await engine.resume()

        let status = await engine.status
        XCTAssertEqual(status, .running)
    }

    /// Paused before the store was ever readable: resume has nothing to fast-forward and
    /// has to bootstrap instead, which ends in running or in a reason.
    func testResumingWithoutAnAdapterBootstraps() async throws {
        let engine = try XCTUnwrap(engine)
        let storeURL = try XCTUnwrap(storeURL)
        await engine.start()
        await engine.pause()

        try MiniatureStore.makeFile(at: storeURL, rows: [MiniatureStore.notification(recID: 1)])
        await engine.resume()

        let status = await engine.status
        XCTAssertEqual(status, .running)
    }

    // MARK: - Automatic resume

    func testAPauseWithAnEndTimeResumesByItself() async throws {
        let engine = try XCTUnwrap(engine)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [MiniatureStore.notification(recID: 1)])
        await engine.start()

        await engine.pause(until: Date().addingTimeInterval(0.05))

        try await Self.waitUntil { await engine.status == .running }
    }

    /// A stale timer must not resume capture minutes after the user stopped it.
    func testStoppingCancelsAPendingAutomaticResume() async throws {
        let engine = try XCTUnwrap(engine)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [MiniatureStore.notification(recID: 1)])
        await engine.start()
        await engine.pause(until: Date().addingTimeInterval(0.05))

        await engine.stop()
        try await Task.sleep(for: .milliseconds(150))

        let status = await engine.status
        XCTAssertEqual(status, .stopped)
    }

    /// Pausing again replaces the pending resume rather than leaving two racing.
    func testPausingAgainReplacesThePendingResume() async throws {
        let engine = try XCTUnwrap(engine)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [MiniatureStore.notification(recID: 1)])
        await engine.start()
        await engine.pause(until: Date().addingTimeInterval(0.05))

        await engine.pause()
        try await Task.sleep(for: .milliseconds(150))

        let status = await engine.status
        XCTAssertEqual(status, .paused(until: nil))
    }

    // MARK: Private

    private var archive: Archive?
    private var watcher: StoreWatcher?
    private var engine: CaptureEngine?
    private var directory: URL?
    private var storeURL: URL?

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureEnginePauseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
    }
}
