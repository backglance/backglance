@testable import BackglanceCore
import Foundation
import XCTest

/// 🔒 The "off means off" guarantee, asserted rather than believed.
///
/// `SparkleUpdaterController` lives in the app target, which no test bundle can import
/// (BACKGLANCE-238), so the decision it makes was moved here precisely so these cases can
/// be checked. Every `XCTAssertNotEqual(…, .start)` below is one shape of "Backglance made
/// no network request" (docs/security/SECURITY.md#the-updater).
final class UpdaterPolicyTests: XCTestCase {
    // MARK: Internal

    // MARK: - The environment override

    /// `BACKGLANCE_DISABLE_UPDATER=1` wins over everything, including a user-initiated
    /// check in a properly signed build.
    func testEnvironmentOverrideStopsEveryTrigger() {
        for trigger in [UpdaterTrigger.launch, .userInitiated] {
            XCTAssertEqual(
                UpdaterPolicy.decision(
                    trigger: trigger,
                    disableEnvironmentValue: "1",
                    publicEDKey: Self.validKey,
                    automaticChecksEnabled: true
                ),
                .disabledByEnvironment
            )
        }
    }

    /// Only the exact value disables it: an unset variable is the normal case, and "0" or
    /// "true" are not the documented spelling (ASSUMPTIONS.md's environment-override list).
    func testOnlyTheValueOneDisablesTheUpdater() {
        for value in [nil, "", "0", "true", "YES"] {
            XCTAssertEqual(
                UpdaterPolicy.decision(
                    trigger: .launch,
                    disableEnvironmentValue: value,
                    publicEDKey: Self.validKey,
                    automaticChecksEnabled: true
                ),
                .start,
                "unexpected decision for BACKGLANCE_DISABLE_UPDATER=\(value ?? "<unset>")"
            )
        }
    }

    // MARK: - The public key

    /// A Debug build carries `$(SU_PUBLIC_ED_KEY)` resolved to an empty string, not a
    /// missing key — `Backglance/Info.plist` substitutes it unconditionally.
    func testNoUsableKeyMeansNoUpdater() {
        for key in [nil, "", "   ", "\n", UpdaterPolicy.publicKeyPlaceholder] {
            XCTAssertFalse(UpdaterPolicy.hasUsablePublicKey(key))
            XCTAssertEqual(
                UpdaterPolicy.decision(
                    trigger: .userInitiated,
                    disableEnvironmentValue: nil,
                    publicEDKey: key,
                    automaticChecksEnabled: true
                ),
                .noPublicKey,
                "unexpected decision for SUPublicEDKey=\(key ?? "<missing>")"
            )
        }
    }

    /// The placeholder `Config/Release.xcconfig` ships until the keypair exists is not a
    /// key. A build carrying it could not verify a download, so it has no business
    /// fetching one.
    func testTheXcconfigPlaceholderIsNotAKey() {
        XCTAssertFalse(UpdaterPolicy.hasUsablePublicKey(UpdaterPolicy.publicKeyPlaceholder))
        XCTAssertTrue(UpdaterPolicy.hasUsablePublicKey(Self.validKey))
    }

    // MARK: - The user's preference

    /// The guarantee itself: the toggle off at launch means Sparkle is never started, so
    /// it never schedules a check and never opens a connection.
    func testAutomaticChecksOffStopsTheLaunchStart() {
        XCTAssertEqual(
            UpdaterPolicy.decision(
                trigger: .launch,
                disableEnvironmentValue: nil,
                publicEDKey: Self.validKey,
                automaticChecksEnabled: false
            ),
            .automaticChecksOff
        )
    }

    /// Clicking "Check for Updates…" is consent for that one request, so it is allowed
    /// even with automatic checks off.
    func testAManualCheckIgnoresTheAutomaticChecksPreference() {
        XCTAssertEqual(
            UpdaterPolicy.decision(
                trigger: .userInitiated,
                disableEnvironmentValue: nil,
                publicEDKey: Self.validKey,
                automaticChecksEnabled: false
            ),
            .start
        )
    }

    /// The ordinary signed build with the setting left on.
    func testTheConfiguredDefaultStarts() {
        XCTAssertEqual(
            UpdaterPolicy.decision(
                trigger: .launch,
                disableEnvironmentValue: nil,
                publicEDKey: Self.validKey,
                automaticChecksEnabled: true
            ),
            .start
        )
    }

    // MARK: Private

    /// Shaped like a real EdDSA public key — 32 bytes, base64 — but not one: nothing here
    /// verifies a signature, and a fixture that looked like a live key would be the kind of
    /// thing someone later copies into an xcconfig.
    private static let validKey = Data(repeating: 0x2B, count: 32).base64EncodedString()
}
