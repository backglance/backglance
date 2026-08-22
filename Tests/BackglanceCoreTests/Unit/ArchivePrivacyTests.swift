@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

/// Covers the per-app half of one-time-code redaction: the accessors the Code Redaction
/// pane reads and writes, and the defaults that hold for an app the archive has never
/// seen.
///
/// See docs/features/PRIVACY_CONTROLS.md#per-app-toggle-and-redact-codes-in-all-apps.
final class ArchivePrivacyTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - The defaults

    /// 🔒 The answer for Messages and Mail is "yes" before either has notified, so the
    /// very first code that arrives is covered rather than the second.
    func testAFreshArchiveAnswersYesForMessagesAndMail() throws {
        let archive = try XCTUnwrap(archive)

        XCTAssertTrue(try archive.redactsOTP(bundleID: "com.apple.MobileSMS"))
        XCTAssertTrue(try archive.redactsOTP(bundleID: "com.apple.mail"))
    }

    /// And the row capture creates on that first notification carries the same answer —
    /// which is what makes the promise true of the archive and not only of this accessor.
    func testTheAppRowCaptureCreatesCarriesTheSameDefault() throws {
        let archive = try XCTUnwrap(archive)

        let app = try archive.upsertApp(bundleID: "com.apple.MobileSMS", now: Date())

        XCTAssertTrue(app.redactOtp)
    }

    func testAnAppTheArchiveHasNeverSeenAnswersWithTheShippedDefault() throws {
        let archive = try XCTUnwrap(archive)

        XCTAssertFalse(try archive.redactsOTP(bundleID: "com.tinyspeck.slackmacgap"))
        XCTAssertFalse(try archive.upsertApp(bundleID: "com.tinyspeck.slackmacgap", now: Date()).redactOtp)
    }

    // MARK: - The toggle

    func testSwitchingRedactionOffForMessagesSticks() throws {
        let archive = try XCTUnwrap(archive)

        try archive.setRedactsOTP(false, bundleID: "com.apple.MobileSMS")

        XCTAssertFalse(try archive.redactsOTP(bundleID: "com.apple.MobileSMS"))
    }

    func testSwitchingRedactionOnForAnAppTheArchiveHasNotSeenCreatesItsRow() throws {
        let archive = try XCTUnwrap(archive)

        let app = try archive.setRedactsOTP(true, bundleID: "com.example.bank")

        XCTAssertTrue(app.redactOtp)
        XCTAssertEqual(app.notificationCount, 0)
        XCTAssertTrue(try archive.redactsOTP(bundleID: "com.example.bank"))
    }

    /// The row created for an unseen app is the same row capture would have made, so the
    /// app's first notification lands on it rather than beside it.
    func testAnAppAddedByBundleIDKeepsItsSettingWhenItFirstNotifies() throws {
        let archive = try XCTUnwrap(archive)
        try archive.setRedactsOTP(true, bundleID: "com.example.bank")

        let app = try archive.upsertApp(bundleID: "com.example.bank", now: Date())

        XCTAssertTrue(app.redactOtp)
        XCTAssertEqual(try archive.allApps().filter { $0.bundleId == "com.example.bank" }.count, 1)
    }

    /// Setting the value a freshly created row already has still leaves exactly one row,
    /// rather than a second one that would shadow the first in every later lookup.
    func testTogglingToTheValueItAlreadyHasLeavesOneRow() throws {
        let archive = try XCTUnwrap(archive)

        let app = try archive.setRedactsOTP(true, bundleID: "com.apple.mail")
        try archive.setRedactsOTP(true, bundleID: "com.apple.mail")

        XCTAssertTrue(app.redactOtp)
        XCTAssertEqual(try archive.allApps().count, 1)
    }

    // MARK: - The list

    func testAppsAreListedNoisiestFirst() throws {
        let archive = try XCTUnwrap(archive)
        let quiet = try XCTUnwrap(archive.upsertApp(bundleID: "com.example.quiet", now: Date()).id)
        let loud = try XCTUnwrap(archive.upsertApp(bundleID: "com.example.loud", now: Date()).id)
        try archive.pool.write { db in
            try Archive.recordNotification(db, appID: quiet, deliveredAt: UnixDate(Date()))
            for _ in 0 ..< 3 {
                try Archive.recordNotification(db, appID: loud, deliveredAt: UnixDate(Date()))
            }
        }

        let listed = try archive.allApps().map(\.bundleId)

        XCTAssertEqual(listed, ["com.example.loud", "com.example.quiet"])
    }

    // MARK: Private

    private var archive: Archive?
}
