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

    // MARK: - Ticks

    func testAWakeReadsEverythingNewAndPersistsHowFarItGot() async throws {
        let engine = try XCTUnwrap(engine)
        let archive = try XCTUnwrap(archive)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: MiniatureStore.rows(4))
        await engine.start()

        await engine.tick(reason: .manual)

        let cursor = await engine.currentCursor
        let recordsRead = await engine.recordsRead
        XCTAssertEqual(cursor.lastRecID, 4)
        XCTAssertEqual(recordsRead, 4)
        // Persisted after the batch, so the next launch resumes rather than re-reads.
        try XCTAssertEqual(archive.loadCursor()?.lastRecID, 4)
    }

    /// The common case on a quiet Mac: the watcher's poll fires, there is nothing new.
    func testAWakeWithNothingNewLeavesTheCursorAlone() async throws {
        let engine = try XCTUnwrap(engine)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: MiniatureStore.rows(2))
        await engine.start()
        await engine.tick(reason: .poll)

        await engine.tick(reason: .poll)

        let cursor = await engine.currentCursor
        let recordsRead = await engine.recordsRead
        XCTAssertEqual(cursor.lastRecID, 2)
        XCTAssertEqual(recordsRead, 2)
    }

    func testATickReadsOnlyWhatArrivedSinceTheLastOne() async throws {
        let engine = try XCTUnwrap(engine)
        let storeURL = try XCTUnwrap(storeURL)
        try MiniatureStore.makeFile(at: storeURL, rows: MiniatureStore.rows(2))
        await engine.start()
        await engine.tick(reason: .poll)

        try MiniatureStore.append(Array(MiniatureStore.rows(5).dropFirst(2)), to: storeURL)
        await engine.tick(reason: .fileChanged)

        let cursor = await engine.currentCursor
        let recordsRead = await engine.recordsRead
        XCTAssertEqual(cursor.lastRecID, 5)
        XCTAssertEqual(recordsRead, 5)
    }

    /// The wake stream is the retry schedule: every unlock, wake and poll is a chance
    /// that Full Disk Access was granted or the store finally exists.
    func testADegradedEngineRetriesItsBootstrapOnTheNextWake() async throws {
        let engine = try XCTUnwrap(engine)
        let storeURL = try XCTUnwrap(storeURL)
        await engine.start()
        let degraded = await engine.status
        XCTAssertEqual(degraded, .degraded(.storeNotFound))

        try MiniatureStore.makeFile(at: storeURL, rows: MiniatureStore.rows(1))
        await engine.tick(reason: .screenUnlocked)

        let recovered = await engine.status
        XCTAssertEqual(recovered, .running)
    }

    /// A store that vanishes under a running engine — the user reset their notification
    /// database, or the account was migrated.
    func testAReadFailureDegradesInsteadOfThrowing() async throws {
        let engine = try XCTUnwrap(engine)
        let storeURL = try XCTUnwrap(storeURL)
        try MiniatureStore.makeFile(at: storeURL, rows: MiniatureStore.rows(1))
        await engine.start()

        try FileManager.default.removeItem(at: storeURL)
        await engine.tick(reason: .poll)

        let status = await engine.status
        XCTAssertEqual(status, .degraded(.storeNotFound))
    }

    /// A stopped engine must not resume behind the user's back when a wake arrives.
    func testAStoppedEngineIgnoresAWake() async throws {
        let engine = try XCTUnwrap(engine)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: MiniatureStore.rows(3))
        await engine.start()
        await engine.stop()

        await engine.tick(reason: .manual)

        let cursor = await engine.currentCursor
        let recordsRead = await engine.recordsRead
        XCTAssertEqual(cursor, .start)
        XCTAssertEqual(recordsRead, 0)
    }

    // MARK: - Metrics

    /// "Capture stopped working" is unanswerable without these. A tick that reads forty
    /// records and archives three is correct if the rest were excluded and a bug if they
    /// failed, and only the tally tells them apart.
    func testATickTalliesEveryOutcome() async throws {
        let engine = try XCTUnwrap(engine)
        let storeURL = try XCTUnwrap(storeURL)
        var corrupt = MiniatureStore.Row(recID: 2)
        corrupt.payload = Data("not a property list".utf8)
        try MiniatureStore.makeFile(at: storeURL, rows: [
            MiniatureStore.notification(recID: 1),
            corrupt,
            MiniatureStore.notification(recID: 3),
        ])

        await engine.start()
        await engine.tick(reason: .manual)

        let metrics = await engine.metrics
        XCTAssertEqual(metrics.ticks, 1)
        XCTAssertEqual(metrics.totals.read, 3)
        XCTAssertEqual(metrics.totals.archived, 2)
        XCTAssertEqual(metrics.totals.failed, 1)
        XCTAssertNotNil(metrics.lastTickAt)
    }

    /// 🔒 The summary goes into a log line and into a diagnostics export a user is about to
    /// send to a stranger, so it is counts and nothing else.
    func testTheMetricsSummaryIsCountsOnly() async throws {
        let engine = try XCTUnwrap(engine)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [
            MiniatureStore.notification(recID: 1, bundleID: "com.example.chat", title: "Ada", body: "Landing at six"),
        ])
        await engine.start()
        await engine.tick(reason: .manual)

        let summary = await engine.metrics.summary

        XCTAssertEqual(summary, "ticks 1 read 1 archived 1 updated 0 dup 0 excluded 0 failed 0 transient 0 resets 0")
    }

    /// Degrading is the thing a diagnostics report is usually about, so the reason is on
    /// the metrics too — and it clears again when capture recovers.
    func testTheDegradedReasonIsCarriedOnTheMetricsAndCleared() async throws {
        let engine = try XCTUnwrap(engine)
        let storeURL = try XCTUnwrap(storeURL)
        await engine.start()

        let degraded = await engine.metrics.degradedReason
        XCTAssertEqual(degraded, .storeNotFound)

        try MiniatureStore.makeFile(at: storeURL, rows: [MiniatureStore.notification(recID: 1)])
        await engine.tick(reason: .screenUnlocked)

        let recovered = await engine.metrics.degradedReason
        XCTAssertNil(recovered)
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
