@testable import BackglanceCapture
import BackglanceCore
import Foundation
import XCTest

// MARK: - CaptureEngineTests

/// The engine's skeleton: one loop, one consumer of the wake stream, and a status other
/// parts of the app can watch. The reading and archiving arrive in the tasks that follow;
/// what is pinned here is the wiring, because a loop that quietly stops consuming wakes
/// looks exactly like a Mac that stopped receiving notifications.
final class CaptureEngineTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        let archive = try Archive(inMemory: true)
        let directory = try Self.temporaryDirectory()
        let watcher = StoreWatcher(location: directory.appendingPathComponent("db"), debounce: 0.01)

        self.archive = archive
        self.directory = directory
        self.watcher = watcher
        storeURL = directory.appendingPathComponent("db")
        engine = Self.makeEngine(archive: archive, watcher: watcher, storeURL: directory.appendingPathComponent("db"))
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

    func testANewEngineIsStopped() async throws {
        let engine = try XCTUnwrap(engine)

        let status = await engine.status
        let lastWake = await engine.lastWake

        XCTAssertEqual(status, .stopped)
        XCTAssertNil(lastWake)
    }

    /// The loop consumes the watcher's stream, and a second consumer would take half the
    /// wakes with it. Starting twice must not create one.
    func testStartingTwiceDoesNotCreateASecondLoop() async throws {
        let engine = try XCTUnwrap(engine)
        let watcher = try XCTUnwrap(watcher)

        await engine.start()
        await engine.start()
        watcher.poke()

        try await Self.waitUntil { await engine.lastWake == .manual }
    }

    func testTheLoopForwardsEveryWakeToTheEngine() async throws {
        let engine = try XCTUnwrap(engine)
        let watcher = try XCTUnwrap(watcher)

        await engine.start()
        watcher.poke()

        try await Self.waitUntil { await engine.lastWake == .manual }
    }

    /// Stopping is what the user gets when they quit or toggle capture off, so it has to
    /// leave the engine restartable rather than spent.
    func testStoppingEndsTheLoopAndCanBeFollowedByAnotherStart() async throws {
        let engine = try XCTUnwrap(engine)
        let watcher = try XCTUnwrap(watcher)

        await engine.start()
        watcher.poke()
        try await Self.waitUntil { await engine.lastWake == .manual }
        await engine.stop()

        let stoppedStatus = await engine.status
        XCTAssertEqual(stoppedStatus, .stopped)

        await engine.start()
        watcher.poke()
        try await Self.waitUntil { await engine.lastWake == .manual }
    }

    // MARK: - Bootstrap

    /// The ordinary case: a store that reads, an adapter that probes clean, and the
    /// bookkeeping a later run resumes from.
    func testStartingOnAReadableStoreRunsAndRecordsWhatItResolved() async throws {
        let engine = try XCTUnwrap(engine)
        let archive = try XCTUnwrap(archive)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: MiniatureStore.rows(3))

        await engine.start()

        let status = await engine.status
        let adapterID = await engine.adapterID
        XCTAssertEqual(status, .running)
        XCTAssertEqual(adapterID, Self.adapterForThisMac)
        try XCTAssertEqual(archive.adapterID(), Self.adapterForThisMac)
        try XCTAssertNotNil(archive.loadFingerprint())
    }

    /// A fresh user account, where `usernoted` has not created its database yet. The
    /// engine says so and stays alive rather than failing to launch.
    func testAMissingStoreDegradesRatherThanThrowing() async throws {
        let engine = try XCTUnwrap(engine)

        await engine.start()

        let status = await engine.status
        XCTAssertEqual(status, .degraded(.storeNotFound))
    }

    /// The macOS-changed-the-store case. Capture stops; the archive is untouched.
    func testAStoreNoAdapterUnderstandsDegradesWithItsFingerprint() async throws {
        let engine = try XCTUnwrap(engine)
        let archive = try XCTUnwrap(archive)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), droppingTables: ["record", "app"])

        await engine.start()

        let status = await engine.status
        let adapterID = await engine.adapterID
        guard case let .degraded(.unknownSchema(fingerprint)) = status else {
            return XCTFail("expected .unknownSchema, got \(status.logDescription)")
        }
        XCTAssertNil(adapterID)
        // Recorded even though nothing could read it: it is what a report needs to turn
        // into the adapter that would.
        try XCTAssertEqual(archive.loadFingerprint(), fingerprint)
    }

    /// Resumable state. A cursor from a previous run is where the next tick starts.
    func testBootstrapResumesFromThePersistedCursor() async throws {
        let engine = try XCTUnwrap(engine)
        let archive = try XCTUnwrap(archive)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: MiniatureStore.rows(3))
        try archive.saveCursor(StoreCursor(lastRecID: 2, lastDeliveredDate: MiniatureStore.delivered))

        await engine.start()

        let cursor = await engine.currentCursor
        XCTAssertEqual(cursor.lastRecID, 2)
    }

    func testAFirstLaunchStartsFromTheBeginningOfTheStore() async throws {
        let engine = try XCTUnwrap(engine)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: MiniatureStore.rows(1))

        await engine.start()

        let cursor = await engine.currentCursor
        XCTAssertEqual(cursor, .start)
    }

    // MARK: - Status

    func testEveryTransitionReachesTheStatusStream() async throws {
        let engine = try XCTUnwrap(engine)
        let observed = Task {
            var seen: [CaptureStatus] = []
            for await status in engine.statusStream {
                seen.append(status)
                if seen.count == 2 {
                    return seen
                }
            }
            return seen
        }

        await engine.transition(to: .running)
        await engine.transition(to: .degraded(.noFullDiskAccess))

        let seen = await observed.value
        XCTAssertEqual(seen, [.running, .degraded(.noFullDiskAccess)])
    }

    /// The engine sets `.running` after every successful bootstrap, and a banner that
    /// redrew on each of those would flicker for no reason.
    func testARepeatedStatusIsNotYielded() async throws {
        let engine = try XCTUnwrap(engine)
        let observed = Task {
            var seen: [CaptureStatus] = []
            for await status in engine.statusStream {
                seen.append(status)
                if seen.count == 2 {
                    return seen
                }
            }
            return seen
        }

        await engine.transition(to: .running)
        await engine.transition(to: .running)
        await engine.transition(to: .stopped)

        let seen = await observed.value
        XCTAssertEqual(seen, [.running, .stopped])
    }

    // MARK: Private

    /// Which adapter this Mac's macOS resolves to. Asserting "v26" outright would fail
    /// on a macOS 14 runner for the right reason and the wrong test.
    private static var adapterForThisMac: String? {
        let fingerprint = StoreFingerprint(
            schemaHash: String(repeating: "0", count: 64),
            dbinfoVersion: nil,
            osVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
        return StoreAdapterRegistry.resolve(fingerprint: fingerprint)?.adapterID
    }

    private var archive: Archive?
    private var watcher: StoreWatcher?
    private var engine: CaptureEngine?
    private var directory: URL?
    private var storeURL: URL?

    /// An engine pointed at a store the test owns. Nothing here ever resolves the real
    /// system store — a test that read the developer's own notifications would be a
    /// privacy bug in the test suite.
    private static func makeEngine(archive: Archive, watcher: StoreWatcher, storeURL: URL) -> CaptureEngine {
        CaptureEngine(archive: archive, watcher: watcher) { storeURL }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureEngineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Polls `condition` until it holds, or fails the test. The watcher hands wakes over
    /// on its own queue, so there is nothing to await directly.
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
