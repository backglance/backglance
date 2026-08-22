@testable import BackglanceCapture
import Foundation
import XCTest

/// The cadence, which is the part with a design decision in it: activation catches nearly
/// every real grant, and the timer is a fallback that must not outlive the screen it exists
/// for.
@MainActor
final class FullDiskAccessMonitorTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try Self.temporaryDirectory()
        storeURL = try XCTUnwrap(directory).appendingPathComponent("db")
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        storeURL = nil
        try super.tearDownWithError()
    }

    // MARK: - Answering

    func testTheFirstAnswerIsTakenAtInit() throws {
        try createStore()

        let monitor = try makeMonitor()

        XCTAssertEqual(monitor.state, .granted)
    }

    /// The grant happens in another app. Coming back is the event that has to notice.
    func testBecomingActiveNoticesAGrant() throws {
        let monitor = try makeMonitor()
        XCTAssertEqual(monitor.state, .storeMissing)

        try createStore()
        monitor.applicationDidBecomeActive()

        XCTAssertEqual(monitor.state, .granted)
    }

    /// `onChange` is what starts capture, so it must not fire on every probe that confirms
    /// what was already true — a poll every thirty seconds would otherwise restart capture
    /// every thirty seconds.
    func testOnChangeFiresOnlyWhenTheAnswerChanges() throws {
        try createStore()
        let monitor = try makeMonitor()
        var changes: [FullDiskAccessState] = []
        monitor.onChange = { changes.append($0) }

        monitor.checkNow()
        monitor.checkNow()

        XCTAssertEqual(monitor.probeCount, 2, "it did ask")
        XCTAssertTrue(changes.isEmpty, "and had nothing new to say")
    }

    func testOnChangeCarriesTheNewAnswer() throws {
        let monitor = try makeMonitor()
        var changes: [FullDiskAccessState] = []
        monitor.onChange = { changes.append($0) }

        try createStore()
        monitor.checkNow()

        XCTAssertEqual(changes, [.granted])
    }

    // MARK: - The fallback timer

    func testPollingReprobesUntilItIsStopped() async throws {
        let monitor = try makeMonitor(pollInterval: .milliseconds(20))

        monitor.startPolling()
        XCTAssertTrue(monitor.isPolling)
        try await Task.sleep(for: .milliseconds(120))
        let whilePolling = monitor.probeCount

        monitor.stopPolling()
        try await Task.sleep(for: .milliseconds(120))

        XCTAssertGreaterThan(whilePolling, 1, "the timer should have re-probed")
        XCTAssertEqual(monitor.probeCount, whilePolling, "and stopped when told to")
        XCTAssertFalse(monitor.isPolling)
    }

    /// A second onboarding screen appearing must not start a second timer.
    func testStartingTwiceRunsOneTimer() async throws {
        let monitor = try makeMonitor(pollInterval: .milliseconds(20))

        monitor.startPolling()
        monitor.startPolling()
        try await Task.sleep(for: .milliseconds(70))
        monitor.stopPolling()

        // Three ticks' worth of window; two timers would roughly double it. The bound is
        // loose on purpose — this is asserting "one timer", not a schedule.
        XCTAssertLessThanOrEqual(monitor.probeCount, 5, "\(monitor.probeCount) probes suggests two timers")
    }

    /// 🔒 Nothing polls outside onboarding. A menu bar app that wakes every thirty seconds
    /// forever to ask a question nobody is waiting on is a battery bug.
    func testAMonitorDoesNotPollUntilItIsAsked() async throws {
        let monitor = try makeMonitor(pollInterval: .milliseconds(20))
        let atRest = monitor.probeCount

        try await Task.sleep(for: .milliseconds(120))

        XCTAssertFalse(monitor.isPolling)
        XCTAssertEqual(monitor.probeCount, atRest)
    }

    // MARK: Private

    private var directory: URL?
    private var storeURL: URL?

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FullDiskAccessMonitorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createStore() throws {
        try Data("x".utf8).write(to: XCTUnwrap(storeURL))
    }

    private func makeMonitor(pollInterval: Duration = .seconds(30)) throws -> FullDiskAccessMonitor {
        let url = try XCTUnwrap(storeURL)
        return FullDiskAccessMonitor(probe: FullDiskAccessProbe { url }, pollInterval: pollInterval)
    }
}
