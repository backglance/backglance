import BackglanceCore
import BackglanceTestSupport
@testable import BackglanceUI
import Foundation
import XCTest

@MainActor
final class NotificationActionHandlerTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        handler = nil
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - fetch

    /// The shared read every action starts from: given a live id, it returns both
    /// halves the action needs — the row and the app that sent it — in one call.
    func testFetchReturnsTheNotificationAndItsApp() throws {
        let archive = try XCTUnwrap(archive)
        let app = try archive.upsertApp(bundleID: Stubs.BundleID.slack, now: Stubs.epoch)
        let appID = try XCTUnwrap(app.id)
        let inserted = try archive.insert(ArchivedNotification(
            uuid: "FIXTURE-1",
            appId: appID,
            title: "Fixture message",
            deliveredAt: UnixDate(Stubs.epoch),
            capturedAt: UnixDate(Stubs.epoch)
        ))
        let id = try XCTUnwrap(inserted.id)

        let (fetched, fetchedApp) = try makeHandler(archive: archive).fetch(id)

        XCTAssertEqual(fetched.id, id)
        XCTAssertEqual(fetchedApp.id, appID)
        XCTAssertEqual(fetchedApp.bundleId, Stubs.BundleID.slack)
    }

    /// An id nothing was ever inserted under — the ordinary shape of "this row was
    /// deleted out from under the click".
    func testFetchOfAnUnknownIDThrowsNotFoundWithThatID() throws {
        let archive = try XCTUnwrap(archive)

        XCTAssertThrowsError(try makeHandler(archive: archive).fetch(404)) { error in
            XCTAssertEqual(error as? ActionError, .notFound(notificationID: 404))
        }
    }

    /// A notification whose app row is gone (or never existed) is just as unusable
    /// to an action as a missing notification — both halves are required, so either
    /// missing is reported the same way.
    func testFetchOfANotificationWithNoAppRowThrowsNotFound() throws {
        let archive = try XCTUnwrap(archive)
        let app = try archive.upsertApp(bundleID: Stubs.BundleID.mail, now: Stubs.epoch)
        let appID = try XCTUnwrap(app.id)
        let inserted = try archive.insert(ArchivedNotification(
            uuid: "FIXTURE-2",
            appId: appID,
            deliveredAt: UnixDate(Stubs.epoch),
            capturedAt: UnixDate(Stubs.epoch)
        ))
        let id = try XCTUnwrap(inserted.id)
        try archive.pool.write { db in
            try db.execute(sql: "DELETE FROM apps WHERE id = ?", arguments: [appID])
        }

        XCTAssertThrowsError(try makeHandler(archive: archive).fetch(id)) { error in
            XCTAssertEqual(error as? ActionError, .notFound(notificationID: id))
        }
    }

    // MARK: - ActionError.userMessage

    func testUserMessageForEveryCase() {
        XCTAssertEqual(
            ActionError.notFound(notificationID: 1).userMessage,
            "Something went wrong — see log"
        )
        XCTAssertEqual(
            ActionError.archive(reason: "sqlite 1: disk I/O error").userMessage,
            "Something went wrong — see log"
        )
        XCTAssertEqual(
            ActionError.appNotInstalled(bundleID: Stubs.BundleID.slack).userMessage,
            "App not found"
        )
        XCTAssertEqual(
            ActionError.launchFailed(bundleID: Stubs.BundleID.slack, reason: "boom").userMessage,
            "Couldn't open \(Stubs.BundleID.slack)"
        )
        XCTAssertEqual(ActionError.pasteboardFailure.userMessage, "Couldn't copy")
        XCTAssertEqual(
            ActionError.exportFailed(reason: "disk full").userMessage,
            "Export failed: disk full"
        )
        XCTAssertEqual(
            ActionError.systemSettingsUnavailable.userMessage,
            "Couldn't open System Settings"
        )
    }

    /// The one case with nothing to say: docs/features/ACTIONS.md maps
    /// `.deepLinkUnresolvable` to a system beep, not text.
    func testDeepLinkUnresolvableHasNoUserMessage() {
        XCTAssertNil(ActionError.deepLinkUnresolvable(notificationID: 1).userMessage)
    }

    // MARK: Private

    private var archive: Archive?
    private var handler: NotificationActionHandler?

    /// A handler held by the test case so nothing about its lifetime is a surprise,
    /// matching ``TimelineStoreTests``'s `makeStore(archive:)`.
    private func makeHandler(archive: Archive) -> NotificationActionHandler {
        let handler = NotificationActionHandler(archive: archive)
        self.handler = handler
        return handler
    }
}
