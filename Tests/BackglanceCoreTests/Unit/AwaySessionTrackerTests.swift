@testable import BackglanceCore
import Foundation
import XCTest

// MARK: - ScriptedAwayClock

/// A clock the test moves, whose `sleep` waits for the test to move it.
///
/// The merge gap is the whole point of the tracker's timing, and it is 60 seconds long:
/// a test that waited it out for real would take a minute per case. So `sleep` polls this
/// clock instead of the wall clock — one real millisecond per turn, cancellable, and it
/// returns the instant the test advances past the deadline.
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
        // Polls this clock rather than the wall clock, so a 60-second merge gap costs the
        // test only as long as it takes to call `advance(by:)` past the deadline. The
        // deadline is absolute and fixed by the caller before this task existed, so it
        // cannot drift past an advance the test already made.
        while now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: Private

    private let lock = NSLock()
    private var instant: Date
}

// MARK: - Recorder

/// Collects the sessions the tracker finishes.
private actor Recorder {
    // MARK: Internal

    private(set) var ended: [AwaySessionTracker.EndedSession] = []

    func record(_ session: AwaySessionTracker.EndedSession) {
        ended.append(session)
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }

    /// Waits until `count` sessions have arrived, or fails the caller's timeout.
    func wait(for count: Int) async {
        while ended.count < count {
            await withCheckedContinuation { continuations.append($0) }
        }
    }

    // MARK: Private

    private var continuations: [CheckedContinuation<Void, Never>] = []
}

// MARK: - AwaySessionTrackerTests

/// Covers the away state machine from `docs/features/MISSED_DIGEST.md#awaysessiontracker`:
/// that overlapping causes make one session rather than several, that the session ends
/// only when the last cause clears, that the merge gap swallows a brief return, and that
/// the digest threshold is reported without suppressing the row.
///
/// Every case drives the tracker through `handle(_:)` with a scripted clock. Nothing here
/// touches `DistributedNotificationCenter` or `NSWorkspace` — that adaptation lives in
/// `AwayEventBridge` in the app target, which is exactly the split that makes this file
/// possible.
final class AwaySessionTrackerTests: XCTestCase {
    // MARK: Internal

    // MARK: - One cause

    func testALockAndUnlockProducesOneSessionAfterTheMergeGap() async throws {
        let clock = ScriptedAwayClock()
        let recorder = Recorder()
        let tracker = makeTracker(clock: clock, recorder: recorder)

        await tracker.handle(.screenLocked)
        clock.advance(by: 600)
        await tracker.handle(.screenUnlocked)

        // Still inside the merge gap: nothing has been committed.
        var ended = await recorder.ended
        XCTAssertTrue(ended.isEmpty, "a session must not commit before the merge gap elapses")

        clock.advance(by: AwaySessionTracker.mergeGap + 1)
        await recorder.wait(for: 1)

        ended = await recorder.ended
        XCTAssertEqual(ended.count, 1)
        let session = try XCTUnwrap(ended.first)
        XCTAssertEqual(session.session.reason, .locked)
        XCTAssertEqual(session.reasons, [.locked])
        XCTAssertEqual(session.duration, 600, accuracy: 0.001)
        XCTAssertTrue(session.meetsDigestThreshold)
        XCTAssertFalse(session.isPartial)
        XCTAssertFalse(session.isReconstructed)
    }

    // MARK: - Overlapping causes

    func testOverlappingCausesAreOneSessionThatEndsWithTheLastOne() async throws {
        let clock = ScriptedAwayClock()
        let recorder = Recorder()
        let tracker = makeTracker(clock: clock, recorder: recorder)
        let start = clock.now

        await tracker.handle(.focusChanged(active: true))
        clock.advance(by: 60)
        await tracker.handle(.screenLocked)
        clock.advance(by: 60)
        await tracker.handle(.willSleep)

        // The first two clear; the third is still holding the session open.
        clock.advance(by: 300)
        await tracker.handle(.focusChanged(active: false))
        await tracker.handle(.screenUnlocked)
        clock.advance(by: AwaySessionTracker.mergeGap + 1)

        var isAway = await tracker.isAway
        XCTAssertTrue(isAway, "sleep is still active, so the session must still be open")
        let ended = await recorder.ended
        XCTAssertTrue(ended.isEmpty)

        await tracker.handle(.didWake)
        let end = clock.now
        clock.advance(by: AwaySessionTracker.mergeGap + 1)
        await recorder.wait(for: 1)

        isAway = await tracker.isAway
        XCTAssertFalse(isAway)

        let recorded = await recorder.ended
        let session = try XCTUnwrap(recorded.first)
        XCTAssertEqual(
            session.session.reason,
            .focus,
            "the column keeps the first cause chronologically, not the last one to clear"
        )
        XCTAssertEqual(session.reasons, [.focus, .locked, .asleep])
        XCTAssertEqual(session.session.startedAt.date, start)
        XCTAssertEqual(session.session.endedAt?.date, end)
    }

    // MARK: - Merging

    func testAGlanceInsideTheMergeGapContinuesTheSameSession() async throws {
        let clock = ScriptedAwayClock()
        let recorder = Recorder()
        let tracker = makeTracker(clock: clock, recorder: recorder)
        let start = clock.now

        await tracker.handle(.screenLocked)
        clock.advance(by: 600)
        await tracker.handle(.screenUnlocked)

        // Back inside the gap, so the candidate end is discarded.
        clock.advance(by: AwaySessionTracker.mergeGap - 10)
        await tracker.handle(.screenLocked)

        let stillNothing = await recorder.ended
        XCTAssertTrue(stillNothing.isEmpty)

        clock.advance(by: 600)
        await tracker.handle(.screenUnlocked)
        let end = clock.now
        clock.advance(by: AwaySessionTracker.mergeGap + 1)
        await recorder.wait(for: 1)

        let ended = await recorder.ended
        XCTAssertEqual(ended.count, 1, "a glance must not split one away session into two")
        let session = try XCTUnwrap(ended.first)
        XCTAssertEqual(session.session.startedAt.date, start, "the merged session keeps its original start")
        XCTAssertEqual(session.session.endedAt?.date, end)
    }

    func testAReturnAfterTheMergeGapStartsANewSession() async {
        let clock = ScriptedAwayClock()
        let recorder = Recorder()
        let tracker = makeTracker(clock: clock, recorder: recorder)

        await tracker.handle(.screenLocked)
        clock.advance(by: 600)
        await tracker.handle(.screenUnlocked)
        clock.advance(by: AwaySessionTracker.mergeGap + 1)
        await recorder.wait(for: 1)

        clock.advance(by: 3_600)
        await tracker.handle(.screenLocked)
        clock.advance(by: 600)
        await tracker.handle(.screenUnlocked)
        clock.advance(by: AwaySessionTracker.mergeGap + 1)
        await recorder.wait(for: 2)

        let ended = await recorder.ended
        XCTAssertEqual(ended.count, 2)
    }

    // MARK: - Thresholds

    func testAShortSessionIsStillRecordedButEarnsNoDigest() async throws {
        let clock = ScriptedAwayClock()
        let recorder = Recorder()
        let tracker = makeTracker(clock: clock, recorder: recorder)

        await tracker.handle(.screenLocked)
        clock.advance(by: 90)
        await tracker.handle(.screenUnlocked)
        clock.advance(by: AwaySessionTracker.mergeGap + 1)
        await recorder.wait(for: 1)

        let recorded = await recorder.ended
        let session = try XCTUnwrap(recorded.first)
        XCTAssertFalse(session.meetsDigestThreshold, "90 s is under the 5-minute default")
        XCTAssertEqual(session.duration, 90, accuracy: 0.001)
    }

    func testTheThresholdIsReadAtEachSessionEndNotCapturedOnce() async throws {
        let clock = ScriptedAwayClock()
        let recorder = Recorder()
        let minimum = MutableThreshold(seconds: 300)
        let tracker = AwaySessionTracker(
            clock: clock,
            minDuration: { minimum.seconds },
            onEnd: { await recorder.record($0) }
        )

        await tracker.handle(.screenLocked)
        clock.advance(by: 120)
        await tracker.handle(.screenUnlocked)
        clock.advance(by: AwaySessionTracker.mergeGap + 1)
        await recorder.wait(for: 1)
        let first = await recorder.ended
        XCTAssertFalse(try XCTUnwrap(first.first).meetsDigestThreshold)

        // The user lowers the setting; the next session sees it without a rebuild.
        minimum.seconds = 60

        clock.advance(by: 3_600)
        await tracker.handle(.screenLocked)
        clock.advance(by: 120)
        await tracker.handle(.screenUnlocked)
        clock.advance(by: AwaySessionTracker.mergeGap + 1)
        await recorder.wait(for: 2)
        let second = await recorder.ended
        XCTAssertTrue(try XCTUnwrap(second.last).meetsDigestThreshold)
    }

    // MARK: - Stray events and partial sessions

    func testAnUnlockWithNoPrecedingLockIsIgnored() async {
        let clock = ScriptedAwayClock()
        let recorder = Recorder()
        let tracker = makeTracker(clock: clock, recorder: recorder)

        // What login looks like: the unlock arrives, the lock never did.
        await tracker.handle(.screenUnlocked)
        clock.advance(by: AwaySessionTracker.mergeGap + 1)

        let isAway = await tracker.isAway
        XCTAssertFalse(isAway)
        let ended = await recorder.ended
        XCTAssertTrue(ended.isEmpty, "a stray unlock must not manufacture a zero-length session")
    }

    func testBeginPartialOpensAFlaggedSessionAndOnlyWhenIdle() async throws {
        let clock = ScriptedAwayClock()
        let recorder = Recorder()
        let tracker = makeTracker(clock: clock, recorder: recorder)
        let start = clock.now

        await tracker.beginPartial(reason: .locked)
        // A second call while away must not restart the session's clock.
        clock.advance(by: 60)
        await tracker.beginPartial(reason: .asleep)

        clock.advance(by: 600)
        await tracker.handle(.screenUnlocked)
        clock.advance(by: AwaySessionTracker.mergeGap + 1)
        await recorder.wait(for: 1)

        let recorded = await recorder.ended
        let session = try XCTUnwrap(recorded.first)
        XCTAssertTrue(session.isPartial)
        XCTAssertEqual(session.session.startedAt.date, start)
        XCTAssertEqual(session.reasons, [.locked])
    }

    // MARK: - Flush

    func testFlushCommitsAnOpenSessionWithoutWaitingOutTheGap() async throws {
        let clock = ScriptedAwayClock()
        let recorder = Recorder()
        let tracker = makeTracker(clock: clock, recorder: recorder)

        await tracker.handle(.screenLocked)
        clock.advance(by: 600)
        // No unlock at all: this is quit-while-locked.
        await tracker.flush()

        let ended = await recorder.ended
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(try XCTUnwrap(ended.first).session.endedAt?.date, clock.now)

        // Flushing again has nothing left to commit.
        await tracker.flush()
        let after = await recorder.ended
        XCTAssertEqual(after.count, 1)
    }

    // MARK: Private

    /// A threshold the test can change mid-run, to prove `minDuration` is a closure and
    /// not a captured constant.
    private final class MutableThreshold: @unchecked Sendable {
        // MARK: Lifecycle

        init(seconds: TimeInterval) {
            storage = seconds
        }

        // MARK: Internal

        var seconds: TimeInterval {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }

        // MARK: Private

        private let lock = NSLock()
        private var storage: TimeInterval
    }

    private func makeTracker(clock: ScriptedAwayClock, recorder: Recorder) -> AwaySessionTracker {
        AwaySessionTracker(clock: clock) { await recorder.record($0) }
    }
}
