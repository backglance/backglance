@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

// MARK: - ScriptedAwayClock

/// A clock the test moves, whose `sleep` waits for the test to move it.
///
/// Copied from `AwaySessionTrackerTests` (private there, so duplicated rather than shared)
/// rather than reimplemented: the merge gap is 60 seconds, and a test that waited it out
/// for real would take a minute per case. `sleep` polls this clock instead of the wall
/// clock — one real millisecond per turn, cancellable, and it returns the instant the test
/// advances past the deadline.
private final class ScriptedAwayClock: AwayClock, @unchecked Sendable {
    // MARK: Lifecycle

    init(now: Date = Date(timeIntervalSince1970: 1_767_225_600)) {
        instant = now
    }

    // MARK: Internal

    var now: Date {
        lock.withLock { instant }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { instant = instant.addingTimeInterval(interval) }
    }

    func sleep(until deadline: Date) async throws {
        while now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: Private

    private let lock = NSLock()
    private var instant: Date
}

// MARK: - FlowRecorder

/// Collects what `AwaySessionRecorder` produced for each session the tracker finished.
///
/// The tracker's `onEnd` calls `AwaySessionRecorder.record(_:)` synchronously and hands the
/// `Outcome?` here, so a test can `wait(for:)` the whole chain — tracker event, session row,
/// linked notifications, digest row — the same way `AwaySessionTrackerTests`' `Recorder`
/// waits for a committed session.
private actor FlowRecorder {
    // MARK: Internal

    private(set) var outcomes: [AwaySessionRecorder.Outcome] = []

    func record(_ outcome: AwaySessionRecorder.Outcome?) {
        if let outcome {
            outcomes.append(outcome)
        }
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }

    /// Waits until `count` outcomes have arrived.
    func wait(for count: Int) async {
        while outcomes.count < count {
            await withCheckedContinuation { continuations.append($0) }
        }
    }

    // MARK: Private

    private var continuations: [CheckedContinuation<Void, Never>] = []
}

// MARK: - DigestFlowTests

/// End to end: `AwaySessionTracker` events, through `AwaySessionRecorder`, to a session row,
/// linked notifications, and a `Digest` row — the real types, wired the way
/// `AppDelegate` wires them, not a reimplementation of the wiring.
///
/// See docs/testing/TESTING.md#digest-tests and
/// docs/features/MISSED_DIGEST.md#archive-tables-involved.
final class DigestFlowTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archiveStorage = try Archive(inMemory: true)
        appIDStorage = try seedApp()
        defaultsSuiteName = "app.backglance.tests.digestflow.\(UUID().uuidString)"
        defaultsStorage = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
    }

    override func tearDownWithError() throws {
        if let defaultsSuiteName {
            defaultsStorage?.removePersistentDomain(forName: defaultsSuiteName)
        }
        defaultsStorage = nil
        defaultsSuiteName = nil
        archiveStorage = nil
        appIDStorage = nil
        try super.tearDownWithError()
    }

    // MARK: - The headline case

    func testLockTenMinutesWithOneNotificationProducesOneSessionAndOneDigest() async throws {
        let clock = ScriptedAwayClock()
        let (tracker, flow) = try makeChain(clock: clock)

        await tracker.handle(.screenLocked)
        clock.advance(by: 5 * 60)
        let notificationID = try seedNotification(at: clock.now)
        clock.advance(by: 5 * 60)
        await tracker.handle(.screenUnlocked)
        clock.advance(by: AwaySessionTracker.mergeGap + 1)
        await flow.wait(for: 1)

        let outcomes = await flow.outcomes
        let outcome = try XCTUnwrap(outcomes.first)
        XCTAssertEqual(outcome.session.reason, .locked)
        XCTAssertNotNil(outcome.session.id)
        XCTAssertEqual(try sessionCount(), 1, "exactly one away_sessions row")

        let digest = try XCTUnwrap(outcome.digest, "a 10-minute session with an arrival earns a digest")
        XCTAssertEqual(digest.itemCount, 1)
        XCTAssertEqual(try digestCount(), 1, "exactly one digests row")

        let linkedSessionID = try await archive().pool.read { db in
            try ArchivedNotification.fetchOne(db, key: notificationID)?.awaySessionId
        }
        XCTAssertEqual(linkedSessionID, outcome.session.id, "the notification points at the session")
    }

    // MARK: - Never twice

    func testASecondRecordForAnEquivalentWindowBuildsNoTwinDigestAndDismissRetiresItForGood() async throws {
        let clock = ScriptedAwayClock()
        let (tracker, flow) = try makeChain(clock: clock)

        await tracker.handle(.screenLocked)
        clock.advance(by: 5 * 60)
        try seedNotification(at: clock.now)
        clock.advance(by: 5 * 60)
        await tracker.handle(.screenUnlocked)
        clock.advance(by: AwaySessionTracker.mergeGap + 1)
        await flow.wait(for: 1)

        let outcomes = await flow.outcomes
        let first = try XCTUnwrap(outcomes.first)
        let firstDigest = try XCTUnwrap(first.digest)

        // A second session-end event for an equivalent window — the "wake and unlock race"
        // `AwaySessionRecorder` documents. It is recorded as its own row (the tracker never
        // hands back an id, so this is a fresh insert, not a duplicate primary key), but its
        // notifications are already claimed by the first digest, so it builds nothing.
        let policy = DigestPolicy(defaults: testDefaults())
        let recorder = try AwaySessionRecorder(archive: archive()) { policy }
        let duplicate = AwaySessionTracker.EndedSession(
            session: AwaySession(
                startedAt: first.session.startedAt,
                endedAt: first.session.endedAt,
                reason: first.session.reason
            ),
            reasons: [.locked],
            isPartial: false,
            isReconstructed: false,
            meetsDigestThreshold: true
        )
        let second = recorder.record(duplicate)

        XCTAssertNotNil(second, "the duplicate session is still recorded honestly")
        XCTAssertNil(
            second?.digest,
            "nothing left to select once the first digest claimed it — a second build is refused"
        )
        XCTAssertEqual(try digestCount(), 1, "still exactly one digest in the whole archive")

        let pending = try archive().pendingDigest()
        XCTAssertEqual(pending?.id, firstDigest.id, "pendingDigest surfaces the one digest that was built")

        _ = try archive().dismissDigest(XCTUnwrap(pending?.id))
        XCTAssertNil(try archive().pendingDigest(), "once dismissed, it never surfaces again")
    }

    // MARK: - Under the threshold

    func testATwoMinuteSessionIsRecordedButEarnsNoDigest() async throws {
        let clock = ScriptedAwayClock()
        let (tracker, flow) = try makeChain(clock: clock)

        await tracker.handle(.screenLocked)
        clock.advance(by: 60)
        let notificationID = try seedNotification(at: clock.now)
        clock.advance(by: 60)
        await tracker.handle(.screenUnlocked)
        clock.advance(by: AwaySessionTracker.mergeGap + 1)
        await flow.wait(for: 1)

        let outcomes = await flow.outcomes
        let outcome = try XCTUnwrap(outcomes.first)
        XCTAssertNotNil(outcome.session.id, "short sessions are still recorded so is:missed keeps working")
        XCTAssertNil(outcome.digest, "2 minutes is under the 5-minute default threshold")
        XCTAssertEqual(try sessionCount(), 1)
        XCTAssertEqual(try digestCount(), 0)

        let linkedSessionID = try await archive().pool.read { db in
            try ArchivedNotification.fetchOne(db, key: notificationID)?.awaySessionId
        }
        XCTAssertEqual(linkedSessionID, outcome.session.id, "linking happens at record time, not at digest time")
    }

    // MARK: - Nothing arrived

    func testATenMinuteSessionWithNoNotificationsIsRecordedButBuildsNoDigest() async throws {
        let clock = ScriptedAwayClock()
        let (tracker, flow) = try makeChain(clock: clock)

        await tracker.handle(.screenLocked)
        clock.advance(by: 10 * 60)
        await tracker.handle(.screenUnlocked)
        clock.advance(by: AwaySessionTracker.mergeGap + 1)
        await flow.wait(for: 1)

        let outcomes = await flow.outcomes
        let outcome = try XCTUnwrap(outcomes.first)
        XCTAssertNotNil(outcome.session.id)
        XCTAssertNil(outcome.digest, "an empty digest is an interruption that says nothing happened")
        XCTAssertEqual(try sessionCount(), 1)
        XCTAssertEqual(try digestCount(), 0)
    }

    // MARK: - "Never" means never

    func testNeverThresholdRecordsTheSessionAndBuildsNothing() async throws {
        DigestThreshold.save(.never, to: testDefaults())
        let clock = ScriptedAwayClock()
        let (tracker, flow) = try makeChain(clock: clock)

        await tracker.handle(.screenLocked)
        clock.advance(by: 10 * 60)
        try seedNotification(at: clock.now)
        await tracker.handle(.screenUnlocked)
        clock.advance(by: AwaySessionTracker.mergeGap + 1)
        await flow.wait(for: 1)

        let outcomes = await flow.outcomes
        let outcome = try XCTUnwrap(outcomes.first)
        XCTAssertNotNil(outcome.session.id, "never still records the session")
        XCTAssertNil(outcome.digest, "never means never, even though the session met the tracker's own threshold")
        XCTAssertEqual(try sessionCount(), 1)
        XCTAssertEqual(try digestCount(), 0)
    }

    // MARK: - A disabled reason

    func testALockOnlySessionBuildsNothingWhenLockedIsDisabled() async throws {
        DigestPolicy.save(disabledReasons: [.locked], to: testDefaults())
        let clock = ScriptedAwayClock()
        let (tracker, flow) = try makeChain(clock: clock)

        await tracker.handle(.screenLocked)
        clock.advance(by: 10 * 60)
        try seedNotification(at: clock.now)
        await tracker.handle(.screenUnlocked)
        clock.advance(by: AwaySessionTracker.mergeGap + 1)
        await flow.wait(for: 1)

        let outcomes = await flow.outcomes
        let outcome = try XCTUnwrap(outcomes.first)
        XCTAssertNil(outcome.digest, "the session's only cause is the one the user switched off")
        XCTAssertEqual(try digestCount(), 0)
    }

    func testASessionWithLockedAndFocusStillBuildsWhenOnlyLockedIsDisabled() async throws {
        DigestPolicy.save(disabledReasons: [.locked], to: testDefaults())
        let clock = ScriptedAwayClock()
        let (tracker, flow) = try makeChain(clock: clock)

        // Locking the lid during a Focus is still a lock: one live cause (`focus`) is
        // enough, even though `locked` — the session's primary, chronologically first
        // cause — is disabled.
        await tracker.handle(.focusChanged(active: true))
        clock.advance(by: 30)
        await tracker.handle(.screenLocked)
        clock.advance(by: 5 * 60)
        let notificationID = try seedNotification(at: clock.now)
        clock.advance(by: 30)
        await tracker.handle(.focusChanged(active: false))
        await tracker.handle(.screenUnlocked)
        clock.advance(by: AwaySessionTracker.mergeGap + 1)
        await flow.wait(for: 1)

        let outcomes = await flow.outcomes
        let outcome = try XCTUnwrap(outcomes.first)
        XCTAssertEqual(outcome.session.reason, .focus, "the column keeps the first cause chronologically")
        let digest = try XCTUnwrap(outcome.digest, "focus alone is a live cause, so the session still earns a digest")
        XCTAssertEqual(digest.itemCount, 1)
        XCTAssertEqual(try digestCount(), 1)

        let linkedSessionID = try await archive().pool.read { db in
            try ArchivedNotification.fetchOne(db, key: notificationID)?.awaySessionId
        }
        XCTAssertEqual(linkedSessionID, outcome.session.id)
    }

    // MARK: Private

    private enum SeedFailure: Error {
        case noRowID
    }

    private var archiveStorage: Archive?
    private var appIDStorage: Int64?
    private var defaultsStorage: UserDefaults?
    private var defaultsSuiteName: String?

    private let base = Date(timeIntervalSince1970: 1_767_225_600)

    private func archive() throws -> Archive {
        try XCTUnwrap(archiveStorage)
    }

    private func appID() throws -> Int64 {
        try XCTUnwrap(appIDStorage)
    }

    /// A local copy of the throwaway `UserDefaults`, safe to capture in a `@Sendable`
    /// closure — the closures below capture this value, never `self`.
    private func testDefaults() -> UserDefaults {
        defaultsStorage ?? UserDefaults.standard
    }

    /// Builds the real chain: a scripted-clock tracker whose `onEnd` calls the real
    /// `AwaySessionRecorder` against this test's archive, collected by a `FlowRecorder`
    /// a test can `wait(for:)`.
    ///
    /// The policy is read from the test's defaults once, here, rather than captured as a
    /// live-reading closure — `UserDefaults` is not `Sendable`, and every case in this file
    /// finishes configuring its defaults before building the chain, so a snapshot is exact.
    private func makeChain(
        clock: ScriptedAwayClock,
        minDuration: @escaping @Sendable () -> TimeInterval = { AwaySessionTracker.defaultMinDuration }
    ) throws -> (tracker: AwaySessionTracker, flow: FlowRecorder) {
        let archive = try archive()
        let policy = DigestPolicy(defaults: testDefaults())
        let recorder = AwaySessionRecorder(archive: archive) { policy }
        let flow = FlowRecorder()
        let tracker = AwaySessionTracker(clock: clock, minDuration: minDuration) { ended in
            await flow.record(recorder.record(ended))
        }
        return (tracker, flow)
    }

    private func seedApp(bundleID: String = "com.example.Chat") throws -> Int64 {
        try archive().pool.write { db in
            var app = AppRecord(
                bundleId: bundleID,
                displayName: bundleID,
                firstSeenAt: UnixDate(self.base),
                lastSeenAt: UnixDate(self.base)
            )
            try app.insert(db)
            guard let id = app.id else {
                throw SeedFailure.noRowID
            }
            return id
        }
    }

    @discardableResult
    private func seedNotification(at delivered: Date, presented: Bool = true) throws -> Int64 {
        let owner = try appID()
        return try archive().pool.write { db in
            var row = ArchivedNotification(
                uuid: UUID().uuidString,
                appId: owner,
                title: "Seed",
                deliveredAt: UnixDate(delivered),
                capturedAt: UnixDate(delivered),
                presented: presented
            )
            try row.insert(db)
            guard let id = row.id else {
                throw SeedFailure.noRowID
            }
            return id
        }
    }

    private func sessionCount() throws -> Int {
        try archive().pool.read { db in try AwaySession.fetchCount(db) }
    }

    private func digestCount() throws -> Int {
        try archive().pool.read { db in try Digest.fetchCount(db) }
    }
}
