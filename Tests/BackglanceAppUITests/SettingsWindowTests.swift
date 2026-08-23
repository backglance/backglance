import XCTest

/// The settings window's seven panes, and the tab bar that has to show them.
///
/// This suite exists because the window shipped at a width where macOS 26 collapsed every
/// tab into the toolbar's `»` overflow menu (BACKGLANCE-249). Nothing failed, nothing
/// logged, and the panes were three clicks deep behind a chevron with no label — the kind of
/// regression only a rendered window can catch, which is why it lives in the bundle that
/// drives one.
///
/// The assertions are deliberately not about the toolbar. Where macOS draws the tabs is
/// Apple's business and it changes between releases — 26 puts them in the toolbar, earlier
/// versions draw them in the content. What this suite fixes in place is that all seven are
/// on screen and each one switches the pane behind it.
final class SettingsWindowTests: XCTestCase {
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

    /// Every pane is one visible click away, not behind an overflow menu.
    func testAllSevenTabsAreVisible() throws {
        let app = try openSettings()

        for pane in Self.panes {
            XCTAssertTrue(
                app.control(pane.title).waitForExistence(timeout: 5),
                "\(pane.title) should be a visible tab, not an item in the toolbar's overflow menu"
            )
        }
        XCTAssertFalse(
            app.descendants(matching: .popUpButton)
                .matching(NSPredicate(format: "label BEGINSWITH 'more toolbar items'")).firstMatch.exists,
            "a toolbar overflow means the tabs did not fit — see SettingsWindowController.contentWidth"
        )
    }

    /// And each one leads somewhere: the pane behind the tab is the pane the tab names.
    func testEachTabShowsItsPane() throws {
        let app = try openSettings()

        for pane in Self.panes {
            let tab = app.control(pane.title)
            XCTAssertTrue(tab.waitForExistence(timeout: 5))
            tab.click()
            XCTAssertTrue(
                app.control(pane.marker).waitForExistence(timeout: 5),
                "the \(pane.title) tab should show the pane that draws \(pane.marker)"
            )
        }
    }

    // MARK: Private

    /// The panes in the order the window offers them, each with an element that only that
    /// pane draws. Six of them are the `settings.tab.<pane>` identifier on the pane's own
    /// scroll view; Apps is a `NavigationSplitView`, whose identifier does not surface the
    /// same way, so its "Select an app" placeholder stands in.
    private static let panes: [(title: String, marker: String)] = [
        ("General", "settings.tab.general"),
        ("Apps", "apps.detail.empty"),
        ("Privacy", "settings.tab.privacy"),
        ("Rules", "settings.tab.rules"),
        ("Updates", "settings.tab.updates"),
        ("Permissions", "settings.tab.permissions"),
        ("Status", "settings.tab.status"),
    ]

    private var archiveDirectory: URL?
    private var app: XCUIApplication?

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsWindowTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Opens Settings from the status item's menu, which is the route a user has.
    private func openSettings() throws -> XCUIApplication {
        let launch = BackglanceLaunch(
            fullDiskAccess: "granted",
            hasCompletedOnboarding: true,
            storePath: BackglanceLaunch.fixtureStorePath
        )
        let app = try launch.app(archiveDirectory: XCTUnwrap(archiveDirectory))
        app.launch()
        self.app = app

        let item = app.descendants(matching: .any)["statusItem.button"]
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.rightClick()
        let menu = item.descendants(matching: .menu).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.menuItems["Settings…"].click()

        XCTAssertTrue(
            app.windows["Backglance Settings"].waitForExistence(timeout: 10),
            "the menu's Settings… item should open the settings window"
        )
        // The window opens behind the test runner, and a tab that is not on screen cannot be
        // clicked.
        app.activate()
        return app
    }
}
