@testable import BackglanceCapture
import BackglanceCore
import Foundation
import XCTest

/// Copying a live SQLite database races the process writing to it, so not every read
/// failure is news. These pin which failures get a retry budget and which do not — the
/// distinction between "your Mac is fine, that was a checkpoint" and "capture is broken
/// and you should know".
///
/// ⚠️ Nothing here reads `~/Library`: every store is a `MiniatureStore` in a temp
/// directory, deliberately corrupted in place.
final class CaptureEngineTransientFailureTests: XCTestCase {
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
        engine = CaptureEngine(archive: archive, watcher: watcher) { directory.appendingPathComponent("db") }
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

    /// Copying a live SQLite database races `usernoted` writing to it. A checkpoint
    /// landing mid-copy yields a snapshot that opens as `SQLITE_NOTADB`, which is
    /// ordinary and fixes itself on the next poll — so it must not put "Backglance
    /// couldn't read the system's notification database" in front of someone whose Mac
    /// is working perfectly (docs/features/CAPTURE.md#edge-cases-and-error-handling).
    func testATornCopyIsRetriedRatherThanDegradingImmediately() async throws {
        let engine = try XCTUnwrap(engine)
        let storeURL = try XCTUnwrap(storeURL)
        try MiniatureStore.makeFile(at: storeURL, rows: MiniatureStore.rows(1))
        await engine.start()

        try Data("not a database".utf8).write(to: storeURL)
        for _ in 1 ..< CaptureEngine.transientFailureLimit {
            await engine.tick(reason: .poll)
        }

        let status = await engine.status
        XCTAssertEqual(status, .running, "still running with retries left")
    }

    /// A store that genuinely will not copy for a minute is worth telling the user about.
    func testATornCopyThatKeepsRepeatingEventuallyDegrades() async throws {
        let engine = try XCTUnwrap(engine)
        let storeURL = try XCTUnwrap(storeURL)
        try MiniatureStore.makeFile(at: storeURL, rows: MiniatureStore.rows(1))
        await engine.start()

        try Data("not a database".utf8).write(to: storeURL)
        for _ in 1 ... CaptureEngine.transientFailureLimit {
            await engine.tick(reason: .poll)
        }

        let status = await engine.status
        guard case .degraded = status else {
            return XCTFail(
                "expected degraded after \(CaptureEngine.transientFailureLimit), got \(status.logDescription)"
            )
        }
    }

    /// "Consecutive" has to mean consecutive: scattered checkpoint races over an
    /// afternoon must never accumulate into a degraded banner.
    func testASuccessfulTickForgivesEarlierTransientFailures() async throws {
        let engine = try XCTUnwrap(engine)
        let storeURL = try XCTUnwrap(storeURL)
        try MiniatureStore.makeFile(at: storeURL, rows: MiniatureStore.rows(1))
        let healthy = try Data(contentsOf: storeURL)
        await engine.start()

        for _ in 1 ..< CaptureEngine.transientFailureLimit {
            try Data("not a database".utf8).write(to: storeURL)
            await engine.tick(reason: .poll)
            try healthy.write(to: storeURL)
            await engine.tick(reason: .poll)
        }

        let status = await engine.status
        XCTAssertEqual(status, .running, "the counter resets on every tick that reads cleanly")
    }

    /// Permission and schema failures are standing conditions the user can act on, so
    /// they skip the retry budget entirely.
    func testAMissingStoreDegradesWithoutSpendingRetries() async throws {
        let engine = try XCTUnwrap(engine)
        let storeURL = try XCTUnwrap(storeURL)
        try MiniatureStore.makeFile(at: storeURL, rows: MiniatureStore.rows(1))
        await engine.start()

        try FileManager.default.removeItem(at: storeURL)
        await engine.tick(reason: .poll)

        let status = await engine.status
        XCTAssertEqual(status, .degraded(.storeNotFound), "no waiting for a condition that will not clear")
    }

    // MARK: Private

    private var archive: Archive!
    private var watcher: StoreWatcher!
    private var engine: CaptureEngine!
    private var directory: URL!
    private var storeURL: URL!

    private static func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CaptureEngineTransientFailureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
