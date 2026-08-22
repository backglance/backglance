import BackglanceTestSupport
@testable import BackglanceUI
import Foundation
import XCTest

// MARK: - SystemSettingsLinkTests

/// Covers the URL ladder in
/// docs/features/ACTIONS.md#open-in-system-settings--notifications: the exact three
/// rungs ``SystemSettingsLink/notificationSettingsURLs(for:)`` builds, and the
/// fallback ordering ``SystemSettingsLink/open(bundleID:)`` tries them in. Reuses
/// ``FakeAppLauncher`` from `OpenActionTests.swift` — same target, same reason: no
/// call here is allowed to reach real `NSWorkspace` and actually open System
/// Settings on the machine running the suite.
@MainActor
final class SystemSettingsLinkTests: XCTestCase {
    // MARK: - notificationSettingsURLs

    func testLadderOrderAndContentsForAPlainBundleID() {
        let urls = SystemSettingsLink.notificationSettingsURLs(for: Stubs.BundleID.slack)

        XCTAssertEqual(urls.map(\.absoluteString), [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Stubs.BundleID.slack)",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ])
    }

    func testBundleIDNeedingPercentEncodingProducesAnEncodedQuery() {
        // A space is not itself illegal in a real bundle id, but it is exactly the
        // kind of character `.urlQueryAllowed` must escape, and it is easy to read
        // in the assertion below.
        let bundleID = "com.example.my app"
        let urls = SystemSettingsLink.notificationSettingsURLs(for: bundleID)

        XCTAssertEqual(
            urls.first?.absoluteString,
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.example.my%20app"
        )
        XCTAssertFalse(
            urls.contains { $0.absoluteString.contains(" ") },
            "the space must not survive unescaped on any rung"
        )
    }

    // MARK: - open(bundleID:)

    func testFirstURLWinningMeansTheOthersAreNeverTried() throws {
        let launcher = FakeAppLauncher()
        launcher.openResult = true

        try SystemSettingsLink(workspace: launcher).open(bundleID: Stubs.BundleID.slack)

        XCTAssertEqual(launcher.calls, try [
            .open(XCTUnwrap(SystemSettingsLink.notificationSettingsURLs(for: Stubs.BundleID.slack).first)),
        ])
    }

    func testFirstTwoRefusedFallsThroughToTheLegacyID() throws {
        let launcher = FakeAppLauncher()
        let urls = SystemSettingsLink.notificationSettingsURLs(for: Stubs.BundleID.slack)
        // Refuse the first two rungs, accept the third (the legacy id).
        launcher.openResults = [urls[0]: false, urls[1]: false, urls[2]: true]

        try SystemSettingsLink(workspace: launcher).open(bundleID: Stubs.BundleID.slack)

        XCTAssertEqual(launcher.calls, urls.map { .open($0) })
    }

    func testAllThreeRefusedThrowsSystemSettingsUnavailable() throws {
        let launcher = FakeAppLauncher()
        launcher.openResult = false

        XCTAssertThrowsError(
            try SystemSettingsLink(workspace: launcher).open(bundleID: Stubs.BundleID.slack)
        ) { error in
            XCTAssertEqual(error as? ActionError, .systemSettingsUnavailable)
        }
        XCTAssertEqual(
            launcher.calls,
            SystemSettingsLink.notificationSettingsURLs(for: Stubs.BundleID.slack).map { .open($0) }
        )
    }
}
