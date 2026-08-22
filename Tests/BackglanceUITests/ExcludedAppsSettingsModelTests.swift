import BackglanceCore
@testable import BackglanceUI
import Foundation
import XCTest

/// Covers `ExcludedAppsSettingsModel`: what the pane lists, what "add" and "remove" write,
/// and what "restore defaults" does and does not undo.
///
/// See docs/features/PRIVACY_CONTROLS.md#exclusion-list.
@MainActor
final class ExcludedAppsSettingsModelTests: XCTestCase {
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

    /// 🔒 The shipped defaults are listed on a fresh archive, before any of them has ever
    /// notified. A pane that only showed what the archive held would show an empty list,
    /// and the user would have no way to tell a password manager was already excluded.
    func testTheShippedDefaultsAreListedOnAFreshArchive() async throws {
        let model = try makeModel()

        await model.load()

        XCTAssertEqual(Set(model.rows.map(\.bundleID)), ExclusionList.shippedDefaultBundleIDs)
        XCTAssertTrue(model.rows.allSatisfy(\.isShippedDefault))
    }

    /// A shipped default carries the reason it ships excluded, so the row can say why
    /// rather than just that.
    func testAShippedDefaultCarriesItsReason() async throws {
        let model = try makeModel()

        await model.load()

        let onePassword = try XCTUnwrap(model.rows.first { $0.bundleID == "com.1password.1password" })
        XCTAssertEqual(onePassword.reason, .passwordManager)

        let backglance = try XCTUnwrap(model.rows.first { $0.bundleID == "app.backglance.Backglance" })
        XCTAssertEqual(backglance.reason, .ownNotifications)
    }

    /// An app that is not excluded does not appear — this pane is the list of exclusions,
    /// not a list of every app the archive knows about.
    func testAnAppThatIsNotExcludedIsNotListed() async throws {
        let archive = try XCTUnwrap(archive)
        try archive.setRedactsOTP(true, bundleID: "com.example.chat")
        let model = try makeModel()

        await model.load()

        XCTAssertFalse(model.rows.contains { $0.bundleID == "com.example.chat" })
    }

    /// A model with no archive shows nothing and writes nothing, rather than offering
    /// controls that would silently do neither.
    func testWithoutAnArchiveNothingIsListed() async {
        let model = ExcludedAppsSettingsModel(archive: nil)

        await model.load()
        await model.exclude(bundleID: "com.example.bank")

        XCTAssertTrue(model.rows.isEmpty)
    }

    // MARK: - Removing a default

    /// 🔒 Removing a shipped default drops it from the list and writes `is_excluded = 0` —
    /// the row's `0` outranks the code's default, which is what makes "you may remove any
    /// of these" true rather than merely stated.
    func testRemovingADefaultDropsItFromTheListAndWritesIsExcludedFalse() async throws {
        let model = try makeModel()
        await model.load()

        await model.remove(bundleID: "com.1password.1password")

        XCTAssertFalse(model.rows.contains { $0.bundleID == "com.1password.1password" })
        let archive = try XCTUnwrap(archive)
        let apps = try archive.allApps()
        let onePassword = try XCTUnwrap(apps.first { $0.bundleId == "com.1password.1password" })
        XCTAssertFalse(onePassword.isExcluded)
    }

    // MARK: - Adding an app by bundle identifier

    func testAddingABundleIDListsItExcluded() async throws {
        let model = try makeModel()
        await model.load()
        model.pendingBundleID = "  com.example.bank  "

        await model.addPendingBundleID()

        XCTAssertTrue(model.pendingBundleID.isEmpty)
        let added = try XCTUnwrap(model.rows.first { $0.bundleID == "com.example.bank" })
        XCTAssertFalse(added.isShippedDefault)
        XCTAssertNil(added.reason)
        XCTAssertEqual(added.notificationCount, 0)
    }

    func testSomethingThatIsNotABundleIDCannotBeAdded() async throws {
        let model = try makeModel()
        await model.load()

        model.pendingBundleID = "Bank"
        XCTAssertFalse(model.canAddPendingBundleID)

        model.pendingBundleID = "com example app"
        XCTAssertFalse(model.canAddPendingBundleID)
    }

    func testAnAppAlreadyExcludedCannotBeAddedTwice() async throws {
        let model = try makeModel()
        await model.load()

        model.pendingBundleID = "com.1password.1password"

        XCTAssertFalse(model.canAddPendingBundleID)
    }

    // MARK: - Restoring defaults

    /// "Restore defaults" undoes exactly the removed defaults and leaves a user-added app
    /// excluded — restoring the defaults is not the same as forgetting what the user asked
    /// for on top of them.
    func testRestoringDefaultsPutsBackOnlyRemovedDefaultsAndLeavesAUserAddedAppExcluded() async throws {
        let model = try makeModel()
        await model.load()
        await model.remove(bundleID: "com.1password.1password")
        model.pendingBundleID = "com.example.bank"
        await model.addPendingBundleID()

        await model.restoreDefaults()

        XCTAssertTrue(model.rows.contains { $0.bundleID == "com.1password.1password" })
        XCTAssertTrue(model.rows.contains { $0.bundleID == "com.example.bank" })
    }

    // MARK: Private

    private var archive: Archive?

    private func makeModel() throws -> ExcludedAppsSettingsModel {
        try ExcludedAppsSettingsModel(archive: XCTUnwrap(archive))
    }
}
