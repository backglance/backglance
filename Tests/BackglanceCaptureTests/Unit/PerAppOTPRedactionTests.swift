@testable import BackglanceCapture
import BackglanceCore
import Foundation
import XCTest

/// Covers `PerAppOTPRedaction` — the gate that decides which apps `OTPRedactor` runs on.
///
/// The matcher itself is `OTPRedactorTests`' subject; what these assert is only *whether*
/// it ran, which is the part the two settings control.
///
/// See docs/features/PRIVACY_CONTROLS.md#per-app-toggle-and-redact-codes-in-all-apps.
final class PerAppOTPRedactionTests: XCTestCase {
    // MARK: Internal

    // MARK: - The per-app flag

    /// 🔒 An app the user has redaction on for loses the digits before anything is
    /// written, and the audit row says only which pattern fired.
    func testAnAppWithTheFlagOnHasItsCodeReplaced() throws {
        let redaction = try PerAppOTPRedaction(defaults: throwawayDefaults())

        let (redacted, event) = redaction.redact(Self.codeNotification, appRedactsOTP: true)

        XCTAssertEqual(redacted.body, "Your verification code is [code redacted]")
        XCTAssertNotNil(event)
        XCTAssertFalse(try XCTUnwrap(event?.patternId).isEmpty)
    }

    /// The value the engine goes on to insert is the receiver, untouched — not a copy
    /// that happens to look the same. A gate that redacted anyway and discarded the
    /// result would pass a weaker assertion than this one.
    func testAnAppWithTheFlagOffIsArchivedAsItArrived() throws {
        let redaction = try PerAppOTPRedaction(defaults: throwawayDefaults())

        let (redacted, event) = redaction.redact(Self.codeNotification, appRedactsOTP: false)

        XCTAssertEqual(redacted.body, Self.codeNotification.body)
        XCTAssertEqual(redacted.title, Self.codeNotification.title)
        XCTAssertNil(event)
    }

    // MARK: - "Redact codes in all apps"

    func testTheGlobalOverrideCoversAnAppWhoseFlagIsOff() throws {
        let defaults = try throwawayDefaults()
        RedactionPolicy.save(redactsAllApps: true, to: defaults)
        let redaction = PerAppOTPRedaction(defaults: defaults)

        let (redacted, event) = redaction.redact(Self.codeNotification, appRedactsOTP: false)

        XCTAssertEqual(redacted.body, "Your verification code is [code redacted]")
        XCTAssertNotNil(event)
    }

    /// The setting is read per notification, not captured when the redactor was built, so
    /// switching the override on covers the next notification rather than the next launch.
    func testSwitchingTheOverrideOnTakesEffectOnTheNextNotification() throws {
        let defaults = try throwawayDefaults()
        let redaction = PerAppOTPRedaction(defaults: defaults)
        XCTAssertNil(redaction.redact(Self.codeNotification, appRedactsOTP: false).1)

        RedactionPolicy.save(redactsAllApps: true, to: defaults)

        XCTAssertNotNil(redaction.redact(Self.codeNotification, appRedactsOTP: false).1)
    }

    /// A notification with no code in it comes back untouched even where redaction is on,
    /// and writes no audit row — the row means "a code was removed", not "we looked".
    func testAnAppWithTheFlagOnButNoCodeIsUntouched() throws {
        let redaction = try PerAppOTPRedaction(defaults: throwawayDefaults())
        let plain = ParsedNotification(
            bundleID: "com.apple.MobileSMS",
            uuid: UUID(),
            title: "Ayşe",
            body: "See you at the café",
            deliveredAt: Date(),
            presented: true
        )

        let (redacted, event) = redaction.redact(plain, appRedactsOTP: true)

        XCTAssertEqual(redacted.body, plain.body)
        XCTAssertNil(event)
    }

    // MARK: Private

    private static let codeNotification = ParsedNotification(
        bundleID: "com.apple.MobileSMS",
        uuid: UUID(),
        title: "Bank",
        body: "Your verification code is 449021",
        deliveredAt: Date(),
        presented: true
    )

    private func throwawayDefaults() throws -> UserDefaults {
        let name = "app.backglance.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }
}
