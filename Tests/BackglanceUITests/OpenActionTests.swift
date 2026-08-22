import BackglanceCore
import BackglanceTestSupport
@testable import BackglanceUI
import Foundation
import XCTest

// MARK: - OpenActionTests

/// Covers the click-time ordering in
/// docs/features/ACTIONS.md#open-openaction-and-deeplinkresolver: `OpenAction`
/// itself (through the ``hasPathOrQuery(_:)`` table) and the two
/// `NotificationActionHandler` methods built on it, `openNotification(id:)`
/// and `openLink(id:)`. Every case goes through ``FakeAppLauncher`` — nothing
/// here is allowed to reach real `NSWorkspace` and actually open or launch
/// anything.
@MainActor
final class OpenActionTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
        launcher = FakeAppLauncher()
    }

    override func tearDownWithError() throws {
        handler = nil
        launcher = nil
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - openNotification: deep link present

    func testDeepLinkHandledOpensItAndNeverActivatesTheAppAndMarksRead() async throws {
        let launcher = try XCTUnwrap(launcher)
        let url = try XCTUnwrap(URL(string: "slack://channel/abc?open=1"))
        launcher.openResult = true
        let id = try insertNotification(deepLink: url.absoluteString)

        try await makeHandler().openNotification(id: id)

        XCTAssertEqual(launcher.calls, [.open(url)])
        XCTAssertTrue(try isRead(id))
    }

    // MARK: - openNotification: deep link refused

    func testDeepLinkRefusedFallsThroughToAppActivationWithNoError() async throws {
        let launcher = try XCTUnwrap(launcher)
        let appURL = try XCTUnwrap(URL(fileURLWithPath: "/Applications/Slack.app") as URL?)
        launcher.openResult = false
        launcher.applicationURLs[Stubs.BundleID.slack] = appURL
        let id = try insertNotification(deepLink: "slack://channel/abc")

        try await makeHandler().openNotification(id: id)

        XCTAssertEqual(launcher.calls, try [
            .open(XCTUnwrap(URL(string: "slack://channel/abc"))),
            .applicationURL(Stubs.BundleID.slack),
            .launchApplication(appURL),
        ])
        XCTAssertTrue(try isRead(id))
    }

    // MARK: - openNotification: deep link does not parse

    func testUnparseableDeepLinkFallsThroughToAppActivationWithNoError() async throws {
        let launcher = try XCTUnwrap(launcher)
        let appURL = try XCTUnwrap(URL(fileURLWithPath: "/Applications/Slack.app") as URL?)
        launcher.applicationURLs[Stubs.BundleID.slack] = appURL
        // The empty string is the one thing `URL(string:)` refuses to parse.
        let id = try insertNotification(deepLink: "")

        try await makeHandler().openNotification(id: id)

        XCTAssertEqual(launcher.calls, [
            .applicationURL(Stubs.BundleID.slack),
            .launchApplication(appURL),
        ])
        XCTAssertTrue(try isRead(id))
    }

    // MARK: - openNotification: no deep link

    func testNoDeepLinkActivatesTheAppAndMarksRead() async throws {
        let launcher = try XCTUnwrap(launcher)
        let appURL = try XCTUnwrap(URL(fileURLWithPath: "/Applications/Slack.app") as URL?)
        launcher.applicationURLs[Stubs.BundleID.slack] = appURL
        let id = try insertNotification(deepLink: nil)

        try await makeHandler().openNotification(id: id)

        XCTAssertEqual(launcher.calls, [
            .applicationURL(Stubs.BundleID.slack),
            .launchApplication(appURL),
        ])
        XCTAssertTrue(try isRead(id))
    }

    // MARK: - openNotification: app not installed

    func testAppNotInstalledThrowsAndDoesNotMarkRead() async throws {
        let id = try insertNotification(deepLink: nil)

        do {
            try await makeHandler().openNotification(id: id)
            XCTFail("expected .appNotInstalled")
        } catch {
            XCTAssertEqual(error as? ActionError, .appNotInstalled(bundleID: Stubs.BundleID.slack))
        }
        XCTAssertFalse(try isRead(id))
    }

    // MARK: - openNotification: launch throws

    func testLaunchFailureThrowsLaunchFailedWithThatBundleID() async throws {
        let launcher = try XCTUnwrap(launcher)
        let appURL = try XCTUnwrap(URL(fileURLWithPath: "/Applications/Slack.app") as URL?)
        launcher.applicationURLs[Stubs.BundleID.slack] = appURL
        struct BoomError: LocalizedError { var errorDescription: String? {
            "boom"
        } }
        launcher.launchError = BoomError()
        let id = try insertNotification(deepLink: nil)

        do {
            try await makeHandler().openNotification(id: id)
            XCTFail("expected .launchFailed")
        } catch {
            XCTAssertEqual(
                error as? ActionError,
                .launchFailed(bundleID: Stubs.BundleID.slack, reason: "boom")
            )
        }
        XCTAssertFalse(try isRead(id))
    }

    // MARK: - openLink

    func testOpenLinkWithNoDeepLinkThrowsDeepLinkUnresolvable() throws {
        let id = try insertNotification(deepLink: nil)

        XCTAssertThrowsError(try makeHandler().openLink(id: id)) { error in
            XCTAssertEqual(error as? ActionError, .deepLinkUnresolvable(notificationID: id))
        }
    }

    func testOpenLinkNeverFallsBackToActivatingTheApp() throws {
        let launcher = try XCTUnwrap(launcher)
        let appURL = try XCTUnwrap(URL(fileURLWithPath: "/Applications/Slack.app") as URL?)
        launcher.openResult = false
        launcher.applicationURLs[Stubs.BundleID.slack] = appURL
        let id = try insertNotification(deepLink: "slack://channel/abc")

        XCTAssertThrowsError(try makeHandler().openLink(id: id)) { error in
            XCTAssertEqual(error as? ActionError, .deepLinkUnresolvable(notificationID: id))
        }
        XCTAssertEqual(launcher.calls, try [.open(XCTUnwrap(URL(string: "slack://channel/abc")))])
    }

    func testOpenLinkOpensTheLinkAndNothingElse() throws {
        let launcher = try XCTUnwrap(launcher)
        let id = try insertNotification(deepLink: "slack://channel/abc")

        try makeHandler().openLink(id: id)

        XCTAssertEqual(launcher.calls, try [.open(XCTUnwrap(URL(string: "slack://channel/abc")))])
        XCTAssertFalse(try isRead(id)) // Open Link never marks read.
    }

    // MARK: - parsedURL refuses what must never be opened

    /// A `file:` link and a schemeless string are both refused before they can
    /// reach `NSWorkspace`, so a row written by an older resolver cannot open a
    /// local path or hand a plain sentence to the workspace. Both fall through
    /// to app activation like any other dead link — refusing to open something
    /// is not an error worth surfacing.
    func testUnopenableDeepLinksAreRefusedAndFallThrough() async throws {
        for deepLink in ["file:///etc/hosts", "Meeting moved to 3pm", "/private/etc/hosts"] {
            let launcher = FakeAppLauncher()
            let appURL = URL(fileURLWithPath: "/Applications/Slack.app")
            launcher.openResult = true // even a workspace that would say yes never gets asked
            launcher.applicationURLs[Stubs.BundleID.slack] = appURL
            let id = try insertNotification(deepLink: deepLink)

            try await NotificationActionHandler(archive: XCTUnwrap(archive), workspace: launcher)
                .openNotification(id: id)

            XCTAssertNil(OpenAction.parsedURL(deepLink), "\(deepLink) must not parse as openable")
            XCTAssertEqual(
                launcher.calls,
                [.applicationURL(Stubs.BundleID.slack), .launchApplication(appURL)],
                "\(deepLink) must never be handed to the workspace"
            )
        }
    }

    // MARK: - hasPathOrQuery

    func testHasPathOrQuery() throws {
        let cases: [(url: String, expected: Bool)] = [
            ("slack://", false), // bare scheme, no authority-relative path or query
            ("https://example.com", false), // host only
            ("https://example.com/a", true), // path
            ("x://y?q=1", true), // query only
            ("https://example.com?q=1", true), // query only, no path
        ]
        for testCase in cases {
            let url = try XCTUnwrap(URL(string: testCase.url))
            XCTAssertEqual(
                OpenAction.hasPathOrQuery(url),
                testCase.expected,
                "expected hasPathOrQuery(\(testCase.url)) == \(testCase.expected)"
            )
        }
    }

    // MARK: - showsOpenLink

    func testShowsOpenLinkMatchesHasPathOrQueryForAParsedLink() {
        XCTAssertFalse(NotificationActionHandler.showsOpenLink(deepLink: nil))
        XCTAssertFalse(NotificationActionHandler.showsOpenLink(deepLink: ""))
        XCTAssertFalse(NotificationActionHandler.showsOpenLink(deepLink: "slack://"))
        XCTAssertTrue(NotificationActionHandler.showsOpenLink(deepLink: "slack://channel/abc"))
    }

    // MARK: Private

    private var archive: Archive?
    private var launcher: FakeAppLauncher?
    private var handler: NotificationActionHandler?

    private func makeHandler() throws -> NotificationActionHandler {
        let handler = try NotificationActionHandler(
            archive: XCTUnwrap(archive),
            workspace: XCTUnwrap(launcher)
        )
        self.handler = handler
        return handler
    }

    /// Inserts a notification from `Stubs.BundleID.slack`, with `deepLink` as
    /// its stored `deep_link`, and returns its id.
    private func insertNotification(deepLink: String?) throws -> Int64 {
        let archive = try XCTUnwrap(archive)
        let app = try archive.upsertApp(bundleID: Stubs.BundleID.slack, now: Stubs.epoch)
        let appID = try XCTUnwrap(app.id)
        let inserted = try archive.insert(ArchivedNotification(
            uuid: UUID().uuidString,
            appId: appID,
            title: "Fixture message",
            deliveredAt: UnixDate(Stubs.epoch),
            capturedAt: UnixDate(Stubs.epoch),
            deepLink: deepLink
        ))
        return try XCTUnwrap(inserted.id)
    }

    private func isRead(_ id: Int64) throws -> Bool {
        let archive = try XCTUnwrap(archive)
        return try archive.pool.read { db in
            try ArchivedNotification.fetchOne(db, key: id)?.isRead ?? false
        }
    }
}

// MARK: - FakeAppLauncher

/// Records every call it receives and returns scripted results — nothing here
/// ever reaches real `NSWorkspace`. See ``AppLaunching``.
@MainActor
final class FakeAppLauncher: AppLaunching {
    enum Call: Equatable {
        case open(URL)
        case applicationURL(String)
        case launchApplication(URL)
    }

    private(set) var calls: [Call] = []

    /// Scripted return for `open(_:)`.
    var openResult = true
    /// Scripted return for `applicationURL(forBundleID:)`, keyed by bundle id.
    /// Missing keys mean "not installed" (`nil`), same as the real API.
    var applicationURLs: [String: URL] = [:]
    /// When set, `launchApplication(at:)` throws this instead of returning.
    var launchError: Error?

    func open(_ url: URL) -> Bool {
        calls.append(.open(url))
        return openResult
    }

    func applicationURL(forBundleID bundleID: String) -> URL? {
        calls.append(.applicationURL(bundleID))
        return applicationURLs[bundleID]
    }

    func launchApplication(at url: URL) async throws {
        calls.append(.launchApplication(url))
        if let launchError {
            throw launchError
        }
    }
}
