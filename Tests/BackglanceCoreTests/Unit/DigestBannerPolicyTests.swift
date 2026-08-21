@testable import BackglanceCore
import Foundation
import XCTest

/// Covers `DigestBannerPolicy`: the settings defaults, the gates in `allowsBanner`, and
/// the popover grace window.
///
/// See docs/features/MISSED_DIGEST.md#the-local-notification-banner.
final class DigestBannerPolicyTests: XCTestCase {
    // MARK: Internal

    // MARK: - init(defaults:)

    func testAllThreeSettingsDefaultToFalseFromAnEmptyDefaultsSuite() throws {
        // This is the permission rule, not timidity: a banner that defaulted on would
        // have to request Notifications authorization on its own behalf the first time
        // a session ended. The popover, which needs no permission, is the default
        // presentation instead.
        let defaults = try throwawayDefaults()
        let policy = DigestBannerPolicy(defaults: defaults)

        XCTAssertFalse(policy.isEnabled)
        XCTAssertFalse(policy.includesFocus)
        XCTAssertFalse(policy.playsSound)
    }

    // MARK: - allowsBanner: isEnabled / isAuthorized gates

    func testAllowsBannerIsFalseWhenNotEnabledEvenWithEverythingElseTrue() {
        let policy = DigestBannerPolicy(isEnabled: false, includesFocus: true, playsSound: true)

        XCTAssertFalse(policy.allowsBanner(
            reason: .locked,
            sessionEndedAt: base,
            popoverLastOpenedAt: nil,
            isAuthorized: true
        ))
    }

    func testAllowsBannerIsFalseWhenNotAuthorizedEvenWithEverythingElseTrue() {
        let policy = DigestBannerPolicy(isEnabled: true, includesFocus: true, playsSound: true)

        XCTAssertFalse(policy.allowsBanner(
            reason: .locked,
            sessionEndedAt: base,
            popoverLastOpenedAt: nil,
            isAuthorized: false
        ))
    }

    // MARK: - allowsBanner: the Focus gate

    func testFocusIsRefusedWhenNotIncludedButEveryOtherReasonIsAllowed() {
        let policy = DigestBannerPolicy(isEnabled: true, includesFocus: false)

        for reason in AwayReason.allCases {
            let allowed = policy.allowsBanner(
                reason: reason,
                sessionEndedAt: base,
                popoverLastOpenedAt: nil,
                isAuthorized: true
            )
            if reason == .focus {
                XCTAssertFalse(allowed, "focus must be refused when includesFocus is false")
            } else {
                XCTAssertTrue(allowed, "\(reason) must still be allowed under the same policy")
            }
        }
    }

    func testFocusIsAllowedWhenIncludesFocusIsTrue() {
        let policy = DigestBannerPolicy(isEnabled: true, includesFocus: true)

        XCTAssertTrue(policy.allowsBanner(
            reason: .focus,
            sessionEndedAt: base,
            popoverLastOpenedAt: nil,
            isAuthorized: true
        ))
    }

    // MARK: - allowsBanner: the popover grace window

    func testPopoverOpenedExactlyAtSessionEndRefusesTheBanner() {
        XCTAssertFalse(allows(popoverLastOpenedAt: base))
    }

    func testPopoverOpenedTwentyNineSecondsAfterEndRefusesTheBanner() {
        XCTAssertFalse(allows(popoverLastOpenedAt: base.addingTimeInterval(29)))
    }

    func testPopoverOpenedAtExactlyTheGraceBoundaryRefusesTheBanner() {
        // The boundary is inclusive: `popoverGrace` itself still counts as "already looked".
        XCTAssertFalse(allows(popoverLastOpenedAt: base.addingTimeInterval(DigestBannerPolicy.popoverGrace)))
    }

    func testPopoverOpenedThirtyOneSecondsAfterEndAllowsTheBanner() {
        // They looked later, at something else — this open is not about this digest.
        XCTAssertTrue(allows(popoverLastOpenedAt: base.addingTimeInterval(31)))
    }

    func testPopoverOpenedBeforeTheSessionEndedAllowsTheBanner() {
        // An open from before they left is not looking at this digest, so it does not count.
        XCTAssertTrue(allows(popoverLastOpenedAt: base.addingTimeInterval(-60)))
    }

    func testPopoverNeverOpenedAllowsTheBanner() {
        XCTAssertTrue(allows(popoverLastOpenedAt: nil))
    }

    // MARK: - allowsBanner: playsSound does not affect the decision

    func testPlaysSoundDoesNotAffectAllowsBanner() {
        // `playsSound` only decides `content.sound` at the posting site — it is not a gate.
        let withoutSound = DigestBannerPolicy(isEnabled: true, includesFocus: true, playsSound: false)
        let withSound = DigestBannerPolicy(isEnabled: true, includesFocus: true, playsSound: true)

        XCTAssertEqual(
            withoutSound.allowsBanner(
                reason: .locked,
                sessionEndedAt: base,
                popoverLastOpenedAt: nil,
                isAuthorized: true
            ),
            withSound.allowsBanner(
                reason: .locked,
                sessionEndedAt: base,
                popoverLastOpenedAt: nil,
                isAuthorized: true
            )
        )
    }

    // MARK: - the stored vocabulary

    func testStoredKeysAreExactlyTheDigestBannerVocabulary() {
        // These strings are the archive/defaults vocabulary — changing one silently
        // resets a user's setting rather than migrating it.
        XCTAssertEqual(DigestBannerPolicy.enabledKey, "digest.banner.enabled")
        XCTAssertEqual(DigestBannerPolicy.focusKey, "digest.banner.focus")
        XCTAssertEqual(DigestBannerPolicy.soundKey, "digest.banner.sound")
    }

    // MARK: Private

    private let base = Date(timeIntervalSince1970: 1_755_600_000)

    /// `allowsBanner` for a fully-enabled, non-Focus session, varying only when the
    /// popover was last opened. Isolates the grace-window arithmetic from the other gates.
    private func allows(popoverLastOpenedAt: Date?) -> Bool {
        let policy = DigestBannerPolicy(isEnabled: true, includesFocus: true)
        return policy.allowsBanner(
            reason: .locked,
            sessionEndedAt: base,
            popoverLastOpenedAt: popoverLastOpenedAt,
            isAuthorized: true
        )
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
