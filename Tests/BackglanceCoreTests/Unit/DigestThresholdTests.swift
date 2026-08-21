@testable import BackglanceCore
import Foundation
import XCTest

/// Covers the digest threshold from
/// docs/features/MISSED_DIGEST.md#session-merging-and-thresholds and its Settings row.
///
/// The merge gap itself is a constant of the state machine and is covered by
/// `AwaySessionTrackerTests`; what is tested here is the part the user can change, and
/// the promise in "Never Nagging Rules" #7 that never means never.
final class DigestThresholdTests: XCTestCase {
    // MARK: Internal

    // MARK: - Durations

    func testEachThresholdMapsToTheDocumentedDuration() {
        XCTAssertEqual(DigestThreshold.always.minimumDuration, 0)
        XCTAssertEqual(DigestThreshold.after5min.minimumDuration, 300)
        XCTAssertEqual(DigestThreshold.after15min.minimumDuration, 900)
    }

    func testNeverIsNotADurationAnyoneCanOutlast() {
        // Rule 7: "never" means never, not "after a very long time".
        let never = DigestThreshold.never.minimumDuration
        XCTAssertFalse(TimeInterval(60 * 60 * 24 * 365) >= never)
        XCTAssertFalse(TimeInterval.greatestFiniteMagnitude >= never)
        XCTAssertTrue(DigestThreshold.never.isDisabled)
        XCTAssertFalse(DigestThreshold.after15min.isDisabled)
    }

    // MARK: - Storage

    func testTheStoredVocabularyIsTheDocumentedOne() {
        // These strings are in a preference file on people's Macs; changing one silently
        // resets their choice.
        XCTAssertEqual(
            Set(DigestThreshold.allCases.map(\.rawValue)),
            ["always", "after5min", "after15min", "never"]
        )
        XCTAssertEqual(DigestThreshold.defaultsKey, "digest.threshold")
    }

    func testAnUnsetPreferenceIsFiveMinutes() throws {
        let defaults = try throwawayDefaults()
        XCTAssertEqual(DigestThreshold(defaults: defaults), .after5min)
    }

    func testAChoiceRoundTrips() throws {
        let defaults = try throwawayDefaults()
        for threshold in DigestThreshold.allCases {
            DigestThreshold.save(threshold, to: defaults)
            XCTAssertEqual(DigestThreshold(defaults: defaults), threshold)
        }
    }

    func testAValueFromANewerBuildFallsBackRatherThanRefusing() throws {
        let defaults = try throwawayDefaults()
        defaults.set("after30min", forKey: DigestThreshold.defaultsKey)
        XCTAssertEqual(DigestThreshold(defaults: defaults), .after5min)
    }

    // MARK: - What the tracker reads

    func testTheClosureIsReadPerCallSoAChangeTakesEffectWithoutARebuild() throws {
        let defaults = try throwawayDefaults()
        let minDuration = DigestThreshold.minDuration(reading: defaults)

        XCTAssertEqual(minDuration(), 300)
        DigestThreshold.save(.after15min, to: defaults)
        XCTAssertEqual(minDuration(), 900, "the tracker must see the new setting, not the one at build time")
        DigestThreshold.save(.always, to: defaults)
        XCTAssertEqual(minDuration(), 0)
    }

    // MARK: - End to end through the tracker

    func testAShortSessionIsRecordedButEarnsNoDigestUnderTheDefault() async throws {
        let defaults = try throwawayDefaults()
        let outcome = try await endSession(lasting: 120, defaults: defaults)
        XCTAssertFalse(outcome.meetsDigestThreshold)
        XCTAssertNotNil(outcome.session.endedAt, "a below-threshold session is still a recorded session")
    }

    func testTheSameSessionEarnsADigestUnderAlways() async throws {
        let defaults = try throwawayDefaults()
        DigestThreshold.save(.always, to: defaults)
        let outcome = try await endSession(lasting: 120, defaults: defaults)
        XCTAssertTrue(outcome.meetsDigestThreshold)
    }

    func testNoSessionEverEarnsADigestUnderNever() async throws {
        let defaults = try throwawayDefaults()
        DigestThreshold.save(.never, to: defaults)
        let outcome = try await endSession(lasting: 60 * 60 * 24, defaults: defaults)
        XCTAssertFalse(outcome.meetsDigestThreshold, "a full day away must still produce no digest")
        XCTAssertNotNil(outcome.session.endedAt, "and must still be recorded, so is:missed keeps working")
    }

    // MARK: Private

    /// Collects the one session these cases produce.
    private actor Recorder {
        // MARK: Internal

        private(set) var ended: [AwaySessionTracker.EndedSession] = []

        func record(_ session: AwaySessionTracker.EndedSession) {
            ended.append(session)
            continuations.forEach { $0.resume() }
            continuations.removeAll()
        }

        func waitForOne() async {
            while ended.isEmpty {
                await withCheckedContinuation { continuations.append($0) }
            }
        }

        // MARK: Private

        private var continuations: [CheckedContinuation<Void, Never>] = []
    }

    /// A clock the test drives, matching `AwaySessionTrackerTests`.
    private final class ScriptedAwayClock: AwayClock, @unchecked Sendable {
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
        private var instant = Date(timeIntervalSince1970: 1_767_225_600)
    }

    /// Runs one lock/unlock of the given length through a real tracker wired to the real
    /// setting, and returns what came out.
    private func endSession(
        lasting duration: TimeInterval,
        defaults: UserDefaults
    ) async throws -> AwaySessionTracker.EndedSession {
        let clock = ScriptedAwayClock()
        let recorder = Recorder()
        let tracker = AwaySessionTracker(
            clock: clock,
            minDuration: DigestThreshold.minDuration(reading: defaults)
        ) { await recorder.record($0) }

        await tracker.handle(.screenLocked)
        clock.advance(by: duration)
        await tracker.handle(.screenUnlocked)
        clock.advance(by: AwaySessionTracker.mergeGap + 1)
        await recorder.waitForOne()

        let ended = await recorder.ended
        return try XCTUnwrap(ended.first)
    }

    private func throwawayDefaults() throws -> UserDefaults {
        let name = "app.backglance.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }
}
