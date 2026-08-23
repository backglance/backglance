import XCTest

/// The menu bar item's right-click menu, driven the way a person drives it.
///
/// This suite exists because the pause submenu was, for one release, unverifiable: it is
/// attached only for the duration of a right click, so nothing outside the app could read it,
/// and `screencapture` on a Mac without Screen Recording permission cannot photograph it
/// either (BACKGLANCE-195). XCUITest can do both — it right-clicks for real, and the menu it
/// opens is in the app's own accessibility tree.
///
/// What is asserted here is *wiring and order*: that the submenu is built, hangs off the right
/// parent, offers its four choices shortest-first, and swaps for "Resume Capture" while paused.
/// The words themselves belong to `PauseCopyTests` in `BackglanceUITests`, which can assert
/// them against `PauseCopy` directly; this bundle does not link `BackglanceUI`, so the titles
/// below are the English baseline the same way `TESTING.md` lists identifiers.
final class StatusItemMenuTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        archiveDirectory = try Self.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
        if let archiveDirectory {
            try? FileManager.default.removeItem(at: archiveDirectory)
        }
        archiveDirectory = nil
        try super.tearDownWithError()
    }

    /// The menu a right click opens, and the four choices under Pause Capture in their
    /// documented order — shortest first, "until I say" last.
    func testPauseSubmenuOffersItsFourChoicesInOrder() throws {
        let app = try launch()
        let menu = openStatusItemMenu(app)

        XCTAssertTrue(menu.menuItems[Self.openWindow].exists)
        XCTAssertTrue(menu.menuItems[Self.settings].exists)
        XCTAssertTrue(menu.menuItems[Self.quit].exists)

        let pause = menu.menuItems[Self.pauseMenu]
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "capture is running, so the menu offers Pause")
        pause.hover()

        for title in Self.pauseChoices {
            XCTAssertTrue(
                menu.menuItems[title].waitForExistence(timeout: 5),
                "\(title) should be one of the pause choices"
            )
        }
        // Order, not just membership: the submenu is a list of durations, and one that reads
        // 1 hour before 15 minutes is wrong in a way no existence check would catch.
        let tops = Self.pauseChoices.map { menu.menuItems[$0].frame.minY }
        XCTAssertEqual(tops, tops.sorted(), "the choices should be offered shortest first")
    }

    /// Picking a duration pauses capture: the item says so, and the menu that offered four
    /// ways to pause now offers the one way back.
    func testPausingSwapsTheSubmenuForResumeAndSaysSo() throws {
        let app = try launch()
        let menu = openStatusItemMenu(app)
        menu.menuItems[Self.pauseMenu].hover()
        XCTAssertTrue(menu.menuItems[Self.pauseChoices[0]].waitForExistence(timeout: 5))
        menu.menuItems[Self.pauseChoices[0]].click()

        XCTAssertTrue(
            waitForItemLabel(app, containing: Self.pausedPhrase),
            "the status item should announce the pause, not only draw it"
        )

        let paused = openStatusItemMenu(app)
        XCTAssertTrue(paused.menuItems[Self.resumeMenu].waitForExistence(timeout: 5))
        XCTAssertFalse(paused.menuItems[Self.pauseMenu].exists, "one or the other, never both")

        paused.menuItems[Self.resumeMenu].click()
        XCTAssertTrue(
            waitForItemLabel(app, containing: Self.pausedPhrase, negated: true),
            "resuming should take the pause back off the item"
        )
    }

    // MARK: Private

    private static let openWindow = "Open Full Window"
    private static let settings = "Settings…"
    private static let quit = "Quit Backglance"
    private static let pauseMenu = "Pause Capture"
    private static let resumeMenu = "Resume Capture"
    private static let pauseChoices = ["For 15 Minutes", "For 1 Hour", "Until Tomorrow", "Until I Resume"]
    /// The state clause `StatusItemAccessibility` appends while capture is paused. The
    /// tooltip carries the deadline too ("capture paused until 17:02"); the label does not,
    /// so this is the part both agree on.
    private static let pausedPhrase = "capture paused"

    private var archiveDirectory: URL?
    private var app: XCUIApplication?

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatusItemMenuTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A running app with capture actually running, which is what puts Pause in the menu.
    private func launch() throws -> XCUIApplication {
        let launch = BackglanceLaunch(
            fullDiskAccess: "granted",
            hasCompletedOnboarding: true,
            storePath: BackglanceLaunch.fixtureStorePath
        )
        let app = try launch.app(archiveDirectory: XCTUnwrap(archiveDirectory))
        app.launch()
        self.app = app
        return app
    }

    private func statusItem(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["statusItem.button"]
    }

    /// Right-clicks the item and returns *its* menu.
    ///
    /// Scoped to the status item rather than reaching for `app.menuItems`, which searches the
    /// whole application: the main menu bar carries a "Settings…" and a "Quit Backglance" of
    /// its own, so an app-wide query answers even when this menu never opened, and the test
    /// passes for the wrong reason. Waiting on the menu element also gives the click the beat
    /// it needs — the menu is attached, opened and detached inside one click handler.
    @discardableResult
    private func openStatusItemMenu(_ app: XCUIApplication) -> XCUIElement {
        let item = statusItem(app)
        XCTAssertTrue(item.waitForExistence(timeout: 10), "the menu bar item is the app's only permanent UI")
        item.rightClick()
        let menu = item.descendants(matching: .menu).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "a right click should open the item's menu")
        return menu
    }

    /// The label is rendered from the capture state the engine reports, so it settles a beat
    /// after the click rather than on it.
    private func waitForItemLabel(
        _ app: XCUIApplication,
        containing phrase: String,
        negated: Bool = false,
        timeout: TimeInterval = 10
    ) -> Bool {
        let contains = NSPredicate(format: "label CONTAINS[c] %@", phrase)
        let predicate = negated ? NSCompoundPredicate(notPredicateWithSubpredicate: contains) : contains
        let matched = expectation(for: predicate, evaluatedWith: statusItem(app))
        return XCTWaiter.wait(for: [matched], timeout: timeout) == .completed
    }
}
