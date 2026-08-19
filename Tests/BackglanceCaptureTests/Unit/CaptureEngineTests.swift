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
        engine = CaptureEngine(archive: archive, watcher: watcher)
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

    private var archive: Archive?
    private var watcher: StoreWatcher?
    private var engine: CaptureEngine?
    private var directory: URL?

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
