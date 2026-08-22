@testable import BackglanceCore
import Foundation
import XCTest

/// Covers `RedactionPolicy`: the two settings that decide which apps ``OTPRedactor`` runs
/// on, and the defaults that hold before the user has decided anything.
///
/// See docs/features/PRIVACY_CONTROLS.md#per-app-toggle-and-redact-codes-in-all-apps.
final class RedactionPolicyTests: XCTestCase {
    // MARK: Internal

    // MARK: - Defaults

    /// 🔒 The two apps that carry codes are covered before the user has opened Settings.
    func testMessagesAndMailRedactByDefault() {
        XCTAssertTrue(RedactionPolicy.redactsByDefault(bundleID: "com.apple.MobileSMS"))
        XCTAssertTrue(RedactionPolicy.redactsByDefault(bundleID: "com.apple.mail"))
    }

    func testEverythingElseDoesNotRedactByDefault() {
        XCTAssertFalse(RedactionPolicy.redactsByDefault(bundleID: "com.tinyspeck.slackmacgap"))
        XCTAssertFalse(RedactionPolicy.redactsByDefault(bundleID: "com.apple.Passwords"))
    }

    func testRedactAllAppsIsOffUntilItIsAskedFor() throws {
        let policy = try RedactionPolicy(defaults: throwawayDefaults())
        XCTAssertFalse(policy.redactsAllApps)
    }

    // MARK: - The gate

    func testAnAppWithTheFlagOnIsRedacted() {
        let policy = RedactionPolicy(redactsAllApps: false)
        XCTAssertTrue(policy.redacts(appRedactsOTP: true))
    }

    func testAnAppWithTheFlagOffIsNotRedacted() {
        let policy = RedactionPolicy(redactsAllApps: false)
        XCTAssertFalse(policy.redacts(appRedactsOTP: false))
    }

    /// The global override is an override: it does not consult the per-app flag at all,
    /// which is what "in all apps" has to mean if the pane is telling the truth.
    func testRedactAllAppsCoversAnAppWhoseFlagIsOff() {
        let policy = RedactionPolicy(redactsAllApps: true)
        XCTAssertTrue(policy.redacts(appRedactsOTP: false))
    }

    func testTheGateReadsTheAppRecordsOwnFlag() {
        let app = AppRecord(
            id: 1,
            bundleId: "com.apple.MobileSMS",
            displayName: nil,
            retention: .inherit,
            isExcluded: false,
            isMuted: false,
            redactOtp: true,
            firstSeenAt: UnixDate(Date()),
            lastSeenAt: UnixDate(Date()),
            notificationCount: 0
        )
        XCTAssertTrue(RedactionPolicy(redactsAllApps: false).redacts(app))
    }

    // MARK: - The settings round trip

    func testSavingTheOverrideIsWhatTheNextReadSees() throws {
        let defaults = try throwawayDefaults()
        RedactionPolicy.save(redactsAllApps: true, to: defaults)
        XCTAssertTrue(RedactionPolicy(defaults: defaults).redactsAllApps)

        RedactionPolicy.save(redactsAllApps: false, to: defaults)
        XCTAssertFalse(RedactionPolicy(defaults: defaults).redactsAllApps)
    }

    // MARK: Private

    private func throwawayDefaults() throws -> UserDefaults {
        let name = "app.backglance.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }
}
