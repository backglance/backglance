@testable import BackglanceCore
import Foundation
import XCTest

/// Covers `DigestPolicy`: the three gates in `allows(reasons:meetsThreshold:)`, the
/// `AwaySessionTracker.EndedSession` convenience, and the settings round trip.
///
/// See docs/features/MISSED_DIGEST.md#never-nagging-rules.
final class DigestPolicyTests: XCTestCase {
    // MARK: Internal

    // MARK: - allows(reasons:meetsThreshold:)

    func testNeverThresholdRefusesEvenASessionThatMetTheThreshold() {
        let policy = DigestPolicy(threshold: .never, disabledReasons: [])
        XCTAssertFalse(policy.allows(reasons: [.locked], meetsThreshold: true))
    }

    func testASessionThatDidNotMeetTheThresholdIsRefused() {
        let policy = DigestPolicy(threshold: .after5min, disabledReasons: [])
        XCTAssertFalse(policy.allows(reasons: [.locked], meetsThreshold: false))
    }

    func testAnEmptyReasonSetIsRefused() {
        let policy = DigestPolicy(threshold: .after5min, disabledReasons: [])
        XCTAssertFalse(policy.allows(reasons: [], meetsThreshold: true))
    }

    func testASessionWhoseReasonsAreAllDisabledIsRefused() {
        let policy = DigestPolicy(threshold: .after5min, disabledReasons: [.focus, .locked])
        XCTAssertFalse(policy.allows(reasons: [.focus, .locked], meetsThreshold: true))
    }

    func testLockingTheLidDuringAFocusIsStillALockSoOnlyFocusDisabledStillAllows() {
        // Only `focus` is disabled; the session also carries `locked`. One allowed
        // reason is enough — someone who switched off Focus digests did not thereby
        // ask to stop hearing about what arrived while their Mac was shut.
        let policy = DigestPolicy(threshold: .after5min, disabledReasons: [.focus])
        XCTAssertTrue(policy.allows(reasons: [.focus, .locked], meetsThreshold: true))
    }

    // MARK: - init(defaults:)

    func testDefaultConstructionFromEmptyDefaultsGivesAfter5MinAndNoDisabledReasons() throws {
        let defaults = try throwawayDefaults()
        let policy = DigestPolicy(defaults: defaults)
        XCTAssertEqual(policy.threshold, .after5min)
        XCTAssertEqual(policy.disabledReasons, [])
    }

    func testSaveDisabledReasonsRoundTripsThroughInitDefaults() throws {
        let defaults = try throwawayDefaults()
        let reasons: Set<AwayReason> = [.focus, .presenting]

        DigestPolicy.save(disabledReasons: reasons, to: defaults)
        let policy = DigestPolicy(defaults: defaults)

        XCTAssertEqual(policy.disabledReasons, reasons)
    }

    func testAnUnrecognisedStoredReasonIsDroppedRatherThanSuppressingEverything() throws {
        let defaults = try throwawayDefaults()
        defaults.set(["bogus", AwayReason.locked.rawValue], forKey: DigestPolicy.disabledReasonsKey)

        let policy = DigestPolicy(defaults: defaults)

        XCTAssertEqual(policy.disabledReasons, [.locked], "the unrecognised entry is dropped, not kept as-is")
        XCTAssertTrue(
            policy.allows(reasons: [.focus], meetsThreshold: true),
            "an unrelated reason must still be allowed, not suppressed by the unreadable entry"
        )
    }

    // MARK: - allows(_ ended:)

    func testAllowsEndedSessionAgreesWithAllowsReasonsAndMeetsThreshold() {
        let session = AwaySession(
            startedAt: UnixDate(base),
            endedAt: UnixDate(base.addingTimeInterval(600)),
            reason: .locked
        )
        let cases: [Case] = [
            Case(threshold: .after5min, disabled: [], reasons: [.locked], meets: true),
            Case(threshold: .after5min, disabled: [], reasons: [.locked], meets: false),
            Case(threshold: .never, disabled: [], reasons: [.locked], meets: true),
            Case(threshold: .after5min, disabled: [.locked], reasons: [.locked], meets: true),
            Case(threshold: .after5min, disabled: [.focus], reasons: [.focus, .locked], meets: true),
            Case(threshold: .after5min, disabled: [], reasons: [], meets: true),
        ]

        for testCase in cases {
            let policy = DigestPolicy(threshold: testCase.threshold, disabledReasons: testCase.disabled)
            let ended = AwaySessionTracker.EndedSession(
                session: session,
                reasons: testCase.reasons,
                isPartial: false,
                isReconstructed: false,
                meetsDigestThreshold: testCase.meets
            )

            XCTAssertEqual(
                policy.allows(ended),
                policy.allows(reasons: testCase.reasons, meetsThreshold: testCase.meets),
                "allows(_:) must be exactly allows(reasons:meetsThreshold:) for the same inputs"
            )
        }
    }

    // MARK: Private

    /// One row of the `allows(_:)` vs. `allows(reasons:meetsThreshold:)` comparison.
    private struct Case {
        let threshold: DigestThreshold
        let disabled: Set<AwayReason>
        let reasons: Set<AwayReason>
        let meets: Bool
    }

    private let base = Date(timeIntervalSince1970: 1_755_600_000)

    private func throwawayDefaults() throws -> UserDefaults {
        let name = "app.backglance.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }
}
