import BackglanceCore
@testable import BackglanceUI
import Foundation
import XCTest

/// Covers `RetentionSettingsModel`: what the pane lists, what the global picker and the
/// per-app overrides write, and what "Run cleanup now" reports.
///
/// See docs/features/PRIVACY_CONTROLS.md#policy-values-and-inheritance.
@MainActor
final class RetentionSettingsModelTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - The global default

    /// Thirty days is the shipped default everywhere else in the app; the pane has to start
    /// there too, or the picker would show a value nobody chose.
    func testTheGlobalDefaultsToThirtyDaysAndWritesThrough() throws {
        let defaults = try throwawayDefaults()
        let model = try makeModel(defaults: defaults)

        XCTAssertEqual(model.global, .days30)

        model.global = .forever

        XCTAssertEqual(RetentionSettings(defaults: defaults).global, .forever, "written straight through")
    }

    /// Setting the same value twice is a no-op, not a second write — `didSet` guards on
    /// equality precisely so a picker re-selecting its own value does not touch the disk.
    func testSettingTheGlobalToItsOwnValueDoesNotThrash() throws {
        let defaults = try throwawayDefaults()
        let model = try makeModel(defaults: defaults)

        model.global = .days30

        XCTAssertEqual(RetentionSettings(defaults: defaults).global, .days30)
    }

    // MARK: - What the pane lists

    /// Every app the archive holds shows up, whether or not it has an override — this is a
    /// list of all apps, not a membership list like Excluded Apps.
    func testAppsAreListedWithTheirOverrides() async throws {
        let archive = try XCTUnwrap(archive)
        try archive.setRedactsOTP(true, bundleID: "com.example.chat")
        try archive.setRetention(.policy(.days7), bundleID: "com.example.bank")
        let model = try makeModel()

        await model.load()

        let chat = try XCTUnwrap(model.rows.first { $0.bundleID == "com.example.chat" })
        XCTAssertEqual(chat.retention, .inherit, "no override was ever set for it")

        let bank = try XCTUnwrap(model.rows.first { $0.bundleID == "com.example.bank" })
        XCTAssertEqual(bank.retention, .policy(.days7))
    }

    /// A model with no archive shows nothing and writes nothing, rather than offering
    /// controls that would silently do neither.
    func testWithoutAnArchiveOrJobNothingIsListedAndWritesAreNoOps() async {
        let model = RetentionSettingsModel(archive: nil, job: nil)

        await model.load()
        await model.setRetention(.policy(.forever), forBundleID: "com.example.bank")
        await model.runCleanupNow()

        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.lastReport)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.canRunCleanupNow)
    }

    // MARK: - Setting an override

    func testSettingAnOverridePersistsAndReloads() async throws {
        let archive = try XCTUnwrap(archive)
        try archive.setRedactsOTP(true, bundleID: "com.example.chat")
        let model = try makeModel()
        await model.load()

        await model.setRetention(.policy(.hours24), forBundleID: "com.example.chat")

        let row = try XCTUnwrap(model.rows.first { $0.bundleID == "com.example.chat" })
        XCTAssertEqual(row.retention, .policy(.hours24))
        let stored = try archive.allApps().first { $0.bundleId == "com.example.chat" }
        XCTAssertEqual(stored?.retention, .policy(.hours24), "the write reached the archive, not just the model")
    }

    /// 🔒 Choosing "Never store" also excludes the app, in the same transaction
    /// (`Archive.setRetention(_:bundleID:now:)`) — the Retention pane and the Excluded Apps
    /// pane must never disagree about an app the user picked this for.
    func testSettingNeverMarksTheAppExcluded() async throws {
        let archive = try XCTUnwrap(archive)
        try archive.setRedactsOTP(true, bundleID: "com.example.chat")
        let model = try makeModel()
        await model.load()

        await model.setRetention(.policy(.never), forBundleID: "com.example.chat")

        let row = try XCTUnwrap(model.rows.first { $0.bundleID == "com.example.chat" })
        XCTAssertEqual(row.retention, .policy(.never))
        let stored = try XCTUnwrap(archive.allApps().first { $0.bundleId == "com.example.chat" })
        XCTAssertTrue(stored.isExcluded)
    }

    // MARK: - Running cleanup now

    /// The model does not run the prune itself — it hands the real job the "manual" trigger
    /// and reports back exactly what came out, so the pane can say something more useful
    /// than "done".
    func testRunCleanupNowReportsWhatThePassDid() async throws {
        let archive = try XCTUnwrap(archive)
        let defaults = try throwawayDefaults()
        let now = Self.now
        let app = try archive.upsertApp(bundleID: "com.example.chat", now: now)
        let appID = try XCTUnwrap(app.id)
        _ = try archive.insertOrUpdate(ArchivedNotification(
            uuid: UUID().uuidString,
            appId: appID,
            title: "Fixture",
            body: "Fixture body",
            deliveredAt: UnixDate(now.addingTimeInterval(-40 * Self.day)),
            capturedAt: UnixDate(now.addingTimeInterval(-40 * Self.day))
        ))
        let job = RetentionJob(
            archive: archive,
            defaults: defaults,
            schedule: RetentionJob.Schedule(launchDelay: 0, interval: 3_600)
        ) { now }
        let model = RetentionSettingsModel(archive: archive, job: job, defaults: defaults)

        await model.runCleanupNow()

        let report = try XCTUnwrap(model.lastReport)
        XCTAssertEqual(report.softDeleted, 1)
        XCTAssertFalse(model.isBusy, "the flag comes back down once the pass returns")
    }

    /// A pass over an archive with nothing to prune still produces a report — `isEmpty`
    /// rather than `nil` — so the pane can say "nothing needed cleaning up" instead of
    /// staying silent about whether the button did anything at all.
    func testRunCleanupNowReportsEmptyWhenThereIsNothingToPrune() async throws {
        let archive = try XCTUnwrap(archive)
        let defaults = try throwawayDefaults()
        let job = RetentionJob(
            archive: archive,
            defaults: defaults,
            schedule: RetentionJob.Schedule(launchDelay: 0, interval: 3_600)
        )
        let model = RetentionSettingsModel(archive: archive, job: job, defaults: defaults)

        await model.runCleanupNow()

        let report = try XCTUnwrap(model.lastReport)
        XCTAssertTrue(report.isEmpty)
    }

    // MARK: Private

    private static let now = Date(timeIntervalSince1970: 1_787_236_200)
    private static let day: TimeInterval = 86_400

    private var archive: Archive?

    private func makeModel(defaults: UserDefaults? = nil) throws -> RetentionSettingsModel {
        let archive = try XCTUnwrap(archive)
        return try RetentionSettingsModel(archive: archive, job: nil, defaults: defaults ?? throwawayDefaults())
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
