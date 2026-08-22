@testable import BackglanceCore
import Foundation
import XCTest

/// Covers the retention *policy* layer: what each value means as a cutoff, how `inherit`
/// resolves, what the global default is, and the one place retention reaches into the
/// exclusion list.
///
/// `RetentionJob` — the thing that actually deletes — is its own task and its own tests.
/// This file is about what the job will be told to do.
///
/// See docs/features/PRIVACY_CONTROLS.md#policy-values-and-inheritance.
final class RetentionSettingsTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - Cutoffs

    func testEachBoundedPolicyCutsOffItsOwnIntervalBeforeNow() {
        XCTAssertEqual(RetentionPolicy.hours24.cutoff(from: Self.now), Self.now.addingTimeInterval(-86_400))
        XCTAssertEqual(RetentionPolicy.days7.cutoff(from: Self.now), Self.now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(RetentionPolicy.days30.cutoff(from: Self.now), Self.now.addingTimeInterval(-30 * 86_400))
    }

    /// `forever` and `never` both have no cutoff, for opposite reasons: one keeps
    /// everything, the other never stored anything to keep. Neither gives the job a window
    /// to prune, which is why both answer `nil` rather than one of them answering
    /// "everything is expired".
    func testForeverAndNeverHaveNoCutoff() {
        XCTAssertNil(RetentionPolicy.forever.cutoff(from: Self.now))
        XCTAssertNil(RetentionPolicy.never.cutoff(from: Self.now))
    }

    // MARK: - Inheritance

    func testInheritResolvesToWhateverTheGlobalIs() {
        XCTAssertEqual(AppRetention.inherit.effectivePolicy(global: .days7), .days7)
        XCTAssertEqual(AppRetention.inherit.effectivePolicy(global: .forever), .forever)
    }

    func testAnOverrideBeatsTheGlobal() {
        XCTAssertEqual(AppRetention.policy(.hours24).effectivePolicy(global: .forever), .hours24)
    }

    /// The direction that matters more: an override can keep *less* than the global as
    /// well as more. A user who set one app to 24 hours under a 30-day global gets 24
    /// hours, not the longer of the two.
    func testAnOverrideMayKeepLessThanTheGlobal() {
        let app = Self.app(retention: .policy(.hours24))

        XCTAssertEqual(app.effectiveRetention(global: .days30), .hours24)
        XCTAssertEqual(
            RetentionSettings(global: .days30).cutoff(for: app, from: Self.now),
            Self.now.addingTimeInterval(-86_400)
        )
    }

    // MARK: - The global default

    func testTheShippedGlobalIsThirtyDays() {
        XCTAssertEqual(RetentionPolicy.globalDefault, .days30)
        XCTAssertEqual(RetentionSettings(global: .globalDefault).global, .days30)
    }

    func testAnUnwrittenPreferenceReadsAsTheShippedDefault() throws {
        XCTAssertEqual(try RetentionSettings(defaults: throwawayDefaults()).global, .days30)
    }

    func testSavingTheGlobalIsWhatTheNextReadSees() throws {
        let defaults = try throwawayDefaults()

        RetentionSettings.save(global: .forever, to: defaults)

        XCTAssertEqual(RetentionSettings(defaults: defaults).global, .forever)
    }

    /// 🔒 A value this build does not recognise — a preference written by a newer one —
    /// falls back to thirty days, not to `forever`. Both lose nothing today, and that is
    /// the point of stating it: falling back to `forever` would silently switch pruning
    /// off, and an archive that quietly keeps everything is what retention exists to
    /// prevent.
    func testAnUnrecognisedPreferenceFallsBackToThirtyDaysRatherThanForever() throws {
        let defaults = try throwawayDefaults()
        defaults.set("42y", forKey: RetentionSettings.globalKey)

        XCTAssertEqual(RetentionSettings(defaults: defaults).global, .days30)
    }

    /// `never` is a statement about one app. Offering it in a picker labelled "Keep
    /// notifications for" would be a way to switch the whole product off by accident.
    func testTheGlobalPickerDoesNotOfferNever() {
        XCTAssertFalse(RetentionSettings.globalChoices.contains(.never))
        XCTAssertEqual(RetentionSettings.globalChoices, [.hours24, .days7, .days30, .forever])
    }

    // MARK: - Where retention meets exclusion

    /// 🔒 "Never store" is the exclusion list's sentence said in a retention picker, so
    /// both columns move in one transaction. A user who picks it and finds the app still
    /// being captured because a second write failed has every reason to stop trusting the
    /// pane.
    func testChoosingNeverAlsoExcludesTheApp() throws {
        let archive = try XCTUnwrap(archive)

        let app = try archive.setRetention(.policy(.never), bundleID: "com.example.bank")

        XCTAssertEqual(app.retention, .policy(.never))
        XCTAssertTrue(app.isExcluded)
        XCTAssertTrue(try archive.exclusionList().excludes("com.example.bank"))
    }

    /// And not the reverse. The app may have been excluded long before anyone touched its
    /// retention — a password manager, or one the user added by hand — so moving off
    /// `never` must not quietly resume capturing it.
    func testMovingOffNeverDoesNotUnexcludeTheApp() throws {
        let archive = try XCTUnwrap(archive)
        try archive.setRetention(.policy(.never), bundleID: "com.example.bank")

        let app = try archive.setRetention(.policy(.days7), bundleID: "com.example.bank")

        XCTAssertEqual(app.retention, .policy(.days7))
        XCTAssertTrue(app.isExcluded, "un-excluding is the Excluded Apps pane's visible, labelled job")
    }

    func testAnOrdinaryRetentionChangeLeavesExclusionAlone() throws {
        let archive = try XCTUnwrap(archive)

        let app = try archive.setRetention(.policy(.hours24), bundleID: "com.example.chat")

        XCTAssertFalse(app.isExcluded)
    }

    /// 🔒 Setting `never` on an app that is somehow already `never` but not excluded
    /// repairs it rather than short-circuiting. The early return is an optimisation, and
    /// an optimisation that can leave the two columns disagreeing is a bug.
    func testNeverRepairsAnAppWhoseExclusionWasLost() throws {
        let archive = try XCTUnwrap(archive)
        try archive.setRetention(.policy(.never), bundleID: "com.example.bank")
        try archive.setExcluded(false, bundleID: "com.example.bank")

        let app = try archive.setRetention(.policy(.never), bundleID: "com.example.bank")

        XCTAssertTrue(app.isExcluded)
    }

    func testRetentionForAnAppTheArchiveHasNotSeenCreatesItsRow() throws {
        let archive = try XCTUnwrap(archive)

        try archive.setRetention(.policy(.days7), bundleID: "com.example.bank")

        let stored = try archive.allApps().first { $0.bundleId == "com.example.bank" }
        XCTAssertEqual(stored?.retention, .policy(.days7))
    }

    /// Nothing already archived is deleted by a policy change. Offering that is the
    /// settings sheet's business, and it asks first.
    func testChangingRetentionDeletesNothingByItself() throws {
        let archive = try XCTUnwrap(archive)
        let app = try archive.upsertApp(bundleID: "com.example.chat", now: Self.old)
        try archive.insertOrUpdate(ArchivedNotification(
            uuid: UUID().uuidString,
            appId: XCTUnwrap(app.id),
            title: "Ancient history",
            deliveredAt: UnixDate(Self.old),
            capturedAt: UnixDate(Self.old)
        ))

        try archive.setRetention(.policy(.hours24), bundleID: "com.example.chat")

        let remaining = try archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        XCTAssertEqual(remaining, 1)
    }

    // MARK: Private

    private static let now = Date(timeIntervalSince1970: 1_787_236_200)
    private static let old = Date(timeIntervalSince1970: 1_700_000_000)

    private var archive: Archive?

    private static func app(retention: AppRetention) -> AppRecord {
        AppRecord(
            id: 1,
            bundleId: "com.example.chat",
            displayName: nil,
            retention: retention,
            isExcluded: false,
            isMuted: false,
            redactOtp: false,
            firstSeenAt: UnixDate(now),
            lastSeenAt: UnixDate(now),
            notificationCount: 0
        )
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
