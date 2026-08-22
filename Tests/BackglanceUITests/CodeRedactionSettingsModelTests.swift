import BackglanceCore
@testable import BackglanceUI
import Foundation
import XCTest

/// Covers `CodeRedactionSettingsModel`: what the pane lists, what a toggle writes, and
/// the one-time warning that says turning redaction off cannot bring anything back.
///
/// See docs/features/PRIVACY_CONTROLS.md#per-app-toggle-and-redact-codes-in-all-apps.
@MainActor
final class CodeRedactionSettingsModelTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - What the pane lists

    /// 🔒 Messages and Mail are listed, switched on, on a Mac where neither has notified.
    /// A pane that only showed what the archive held would show an empty list here, and
    /// the user would have no way to tell redaction was already running.
    func testTheDefaultsAreListedBeforeEitherHasNotified() async throws {
        let model = try makeModel()

        await model.load()

        XCTAssertEqual(Set(model.rows.map(\.bundleID)), RedactionPolicy.defaultBundleIDs)
        XCTAssertTrue(model.rows.allSatisfy(\.isOn))
    }

    func testCapturedAppsComeFirstAndTheUnseenDefaultsFollow() async throws {
        let archive = try XCTUnwrap(archive)
        try archive.setRedactsOTP(false, bundleID: "com.example.chat")
        let model = try makeModel()

        await model.load()

        XCTAssertEqual(model.rows.first?.bundleID, "com.example.chat")
        XCTAssertEqual(Set(model.rows.dropFirst().map(\.bundleID)), RedactionPolicy.defaultBundleIDs)
    }

    /// An app the user switched off is listed off — the row reports the archive rather
    /// than the shipped default it no longer has.
    func testAnAppSwitchedOffIsListedOff() async throws {
        let model = try makeModel()
        await model.load()

        await model.setRedaction(false, forBundleID: "com.apple.MobileSMS")

        let messages = try XCTUnwrap(model.rows.first { $0.bundleID == "com.apple.MobileSMS" })
        XCTAssertFalse(messages.isOn)
        XCTAssertFalse(try XCTUnwrap(archive).redactsOTP(bundleID: "com.apple.MobileSMS"))
    }

    /// A model with no archive shows nothing and writes nothing, rather than offering
    /// toggles that would silently do neither.
    func testWithoutAnArchiveNothingIsListed() async throws {
        let model = try CodeRedactionSettingsModel(archive: nil, defaults: throwawayDefaults())

        await model.load()
        await model.setRedaction(false, forBundleID: "com.apple.MobileSMS")

        XCTAssertTrue(model.rows.isEmpty)
    }

    // MARK: - Adding an app by bundle identifier

    func testAddingABundleIDCreatesARowWithRedactionOn() async throws {
        let model = try makeModel()
        await model.load()
        model.pendingBundleID = "  com.example.bank  "

        await model.addPendingBundleID()

        XCTAssertTrue(model.pendingBundleID.isEmpty)
        let added = try XCTUnwrap(model.rows.first { $0.bundleID == "com.example.bank" })
        XCTAssertTrue(added.isOn)
        XCTAssertEqual(added.notificationCount, 0)
    }

    func testSomethingThatIsNotABundleIDCannotBeAdded() async throws {
        let model = try makeModel()
        await model.load()

        model.pendingBundleID = "Messages"
        XCTAssertFalse(model.canAddPendingBundleID)

        model.pendingBundleID = "com example app"
        XCTAssertFalse(model.canAddPendingBundleID)
    }

    func testAnAppAlreadyInTheListCannotBeAddedTwice() async throws {
        let model = try makeModel()
        await model.load()

        model.pendingBundleID = "com.apple.MobileSMS"

        XCTAssertFalse(model.canAddPendingBundleID)
    }

    // MARK: - The global override

    func testTheOverrideIsWrittenStraightThrough() throws {
        let defaults = try throwawayDefaults()
        let model = CodeRedactionSettingsModel(archive: archive, defaults: defaults)

        model.redactsAllApps = true

        XCTAssertTrue(RedactionPolicy(defaults: defaults).redactsAllApps)
    }

    // MARK: - The plain-text warning

    /// Once, not on every toggle — and only for an app that shipped with redaction on,
    /// because switching off one you switched on yourself is not news.
    func testSwitchingOffADefaultWarnsOnceAndThenNeverAgain() async throws {
        let model = try makeModel()
        await model.load()

        await model.setRedaction(false, forBundleID: "com.apple.MobileSMS")
        XCTAssertEqual(model.plainTextWarningBundleID, "com.apple.MobileSMS")
        model.dismissPlainTextWarning()

        await model.setRedaction(false, forBundleID: "com.apple.mail")
        XCTAssertNil(model.plainTextWarningBundleID)
    }

    func testTheWarningSurvivesARelaunch() async throws {
        let defaults = try throwawayDefaults()
        let first = CodeRedactionSettingsModel(archive: archive, defaults: defaults)
        await first.setRedaction(false, forBundleID: "com.apple.MobileSMS")
        XCTAssertNotNil(first.plainTextWarningBundleID)

        let second = CodeRedactionSettingsModel(archive: archive, defaults: defaults)
        await second.setRedaction(false, forBundleID: "com.apple.mail")

        XCTAssertNil(second.plainTextWarningBundleID)
    }

    func testSwitchingOffAnAppTheUserAddedDoesNotWarn() async throws {
        let model = try makeModel()
        model.pendingBundleID = "com.example.bank"
        await model.addPendingBundleID()

        await model.setRedaction(false, forBundleID: "com.example.bank")

        XCTAssertNil(model.plainTextWarningBundleID)
    }

    // MARK: Private

    private var archive: Archive?

    private func makeModel() throws -> CodeRedactionSettingsModel {
        try CodeRedactionSettingsModel(archive: XCTUnwrap(archive), defaults: throwawayDefaults())
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
