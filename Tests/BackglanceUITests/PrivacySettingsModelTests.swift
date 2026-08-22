import BackglanceCore
@testable import BackglanceUI
import Foundation
import XCTest

/// The Privacy pane's own state: the redaction activity table, the pause row, and the
/// import-while-paused switch. The three composed sections have their own tests.
@MainActor
final class PrivacySettingsModelTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
        let name = "app.backglance.tests.\(UUID().uuidString)"
        suiteName = name
        defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - Redaction activity

    /// 🔒 Counts and app names. `redactions` never stored the text it replaced, so the table
    /// could not show a code even if it wanted to — and this asserts the shape it does show.
    func testActivityCountsRedactionsPerApp() async throws {
        let archive = try XCTUnwrap(archive)
        try seedRedactions(in: archive, bundleID: "com.apple.MobileSMS", count: 3)
        try seedRedactions(in: archive, bundleID: "com.apple.mail", count: 1)
        let model = try makeModel()

        await model.load()

        XCTAssertEqual(model.activity.map(\.bundleID), ["com.apple.MobileSMS", "com.apple.mail"])
        XCTAssertEqual(model.activity.map(\.count), [3, 1], "busiest app first")
        XCTAssertTrue(model.hasActivity)
    }

    /// An empty table is an answer, not a missing one, so the pane says so rather than
    /// hiding the section.
    func testAnArchiveWithNoRedactionsHasNoActivity() async throws {
        let model = try makeModel()

        await model.load()

        XCTAssertTrue(model.activity.isEmpty)
        XCTAssertFalse(model.hasActivity)
        XCTAssertNil(model.failure)
    }

    /// The window is thirty days. Something redacted last spring is not "recent activity".
    func testActivityIgnoresRedactionsOlderThanTheWindow() async throws {
        let archive = try XCTUnwrap(archive)
        let longAgo = Date().addingTimeInterval(-PrivacySettingsModel.activityWindow - 60)
        try seedRedactions(in: archive, bundleID: "com.apple.MobileSMS", count: 2, at: longAgo)
        let model = try makeModel()

        await model.load()

        XCTAssertTrue(model.activity.isEmpty)
    }

    /// A redaction belongs to a notification; a pruned notification takes its audit row with
    /// it. The table reports on what the archive holds, not on what it once did.
    func testActivityDropsRedactionsWhoseNotificationWasPruned() async throws {
        let archive = try XCTUnwrap(archive)
        try seedRedactions(in: archive, bundleID: "com.apple.MobileSMS", count: 2)
        try await archive.pool.write { db in try db.execute(sql: "DELETE FROM notifications") }
        let model = try makeModel()

        await model.load()

        XCTAssertTrue(model.activity.isEmpty)
    }

    // MARK: - The pause row

    func testThePauseRowReflectsTheStoredPause() async throws {
        let defaults = try XCTUnwrap(defaults)
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        PauseSettings.save(state: .until(until), to: defaults)
        let model = try makeModel()

        await model.load()

        XCTAssertEqual(model.pauseState, .until(until))
    }

    /// The status item's menu can pause capture while this window is open, so the row is
    /// re-read on appearance rather than captured once at init.
    func testThePauseRowIsRereadOnLoad() async throws {
        let defaults = try XCTUnwrap(defaults)
        let model = try makeModel()
        XCTAssertEqual(model.pauseState, .notPaused)

        PauseSettings.save(state: .indefinite, to: defaults)
        await model.load()

        XCTAssertEqual(model.pauseState, .indefinite)
    }

    func testResumingClearsThePauseAndCallsTheEngine() async throws {
        let defaults = try XCTUnwrap(defaults)
        PauseSettings.save(state: .indefinite, to: defaults)
        let resumed = Flag()
        let resume: @Sendable () async -> Void = {
            PauseSettings.save(state: .notPaused, to: defaults)
            await resumed.raise()
        }
        let model = try makeModel(resumeCapture: resume)
        await model.load()

        await model.resume()

        let didResume = await resumed.value
        XCTAssertTrue(didResume)
        XCTAssertEqual(model.pauseState, .notPaused)
    }

    /// Written straight through, because `CaptureEngine.resume()` reads it fresh — there is
    /// no apply step to forget between this toggle and the next resume.
    func testTheImportSwitchIsWrittenStraightThrough() throws {
        let defaults = try XCTUnwrap(defaults)
        let model = try makeModel()
        XCTAssertFalse(model.importWhilePaused)

        model.importWhilePaused = true

        XCTAssertTrue(PauseSettings(defaults: defaults).importWhilePaused)
    }

    // MARK: - Reveal in Finder

    /// An in-memory archive has no folder to show, so the button has nothing to point at and
    /// the pane disables it rather than opening the wrong window.
    func testAnInMemoryArchiveHasNoDirectoryToReveal() throws {
        let model = try makeModel()

        XCTAssertNil(model.archiveDirectory)
    }

    // MARK: Private

    private actor Flag {
        private(set) var value = false

        func raise() {
            value = true
        }
    }

    private var archive: Archive?
    private var defaults: UserDefaults?
    private var suiteName: String?

    /// `store_rec_id` is unique across the whole archive, so a per-app counter would make
    /// every app after the first insert nothing but duplicates.
    private var nextStoreRecID: Int64 = 1

    private func makeModel(
        resumeCapture: @escaping @Sendable () async -> Void = {}
    ) throws -> PrivacySettingsModel {
        let archive = try XCTUnwrap(archive)
        let defaults = try XCTUnwrap(defaults)
        return PrivacySettingsModel(
            archive: archive,
            retention: RetentionSettingsModel(archive: archive, job: nil, defaults: defaults),
            exclusions: ExcludedAppsSettingsModel(archive: archive),
            redaction: CodeRedactionSettingsModel(archive: archive, defaults: defaults),
            wipe: WipeConfirmationModel(archive: archive),
            resumeCapture: resumeCapture,
            defaults: defaults
        )
    }

    private func seedRedactions(
        in archive: Archive,
        bundleID: String,
        count: Int,
        at date: Date = Date()
    ) throws {
        let app = try archive.upsertApp(bundleID: bundleID, now: date)
        for index in 0 ..< count {
            let notification = try ArchivedNotification(
                uuid: UUID().uuidString,
                appId: XCTUnwrap(app.id),
                title: "Aurora Bank",
                body: "Your code is [code redacted]",
                deliveredAt: UnixDate(date),
                capturedAt: UnixDate(date),
                redaction: .otp,
                storeRecId: nextStoreRecID + Int64(index)
            )
            _ = try archive.insertOrUpdate(
                notification,
                redaction: RedactionEvent(kind: .otp, patternId: "otp.keyword.en", redactedAt: UnixDate(date))
            )
        }
        nextStoreRecID += Int64(count)
    }
}
