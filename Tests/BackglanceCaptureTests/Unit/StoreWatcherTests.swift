@testable import BackglanceCapture
import Foundation
import XCTest

/// ⚠️ These watch an ordinary file standing in for Apple's store. Nothing here reads
/// `~/Library`. Every test uses a short debounce and a short poll interval so the suite
/// does not spend fifteen seconds waiting for a timer.
final class StoreWatcherTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StoreWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("store".utf8).write(to: storeURL)
    }

    override func tearDownWithError() throws {
        watcher?.stop()
        watcher = nil
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Waking on a write

    /// The core promise: something appended to the store, and the engine hears about it
    /// within the debounce window rather than waiting for the next poll.
    func testAWriteToTheStoreWakesTheEngine() async throws {
        let watcher = makeWatcher()
        watcher.start()
        try await settle()

        try append("a notification")

        let reason = try await firstWake(from: watcher, timeout: 2)
        XCTAssertEqual(reason, .fileChanged)
    }

    /// The `-wal` is where new rows land before a checkpoint, so a write there has to
    /// wake the engine just as a write to `db` does.
    func testAWriteToTheWalWakesTheEngine() async throws {
        try Data("wal".utf8).write(to: walURL)
        let watcher = makeWatcher()
        watcher.start()
        try await settle()

        let handle = try FileHandle(forWritingTo: walURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("more".utf8))
        try handle.synchronize()

        let reason = try await firstWake(from: watcher, timeout: 2)
        XCTAssertEqual(reason, .fileChanged)
    }

    /// A burst — an app posting fifty notifications in a second — must produce one tick,
    /// not fifty. One tick reads all fifty anyway.
    func testABurstOfWritesIsCoalescedIntoASingleWake() async throws {
        let watcher = makeWatcher(debounce: 0.3)
        watcher.start()
        try await settle()

        for index in 0 ..< 20 {
            try append("notification \(index)")
        }

        let wakes = await countWakes(from: watcher, within: 1.5)

        XCTAssertEqual(wakes, 1, "twenty writes inside one debounce window are one tick")
    }

    /// Coalescing a burst is the goal; swallowing one is not.
    ///
    /// A plain cancel-and-reschedule debounce starves under *sustained* activity: every
    /// new write cancels the wake that was about to fire, so a steadily chatty app — or
    /// anything writing faster than the debounce — would mean the engine is never told
    /// anything at all, and nothing is ever archived. The wake is capped for that reason.
    func testSustainedWritesStillWakeTheEngine() async throws {
        let watcher = makeWatcher(debounce: 0.2)
        watcher.start()
        try await settle()

        // Writes arriving faster than the debounce, continuously, for longer than the cap.
        let writing = Task {
            for _ in 0 ..< 30 {
                try? self.append("a steady stream")
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { writing.cancel() }

        let reason = try await firstWake(from: watcher, timeout: 2)
        XCTAssertEqual(reason, .fileChanged)
    }

    // MARK: - The poll fallback

    /// The backstop. Without Full Disk Access no file source ever arms, so the poll is
    /// the only trigger left — and it is what lets capture resume on its own the moment
    /// access is granted, with no relaunch.
    func testThePollTimerWakesTheEngineWithNoFileActivity() async throws {
        let watcher = makeWatcher(pollInterval: 0.2)
        watcher.start()

        let reason = try await firstWake(from: watcher, timeout: 3)
        XCTAssertEqual(reason, .poll)
    }

    func testTheDefaultPollIntervalMatchesThePowerState() {
        let watcher = makeWatcher(pollInterval: nil)
        let expected: TimeInterval = ProcessInfo.processInfo.isLowPowerModeEnabled ? 60 : 15

        XCTAssertEqual(watcher.pollInterval, expected)
    }

    // MARK: - Manual trigger

    /// Someone clicked "Check now" and is watching the menu bar. `poke()` skips the
    /// debounce for exactly that reason.
    func testPokeWakesImmediately() async throws {
        let watcher = makeWatcher(debounce: 5)
        watcher.start()
        try await settle()

        watcher.poke()

        // Far inside the 5 s debounce this watcher would otherwise impose.
        let reason = try await firstWake(from: watcher, timeout: 1)
        XCTAssertEqual(reason, .manual)
    }

    /// A watcher that kept firing after `stop()` would drive ticks while capture is
    /// paused, which is the one thing pausing has to prevent.
    func testNoWakesArriveAfterStop() async throws {
        let watcher = makeWatcher(debounce: 0.1)
        watcher.start()
        try await settle()
        watcher.stop()
        try await settle()

        try append("written after stop")

        await assertNoWake(from: watcher, within: 0.8)
    }

    /// `start()` after `stop()` has to work: the engine restarts the watcher when it
    /// recovers from a degraded state.
    func testStartingAgainAfterStopResumesWaking() async throws {
        let watcher = makeWatcher()
        watcher.start()
        try await settle()
        watcher.stop()
        try await settle()
        watcher.start()
        try await settle()

        try append("written after restart")

        let reason = try await firstWake(from: watcher, timeout: 2)
        XCTAssertEqual(reason, .fileChanged)
    }

    /// Arming twice must replace the sources, not stack a second set on top of them.
    func testStartingTwiceDoesNotDoubleTheWakes() async throws {
        let watcher = makeWatcher(debounce: 0.2)
        watcher.start()
        watcher.start()
        try await settle()

        try append("a notification")

        let reason = try await firstWake(from: watcher, timeout: 2)
        XCTAssertEqual(reason, .fileChanged)
        await assertNoWake(from: watcher, within: 0.8)
    }

    /// A watcher that is released without `stop()` has to let go of its file descriptors.
    ///
    /// `deinit` used to finish the wake stream and nothing else, so every watcher that
    /// went out of scope un-stopped left `O_EVTONLY` descriptors on `db`, `db-wal` and
    /// `db2/` open, plus a repeating poll timer, for the lifetime of the process. Nothing
    /// misbehaved visibly — the event handlers hold `self` weakly, so they simply stopped
    /// doing anything — which is exactly why it needs a test that looks at the descriptors
    /// rather than at the behaviour.
    func testAWatcherReleasedWithoutStoppingClosesItsDescriptors() async throws {
        // One warm-up round first: the very first watcher pays one-time costs (queue
        // creation, dyld) that would otherwise read as a leak.
        do {
            let warmUp = StoreWatcher(location: storeURL, debounce: 0.1, pollInterval: 30)
            warmUp.start()
            try await settle()
        }
        try await settle()

        let before = Self.openDescriptorCount()
        for _ in 0 ..< 5 {
            let leaked = StoreWatcher(location: storeURL, debounce: 0.1, pollInterval: 30)
            leaked.start()
            try await settle()
            // Deliberately no stop(): the point is that dropping the last reference is
            // enough. `start()`'s queue block retains the watcher until it has run, which
            // the settle above waits for, so the release here really is the last one.
        }
        try await settle()
        let after = Self.openDescriptorCount()

        // Five watchers × three descriptors is fifteen; a small allowance absorbs
        // unrelated churn without letting a real leak through.
        XCTAssertLessThanOrEqual(after, before + 3, "open descriptors went from \(before) to \(after)")
    }

    /// A store recreated under the watcher — `usernoted` checkpointing, or a fresh
    /// account getting its first notification — must not leave capture watching a dead
    /// inode for the rest of the session.
    func testAReplacedStoreFileIsPickedUpAgain() async throws {
        let watcher = makeWatcher(debounce: 0.1)
        watcher.start()
        try await settle()

        try FileManager.default.removeItem(at: storeURL)
        try Data("a brand new store".utf8).write(to: storeURL)
        // The re-arm is deliberately delayed so the replacement is actually in place.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        _ = await nextWake(from: watcher, within: 0.3)

        try append("written to the new file")

        let reason = try await firstWake(from: watcher, timeout: 2)
        XCTAssertEqual(reason, .fileChanged)
    }

    // MARK: Private

    private var root = URL(fileURLWithPath: NSTemporaryDirectory())
    private var watcher: StoreWatcher?

    private var storeURL: URL {
        root.appendingPathComponent("db")
    }

    private var walURL: URL {
        root.appendingPathComponent("db-wal")
    }

    /// How many file descriptors this process currently holds open.
    ///
    /// `fcntl(_:F_GETFD)` succeeds for an open descriptor and fails with `EBADF` for a
    /// closed one, which is the cheapest reliable way to count them on Darwin.
    private static func openDescriptorCount() -> Int {
        var count = 0
        for descriptor in 0 ..< Int32(getdtablesize()) where fcntl(descriptor, F_GETFD) != -1 {
            count += 1
        }
        return count
    }

    /// A watcher with test-sized timings, retained so teardown can stop it.
    ///
    /// The poll interval defaults to something long enough that a poll never races the
    /// file-change assertions — a test that means to observe a poll asks for a short one.
    private func makeWatcher(debounce: TimeInterval = 0.2, pollInterval: TimeInterval? = 30) -> StoreWatcher {
        let watcher = StoreWatcher(location: storeURL, debounce: debounce, pollInterval: pollInterval)
        self.watcher = watcher
        return watcher
    }

    /// Lets `start()`/`stop()` finish on the watcher's private queue, and lets any
    /// re-arm settle, before the test does something observable.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    private func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: storeURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.synchronize()
    }

    /// The next wake. Fails the test if none arrives — a watcher that stays silent is
    /// the failure these tests exist to catch, never a reason to skip.
    private func firstWake(
        from watcher: StoreWatcher,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> WakeReason {
        let reason = await nextWake(from: watcher, within: timeout)
        return try XCTUnwrap(reason, "no wake within \(timeout)s", file: file, line: line)
    }

    /// How many wakes arrive in `window`. Used to prove coalescing, so it counts rather
    /// than stopping at the first.
    private func countWakes(from watcher: StoreWatcher, within window: TimeInterval) async -> Int {
        await withTaskGroup(of: Int.self) { group in
            group.addTask {
                var count = 0
                for await _ in watcher.wakes {
                    count += 1
                }
                return count
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
                return -1
            }
            // The timeout task finishes first by construction; cancelling the group ends
            // the iteration, and its partial count is what the second `next()` returns.
            _ = await group.next()
            group.cancelAll()
            let counted = await group.next() ?? 0
            return max(counted, 0)
        }
    }

    /// The next wake, or `nil` on timeout.
    private func nextWake(from watcher: StoreWatcher, within timeout: TimeInterval) async -> WakeReason? {
        await withTaskGroup(of: WakeReason?.self) { group in
            group.addTask {
                for await reason in watcher.wakes {
                    return reason
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let result = await group.next().flatMap { $0 }
            group.cancelAll()
            return result
        }
    }

    private func assertNoWake(from watcher: StoreWatcher, within timeout: TimeInterval) async {
        let reason = await nextWake(from: watcher, within: timeout)
        XCTAssertNil(reason, "expected silence, got \(String(describing: reason))")
    }
}
