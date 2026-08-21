import BackglanceCore
@testable import BackglanceUI
import Foundation
import XCTest

/// Covers `DigestSettingsModel`: reading the five stored settings at init, writing each
/// straight through to `UserDefaults` on change (there is no "apply" step), and the
/// authorization dance around `bannerEnabled` — which is the one setting that can be
/// switched back off by something other than the user.
///
/// See docs/features/MISSED_DIGEST.md#the-local-notification-banner and
/// docs/features/PERMISSIONS_PRIVACY.md#notifications-backglances-own-local-notifications.
@MainActor
final class DigestSettingsModelTests: XCTestCase {
    // MARK: Internal

    // MARK: - init(defaults:)

    func testInitReadsExistingStoredValues() throws {
        let defaults = try throwawayDefaults()
        DigestThreshold.save(.after15min, to: defaults)
        DigestPolicy.save(disabledReasons: [.focus, .presenting], to: defaults)
        defaults.set(true, forKey: DigestBannerPolicy.enabledKey)
        defaults.set(true, forKey: DigestBannerPolicy.focusKey)
        defaults.set(true, forKey: DigestBannerPolicy.soundKey)

        let model = DigestSettingsModel(defaults: defaults)

        XCTAssertEqual(model.threshold, .after15min)
        XCTAssertEqual(model.disabledReasons, [.focus, .presenting])
        XCTAssertTrue(model.bannerEnabled)
        XCTAssertTrue(model.bannerForFocus)
        XCTAssertTrue(model.bannerSound)
    }

    func testInitOnAnEmptySuiteGivesTheDefaults() throws {
        let defaults = try throwawayDefaults()

        let model = DigestSettingsModel(defaults: defaults)

        XCTAssertEqual(model.threshold, .after5min)
        XCTAssertEqual(model.disabledReasons, [])
        XCTAssertFalse(model.bannerEnabled)
        XCTAssertFalse(model.bannerForFocus)
        XCTAssertFalse(model.bannerSound)
    }

    // MARK: - threshold

    func testSettingThresholdWritesThroughImmediatelyWithNoApplyStep() throws {
        let defaults = try throwawayDefaults()
        let model = DigestSettingsModel(defaults: defaults)

        model.threshold = .after15min

        XCTAssertEqual(defaults.string(forKey: DigestThreshold.defaultsKey), DigestThreshold.after15min.rawValue)
    }

    // MARK: - setCounts(_:for:) / counts(_:)

    func testSetCountsFalseDisablesAReasonAndTrueReenablesIt() throws {
        let defaults = try throwawayDefaults()
        let model = DigestSettingsModel(defaults: defaults)
        XCTAssertTrue(model.counts(.focus))

        model.setCounts(false, for: .focus)

        XCTAssertTrue(model.disabledReasons.contains(.focus))
        XCTAssertFalse(model.counts(.focus))
        XCTAssertEqual(defaults.stringArray(forKey: DigestPolicy.disabledReasonsKey), [AwayReason.focus.rawValue])

        model.setCounts(true, for: .focus)

        XCTAssertFalse(model.disabledReasons.contains(.focus))
        XCTAssertTrue(model.counts(.focus))
        XCTAssertEqual(defaults.stringArray(forKey: DigestPolicy.disabledReasonsKey), [])
    }

    // MARK: - bannerForFocus / bannerSound

    func testBannerForFocusWritesThroughOnChange() throws {
        let defaults = try throwawayDefaults()
        let model = DigestSettingsModel(defaults: defaults)

        model.bannerForFocus = true

        XCTAssertTrue(defaults.bool(forKey: DigestBannerPolicy.focusKey))
    }

    func testBannerSoundWritesThroughOnChange() throws {
        let defaults = try throwawayDefaults()
        let model = DigestSettingsModel(defaults: defaults)

        model.bannerSound = true

        XCTAssertTrue(defaults.bool(forKey: DigestBannerPolicy.soundKey))
    }

    // MARK: - bannerEnabled: requesting authorization

    func testEnablingBannersWithAnAuthorizedGrantKeepsTheToggleOn() async throws {
        let defaults = try throwawayDefaults()
        let model = DigestSettingsModel(
            defaults: defaults,
            authorization: BannerAuthorizing(read: { .notDetermined }, request: { .authorized })
        )

        model.bannerEnabled = true
        // The request is kicked off from `bannerEnabled`'s didSet inside an unstructured
        // Task, which races the assertions below. Calling authorizeBannersIfNeeded()
        // directly makes the outcome deterministic instead of sleeping/yielding for that
        // Task to be scheduled.
        await model.authorizeBannersIfNeeded()

        XCTAssertTrue(model.bannerEnabled)
        XCTAssertEqual(model.bannerAuthorization, .authorized)
        XCTAssertTrue(defaults.bool(forKey: DigestBannerPolicy.enabledKey))
    }

    func testEnablingBannersWithADeniedGrantTurnsTheToggleBackOff() async throws {
        // "a toggle that stayed on while nothing could be delivered would be a lie" —
        // the doc comment on authorizeBannersIfNeeded().
        let defaults = try throwawayDefaults()
        let model = DigestSettingsModel(
            defaults: defaults,
            authorization: BannerAuthorizing(read: { .notDetermined }, request: { .denied })
        )

        model.bannerEnabled = true
        await model.authorizeBannersIfNeeded()

        XCTAssertFalse(model.bannerEnabled)
        XCTAssertEqual(model.bannerAuthorization, .denied)
        XCTAssertFalse(defaults.bool(forKey: DigestBannerPolicy.enabledKey))
    }

    func testEnablingBannersWithNoNotificationCentreWiredTurnsTheToggleBackOff() async throws {
        let defaults = try throwawayDefaults()
        let model = DigestSettingsModel(defaults: defaults)

        model.bannerEnabled = true
        await model.authorizeBannersIfNeeded()

        XCTAssertFalse(model.bannerEnabled)
        XCTAssertFalse(defaults.bool(forKey: DigestBannerPolicy.enabledKey))
    }

    func testDisablingBannersNeverRequestsAuthorization() async throws {
        let defaults = try throwawayDefaults()
        defaults.set(true, forKey: DigestBannerPolicy.enabledKey)
        let recorder = CallRecorder()
        let model = DigestSettingsModel(
            defaults: defaults,
            authorization: BannerAuthorizing(
                read: { .notDetermined },
                request: {
                    await recorder.record()
                    return .authorized
                }
            )
        )
        XCTAssertTrue(model.bannerEnabled)

        model.bannerEnabled = false
        // Switching off spawns no Task in the first place (didSet returns before it would
        // be created), but yield once anyway so a wrongly-scheduled one would have had a
        // chance to run before we check the recorder.
        await Task.yield()

        let calls = await recorder.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(defaults.bool(forKey: DigestBannerPolicy.enabledKey))
    }

    // MARK: - refreshAuthorization()

    func testRefreshAuthorizationDeniedSwitchesAnEnabledBannerBackOff() async throws {
        let defaults = try throwawayDefaults()
        defaults.set(true, forKey: DigestBannerPolicy.enabledKey)
        let model = DigestSettingsModel(
            defaults: defaults,
            authorization: BannerAuthorizing(read: { .denied }, request: { .denied })
        )
        XCTAssertTrue(model.bannerEnabled)

        await model.refreshAuthorization()

        XCTAssertEqual(model.bannerAuthorization, .denied)
        XCTAssertFalse(model.bannerEnabled)
        XCTAssertFalse(defaults.bool(forKey: DigestBannerPolicy.enabledKey))
    }

    func testRefreshAuthorizationNotDeterminedLeavesAnEnabledBannerAlone() async throws {
        let defaults = try throwawayDefaults()
        defaults.set(true, forKey: DigestBannerPolicy.enabledKey)
        let model = DigestSettingsModel(
            defaults: defaults,
            authorization: BannerAuthorizing(read: { .notDetermined }, request: { .notDetermined })
        )
        XCTAssertTrue(model.bannerEnabled)

        await model.refreshAuthorization()

        XCTAssertEqual(model.bannerAuthorization, .notDetermined)
        XCTAssertTrue(model.bannerEnabled, "only .denied revokes; .notDetermined must not touch the toggle")
        XCTAssertTrue(defaults.bool(forKey: DigestBannerPolicy.enabledKey))
    }

    // MARK: - isDigestDisabled / canRequestBanners

    func testIsDigestDisabledIsTrueOnlyForNever() throws {
        let defaults = try throwawayDefaults()
        let model = DigestSettingsModel(defaults: defaults)

        for threshold in DigestThreshold.allCases {
            model.threshold = threshold
            XCTAssertEqual(model.isDigestDisabled, threshold == .never, "for \(threshold)")
        }
    }

    func testCanRequestBannersIsFalseOnlyForDenied() async throws {
        for (status, expected) in [
            (BannerAuthorization.notDetermined, true),
            (BannerAuthorization.authorized, true),
            (BannerAuthorization.denied, false),
        ] {
            let defaults = try throwawayDefaults()
            let model = DigestSettingsModel(
                defaults: defaults,
                authorization: BannerAuthorizing(read: { status }, request: { status })
            )

            await model.refreshAuthorization()

            XCTAssertEqual(model.canRequestBanners, expected, "for \(status)")
        }
    }

    // MARK: Private

    /// Counts calls to a closure without touching any actor the closure itself might run
    /// on — the closures `DigestSettingsModel` is given are `@Sendable`.
    private actor CallRecorder {
        private(set) var callCount = 0

        func record() {
            callCount += 1
        }
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
