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
        // A suite of its own, because pause is persisted: writing to `.standard` would put
        // the test machine's Backglance into whatever state the last test left behind.
        let suiteName = "app.backglance.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        self.archive = archive
        self.directory = directory
        self.storeURL = storeURL
        self.watcher = watcher
        self.suiteName = suiteName
        self.defaults = defaults
        engine = CaptureEngine(archive: archive, watcher: watcher, defaults: defaults) { storeURL }
    }

    override func tearDownWithError() throws {
        watcher?.stop()
        watcher = nil
        engine = nil
        archive = nil
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
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

    // MARK: - The four choices

    func testTheChoicesCoverFifteenMinutesAnHourTomorrowAndForever() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Istanbul"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2_026, month: 8, day: 22, hour: 14)))

        XCTAssertEqual(PauseChoice.fifteenMinutes.deadline(from: now), now.addingTimeInterval(900))
        XCTAssertEqual(PauseChoice.oneHour.deadline(from: now), now.addingTimeInterval(3_600))
        XCTAssertEqual(
            PauseChoice.untilTomorrow.deadline(from: now, calendar: calendar),
            calendar.date(from: DateComponents(year: 2_026, month: 8, day: 23))
        )
        XCTAssertNil(PauseChoice.indefinitely.deadline(from: now))
    }

    func testPausingByChoiceSchedulesTheChoicesDeadline() async throws {
        let engine = try XCTUnwrap(engine)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [MiniatureStore.notification(recID: 1)])
        await engine.start()
        let now = Date()

        await engine.pause(.oneHour, from: now)

        let status = await engine.status
        XCTAssertEqual(status, .paused(until: now.addingTimeInterval(3_600)))
    }

    // MARK: - Surviving a relaunch

    /// 🔒 Quitting is not resuming. A pause set for the rest of the day is still in force
    /// after a restart, or every pause becomes "until the next reboot".
    func testAnIndefinitePauseSurvivesARelaunch() async throws {
        let engine = try XCTUnwrap(engine)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [MiniatureStore.notification(recID: 1)])
        await engine.start()
        await engine.pause()
        await engine.stop()

        let relaunched = try relaunchedEngine()
        await relaunched.start()
        defer { Task { await relaunched.stop() } }

        let status = await relaunched.status
        XCTAssertEqual(status, .paused(until: nil))
    }

    func testATimedPauseIsRestoredWithItsRemainingTime() async throws {
        let engine = try XCTUnwrap(engine)
        let until = Date().addingTimeInterval(1_800)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [MiniatureStore.notification(recID: 1)])
        await engine.start()
        await engine.pause(until: until)
        await engine.stop()

        let relaunched = try relaunchedEngine()
        await relaunched.start()
        defer { Task { await relaunched.stop() } }

        // To the second, not to the bit: the deadline round-trips through a Unix-epoch
        // `Double`, and re-basing it on 2001 costs a few of the low ones.
        guard case let .paused(restored) = await relaunched.status else {
            return XCTFail("expected a restored pause")
        }
        try XCTAssertEqual(XCTUnwrap(restored).timeIntervalSince1970, until.timeIntervalSince1970, accuracy: 0.001)
    }

    /// 🔒 A pause that ran out overnight ends the way any other pause ends: by skipping
    /// what arrived during it, not by importing an evening's notifications at breakfast.
    func testAPauseThatExpiredWhileQuitSkipsWhatArrivedDuringIt() async throws {
        let engine = try XCTUnwrap(engine)
        let archive = try XCTUnwrap(archive)
        let storeURL = try XCTUnwrap(storeURL)
        try MiniatureStore.makeFile(at: storeURL, rows: [MiniatureStore.notification(recID: 1)])
        try archive.captureFromTheStartOfTheStore()
        await engine.start()
        await engine.tick(reason: .manual)
        await engine.pause(until: Date().addingTimeInterval(0.05))
        await engine.stop()
        try MiniatureStore.append((2 ... 5).map { MiniatureStore.notification(recID: Int64($0)) }, to: storeURL)
        try await Task.sleep(for: .milliseconds(100))

        let relaunched = try relaunchedEngine()
        await relaunched.start()
        defer { Task { await relaunched.stop() } }
        await relaunched.tick(reason: .manual)

        let count = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        let status = await relaunched.status
        XCTAssertEqual(status, .running)
        XCTAssertEqual(count, 1, "only the notification from before the pause")
    }

    func testResumingClearsTheStoredPause() async throws {
        let engine = try XCTUnwrap(engine)
        let defaults = try XCTUnwrap(defaults)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [MiniatureStore.notification(recID: 1)])
        await engine.start()
        await engine.pause()

        await engine.resume()

        XCTAssertEqual(PauseSettings(defaults: defaults).state, .notPaused)
    }

    // MARK: - Importing what arrived while paused

    /// The opt-in that turns the gap into a delay. Off by default; on, resume reads from
    /// the frozen cursor instead of jumping past it.
    func testImportWhilePausedBackfillsTheGapOnResume() async throws {
        let engine = try XCTUnwrap(engine)
        let archive = try XCTUnwrap(archive)
        let storeURL = try XCTUnwrap(storeURL)
        try PauseSettings.save(importWhilePaused: true, to: XCTUnwrap(defaults))
        try MiniatureStore.makeFile(at: storeURL, rows: [MiniatureStore.notification(recID: 1)])
        try archive.captureFromTheStartOfTheStore()
        await engine.start()
        await engine.tick(reason: .manual)
        await engine.pause()

        try MiniatureStore.append((2 ... 5).map { MiniatureStore.notification(recID: Int64($0)) }, to: storeURL)
        await engine.resume()
        await engine.tick(reason: .manual)

        let count = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        XCTAssertEqual(count, 5, "the pause was a delay, not a gap")
    }

    // MARK: Private

    private var archive: Archive?
    private var watcher: StoreWatcher?
    private var engine: CaptureEngine?
    private var directory: URL?
    private var storeURL: URL?
    private var defaults: UserDefaults?
    private var suiteName: String?

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

    /// A second engine over the same archive, store and preferences — the next launch.
    private func relaunchedEngine() throws -> CaptureEngine {
        let storeURL = try XCTUnwrap(storeURL)
        return try CaptureEngine(
            archive: XCTUnwrap(archive),
            watcher: XCTUnwrap(watcher),
            defaults: XCTUnwrap(defaults)
        ) { storeURL }
    }
}
