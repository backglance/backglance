import BackglanceCore
@testable import BackglanceUI
import Foundation
import XCTest

/// Covers `AppsSettingsModel`: the picker's row list, the selected app's three settings, and
/// that every write goes through the composed ``RetentionSettingsModel``,
/// ``ExcludedAppsSettingsModel`` and ``CodeRedactionSettingsModel`` rather than a second copy
/// of their archive logic.
///
/// See docs/features/PRIVACY_CONTROLS.md#ui-components.
@MainActor
final class AppsSettingsModelTests: XCTestCase {
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

    /// The row list is `RetentionSettingsModel.rows` verbatim: every app the archive holds,
    /// not the narrower membership lists Excluded Apps and Code Redaction show.
    func testRowsMirrorRetentionsList() async throws {
        let archive = try XCTUnwrap(archive)
        _ = try archive.upsertApp(bundleID: "com.example.chat", now: Self.now)
        let model = try makeModel()

        await model.load()

        XCTAssertEqual(model.rows.map(\.bundleID), model.retention.rows.map(\.bundleID))
        XCTAssertEqual(Set(model.rows.map(\.bundleID)), ["com.example.chat"])
    }

    /// A fresh archive with nothing captured yet lists nothing — unlike Excluded Apps and
    /// Code Redaction, this pane does not seed itself with shipped defaults that have never
    /// notified.
    func testAFreshArchiveListsNoApps() async throws {
        let model = try makeModel()

        await model.load()

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.selectedBundleID)
        XCTAssertNil(model.selectedRow)
    }

    /// `load()` picks a default selection when there is none yet, so the detail side has
    /// something to show the first time the pane appears.
    func testLoadSelectsTheFirstAppWhenNothingIsSelected() async throws {
        let archive = try XCTUnwrap(archive)
        _ = try archive.upsertApp(bundleID: "com.example.chat", now: Self.now)
        let model = try makeModel()

        await model.load()

        XCTAssertEqual(model.selectedBundleID, "com.example.chat")
    }

    /// A selection the caller already made is not overridden by a later `load()`.
    func testLoadDoesNotOverrideAnExistingSelection() async throws {
        let archive = try XCTUnwrap(archive)
        _ = try archive.upsertApp(bundleID: "com.example.chat", now: Self.now)
        _ = try archive.upsertApp(bundleID: "com.example.bank", now: Self.now)
        let model = try makeModel()
        await model.load()

        model.selectedBundleID = "com.example.bank"
        await model.load()

        XCTAssertEqual(model.selectedBundleID, "com.example.bank")
    }

    // MARK: - Reading the selected app's settings

    func testSelectedRowReflectsRetention() async throws {
        let archive = try XCTUnwrap(archive)
        try archive.setRetention(.policy(.days7), bundleID: "com.example.bank")
        let model = try makeModel()
        await model.load()
        model.selectedBundleID = "com.example.bank"

        XCTAssertEqual(model.selectedRow?.retention, .policy(.days7))
    }

    func testIsSelectedExcludedReflectsTheExclusionList() async throws {
        let archive = try XCTUnwrap(archive)
        _ = try archive.upsertApp(bundleID: "com.example.chat", now: Self.now)
        try archive.setExcluded(true, bundleID: "com.example.chat")
        let model = try makeModel()
        await model.load()
        model.selectedBundleID = "com.example.chat"

        XCTAssertTrue(model.isSelectedExcluded)
    }

    func testIsSelectedRedactedReflectsTheRedactionList() async throws {
        let archive = try XCTUnwrap(archive)
        try archive.setRedactsOTP(true, bundleID: "com.example.chat")
        let model = try makeModel()
        await model.load()
        model.selectedBundleID = "com.example.chat"

        XCTAssertTrue(model.isSelectedRedacted)
    }

    /// Nothing selected reports the quiet defaults rather than crashing.
    func testWithNoSelectionEverythingReadsAsUnset() {
        let model = try? makeModel()
        XCTAssertNotNil(model)
        XCTAssertNil(model?.selectedRow)
        XCTAssertEqual(model?.isSelectedExcluded, false)
        XCTAssertEqual(model?.isSelectedRedacted, false)
    }

    // MARK: - Writing the selected app's settings

    /// The write reaches the archive through `RetentionSettingsModel`, not a second write
    /// path — asserted by reading the archive back, the same way `RetentionSettingsModelTests`
    /// proves its own writes land.
    func testSetRetentionWritesThroughTheComposedRetentionModel() async throws {
        let archive = try XCTUnwrap(archive)
        _ = try archive.upsertApp(bundleID: "com.example.chat", now: Self.now)
        let model = try makeModel()
        await model.load()
        model.selectedBundleID = "com.example.chat"

        await model.setRetention(.policy(.hours24))

        XCTAssertEqual(model.selectedRow?.retention, .policy(.hours24))
        let stored = try archive.allApps().first { $0.bundleId == "com.example.chat" }
        XCTAssertEqual(stored?.retention, .policy(.hours24))
    }

    func testSetExcludedWritesThroughTheComposedExclusionsModel() async throws {
        let archive = try XCTUnwrap(archive)
        _ = try archive.upsertApp(bundleID: "com.example.chat", now: Self.now)
        let model = try makeModel()
        await model.load()
        model.selectedBundleID = "com.example.chat"

        await model.setExcluded(true)

        XCTAssertTrue(model.isSelectedExcluded)
        let stored = try archive.allApps().first { $0.bundleId == "com.example.chat" }
        XCTAssertEqual(stored?.isExcluded, true)

        await model.setExcluded(false)

        XCTAssertFalse(model.isSelectedExcluded)
    }

    func testSetRedactionWritesThroughTheComposedRedactionModel() async throws {
        let archive = try XCTUnwrap(archive)
        _ = try archive.upsertApp(bundleID: "com.example.chat", now: Self.now)
        let model = try makeModel()
        await model.load()
        model.selectedBundleID = "com.example.chat"

        await model.setRedaction(true)

        XCTAssertTrue(model.isSelectedRedacted)
        let stored = try archive.allApps().first { $0.bundleId == "com.example.chat" }
        XCTAssertEqual(stored?.redactOtp, true)
    }

    /// Every write is a no-op with nothing selected, the same "controls that quietly do
    /// nothing" contract every other settings model in this package keeps for a `nil`
    /// archive.
    func testWritesWithNoSelectionAreNoOps() async throws {
        let model = try makeModel()

        await model.setRetention(.policy(.forever))
        await model.setExcluded(true)
        await model.setRedaction(true)

        XCTAssertNil(model.selectedRow)
    }

    // MARK: Private

    private static let now = Date(timeIntervalSince1970: 1_787_236_200)

    private var archive: Archive?

    private func makeModel() throws -> AppsSettingsModel {
        let archive = try XCTUnwrap(archive)
        return AppsSettingsModel(
            retention: RetentionSettingsModel(archive: archive, job: nil, defaults: throwawayDefaults()),
            exclusions: ExcludedAppsSettingsModel(archive: archive),
            redaction: CodeRedactionSettingsModel(archive: archive, defaults: throwawayDefaults())
        )
    }

    private func throwawayDefaults() -> UserDefaults {
        let name = "app.backglance.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }
}
