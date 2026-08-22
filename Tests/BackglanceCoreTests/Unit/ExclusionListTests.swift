@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

/// Covers `ExclusionList` — the two layers, which one wins, and what "restore defaults"
/// is allowed to touch.
///
/// 🔒 Privacy Invariant #3. This file is about *what* is excluded; that the check runs
/// before a payload is decoded is asserted in `CaptureEnginePipelineTests`, because it is
/// a fact about the pipeline rather than about this type.
///
/// See docs/features/PRIVACY_CONTROLS.md#defaults.
final class ExclusionListTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - The shipped defaults

    /// 🔒 The list the app ships with, named rather than counted, because a default
    /// silently dropping out of it is the failure that would never be noticed.
    func testTheShippedDefaultsAreTheSevenFromTheDocument() {
        XCTAssertEqual(ExclusionList.shippedDefaultBundleIDs, [
            "com.1password.1password",
            "com.agilebits.onepassword7",
            "com.bitwarden.desktop",
            "com.dashlane.Dashlane",
            "com.lastpass.LastPass",
            "com.apple.Passwords",
            "app.backglance.Backglance",
        ])
    }

    func testEveryPasswordManagerIsExcludedBeforeTheUserDecidesAnything() {
        let list = ExclusionList()

        for entry in ExclusionList.shippedDefaults where entry.reason == .passwordManager {
            XCTAssertTrue(list.excludes(entry.bundleID), entry.bundleID)
        }
    }

    /// Backglance's own banners are on the list for a different reason from the password
    /// managers — noise, not secrecy — and the pane shows that reason, so it has to be
    /// carried on the entry rather than implied by its position.
    func testBackglanceExcludesItsOwnNotificationsForItsOwnReason() {
        let entry = ExclusionList.shippedDefaults.first { $0.bundleID == "app.backglance.Backglance" }

        XCTAssertEqual(entry?.reason, .ownNotifications)
        XCTAssertTrue(ExclusionList().excludes("app.backglance.Backglance"))
    }

    func testAnAppNobodyHasMentionedIsNotExcluded() {
        XCTAssertFalse(ExclusionList().excludes("com.tinyspeck.slackmacgap"))
    }

    /// A bundle identifier is an identifier. macOS does not think `com.example.App` and
    /// `com.example.app` are the same app, and folding case here would let a near-miss
    /// match an exclusion that was never meant for it.
    func testBundleIdentifiersAreComparedExactly() {
        XCTAssertTrue(ExclusionList().excludes("com.apple.Passwords"))
        XCTAssertFalse(ExclusionList().excludes("com.apple.passwords"))
    }

    // MARK: - Which layer wins

    func testAnAppTheUserExcludedIsExcluded() {
        let list = ExclusionList(overrides: ["com.example.bank": true])

        XCTAssertTrue(list.excludes("com.example.bank"))
    }

    /// The one that makes "you may remove any of these" true. A row saying `false`
    /// outranks the shipped default, or the promise is only a sentence in a document.
    func testAUserWhoSwitchesOffADefaultGetsTheirWay() {
        let list = ExclusionList(overrides: ["com.1password.1password": false])

        XCTAssertFalse(list.excludes("com.1password.1password"))
    }

    /// An app with no row has made no decision, so the default stands — which is what
    /// makes a default added in a later release reach an archive created before it.
    func testAnAbsentOverrideIsNotTheSameAsFalse() {
        let list = ExclusionList(overrides: ["com.example.other": true])

        XCTAssertTrue(list.excludes("com.bitwarden.desktop"))
    }

    func testTheExcludedSetIsTheDefaultsPlusAdditionsMinusRemovals() {
        let list = ExclusionList(overrides: [
            "com.example.bank": true,
            "com.lastpass.LastPass": false,
        ])

        XCTAssertTrue(list.excludedBundleIDs.contains("com.example.bank"))
        XCTAssertFalse(list.excludedBundleIDs.contains("com.lastpass.LastPass"))
        XCTAssertTrue(list.excludedBundleIDs.contains("com.apple.Passwords"))
    }

    func testSuppressedDefaultsAreOnlyTheDefaultsTheUserSwitchedOff() {
        let list = ExclusionList(overrides: [
            "com.lastpass.LastPass": false,
            "com.example.bank": false,
            "com.example.other": true,
        ])

        XCTAssertEqual(list.suppressedDefaults.map(\.bundleID), ["com.lastpass.LastPass"])
    }

    // MARK: - Through the archive

    func testAFreshArchiveExcludesTheShippedDefaults() throws {
        let archive = try XCTUnwrap(archive)

        let list = try archive.exclusionList()

        XCTAssertEqual(list.excludedBundleIDs, ExclusionList.shippedDefaultBundleIDs)
    }

    func testExcludingAnAppTheArchiveHasNotSeenCreatesItsRow() throws {
        let archive = try XCTUnwrap(archive)

        let app = try archive.setExcluded(true, bundleID: "com.example.bank")

        XCTAssertTrue(app.isExcluded)
        XCTAssertTrue(try archive.exclusionList().excludes("com.example.bank"))
    }

    func testSwitchingOffADefaultIsWrittenDownAndSticks() throws {
        let archive = try XCTUnwrap(archive)

        try archive.setExcluded(false, bundleID: "com.1password.1password")

        XCTAssertFalse(try archive.exclusionList().excludes("com.1password.1password"))
    }

    /// 🔒 Excluding an app stops the *next* notification. It does not reach back and
    /// delete what is already archived — that is a separate decision with its own
    /// confirmation, and a method that quietly did both would make the pane's toggle far
    /// more destructive than it looks.
    func testExcludingAnAppLeavesWhatIsAlreadyArchivedAlone() throws {
        let archive = try XCTUnwrap(archive)
        let app = try archive.upsertApp(bundleID: "com.example.bank", now: Self.delivered)
        try archive.insertOrUpdate(ArchivedNotification(
            uuid: UUID().uuidString,
            appId: XCTUnwrap(app.id),
            title: "Statement ready",
            deliveredAt: UnixDate(Self.delivered),
            capturedAt: UnixDate(Self.delivered)
        ))

        try archive.setExcluded(true, bundleID: "com.example.bank")

        let remaining = try archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        XCTAssertEqual(remaining, 1)
    }

    // MARK: - Restore defaults

    func testRestoringDefaultsPutsBackOnlyWhatWasSwitchedOff() throws {
        let archive = try XCTUnwrap(archive)
        try archive.setExcluded(false, bundleID: "com.lastpass.LastPass")
        try archive.setExcluded(false, bundleID: "com.bitwarden.desktop")

        let restored = try archive.restoreDefaultExclusions()

        XCTAssertEqual(restored, 2)
        XCTAssertEqual(try archive.exclusionList().excludedBundleIDs, ExclusionList.shippedDefaultBundleIDs)
    }

    /// The surprise this guards against: "restore defaults" un-excluding a bank the user
    /// added by hand. Restoring the defaults means restoring the defaults.
    func testRestoringDefaultsLeavesAnAppTheUserAddedExcluded() throws {
        let archive = try XCTUnwrap(archive)
        try archive.setExcluded(true, bundleID: "com.example.bank")
        try archive.setExcluded(false, bundleID: "com.lastpass.LastPass")

        try archive.restoreDefaultExclusions()

        XCTAssertTrue(try archive.exclusionList().excludes("com.example.bank"))
    }

    func testRestoringDefaultsOnAnUntouchedArchiveChangesNothing() throws {
        let archive = try XCTUnwrap(archive)

        XCTAssertEqual(try archive.restoreDefaultExclusions(), 0)
    }

    // MARK: Private

    private static let delivered = Date(timeIntervalSince1970: 1_787_236_200)

    private var archive: Archive?
}
