import XCTest

/// The three catalog plurals nothing else can see rendered, read off the running app.
///
/// `StatusItemAccessibility.unreadPhrase`, `UndoToastView.message` and
/// `ExportSheet.title` interpolate a count and leave the singular/plural to the
/// catalog entry's variations (docs/reference/INTERNATIONALIZATION.md#plural-rules).
/// Their unit tests cannot verify that: those bundles have no host application, so
/// `Bundle.main` is the xctest runner, every lookup falls back to the key, and a
/// conversion once shipped the singular to VoiceOver with eight green tests — this
/// suite is the missing half that lets the conversion stand. The exact copy asserted
/// here is deliberate: the singular reading as a singular *is* the behaviour under
/// test, so a reworded string should fail it, unlike the flow suites next door.
/// The spoken label is asserted for both branches through the full UI; the toast and
/// the export sheet get their singular through the UI and both branches from the
/// built app's compiled catalog, because the multi-selection their plural needs
/// cannot be made from this bundle (keystrokes and held modifiers only ever reach
/// the *active* app, which an agent app under the runner never is).
///
/// Rows come from `DebugSeeding` (`BACKGLANCE_SEED_UNREAD`, DEBUG-only): this bundle
/// links nothing, so the app seeding its own already-redirected archive is the one
/// way a test gets a timeline with content on it.
final class PluralRenderingTests: XCTestCase {
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

    /// One unread row: the spoken label uses the `one` variation, exactly.
    func testStatusItemLabelIsSingularForOneUnread() throws {
        let app = try launch(seedUnread: 1)
        XCTAssertTrue(
            waitForItemLabel(app, equalTo: "Backglance, 1 unread notification"),
            "got: \(statusItem(app).label)"
        )
    }

    /// Three unread rows: the `other` variation, with the exact count.
    func testStatusItemLabelIsPluralForThreeUnread() throws {
        let app = try launch(seedUnread: 3)
        XCTAssertTrue(
            waitForItemLabel(app, equalTo: "Backglance, 3 unread notifications"),
            "got: \(statusItem(app).label)"
        )
    }

    /// Deleting one row renders the toast's singular, in the real UI.
    ///
    /// Mouse-only, via the row's own context menu, and singular-only: neither
    /// keystrokes nor held modifiers reach an `LSUIElement` app under XCUITest —
    /// both route to the *active* application, and the agent app is never
    /// `.runningForeground` while the runner holds focus (the same fact
    /// `OnboardingFDATests` documents). That rules out ⌫, ⌘A and ⌘-click alike, so
    /// no multi-selection can be made here and the plural branch is asserted from
    /// the built app's compiled catalog instead —
    /// ``testPluralVariationsResolveFromTheBuiltAppsCatalog()``. BACKGLANCE-253
    /// tracks the by-hand keyboard check this cannot replace.
    func testDeleteToastRendersTheSingular() throws {
        let app = try launch(seedUnread: 1)
        let window = try openTimelineWindow(app)
        let row = timelineRows(window).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the seeded row should be on the timeline")

        row.click()
        let menu = contextMenu(of: row, in: app)
        menu.menuItems["Delete"].click()
        XCTAssertTrue(
            app.staticTexts["Deleted 1 notification"].waitForExistence(timeout: 10),
            "one deleted row should read as a singular"
        )
    }

    /// Both variations of all three converted keys, resolved from the app under
    /// test's own compiled resources — the same `Localizable.stringsdict` the
    /// running app's `String(localized:)` reads, which is what makes this a
    /// rendered-form check rather than a key-fallback one (the unit bundles'
    /// limitation). The multi-row UI routes to the toast and the export sheet are
    /// unreachable under XCUITest (see ``testDeleteToastRendersTheSingular()``),
    /// so this is where their plural branches are pinned.
    func testPluralVariationsResolveFromTheBuiltAppsCatalog() throws {
        let bundle = try builtAppBundle()
        func resolved(_ key: String, _ count: Int) -> String {
            String.localizedStringWithFormat(bundle.localizedString(forKey: key, value: "", table: nil), count)
        }

        XCTAssertEqual(resolved("Deleted %lld notifications", 1), "Deleted 1 notification")
        XCTAssertEqual(resolved("Deleted %lld notifications", 2), "Deleted 2 notifications")
        XCTAssertEqual(resolved("Export %lld Notifications", 1), "Export 1 Notification")
        XCTAssertEqual(resolved("Export %lld Notifications", 2), "Export 2 Notifications")
        XCTAssertEqual(
            resolved("Backglance, %lld unread notifications", 1),
            "Backglance, 1 unread notification"
        )
        XCTAssertEqual(
            resolved("Backglance, %lld unread notifications", 3),
            "Backglance, 3 unread notifications"
        )
    }

    /// The export sheet's title off a one-row selection, in the real UI. The
    /// two-row plural is pinned by
    /// ``testPluralVariationsResolveFromTheBuiltAppsCatalog()`` — see
    /// ``testDeleteToastRendersTheSingular()`` for why no multi-selection can be
    /// made from this bundle.
    func testExportSheetTitleRendersTheSingular() throws {
        let app = try launch(seedUnread: 1)
        let window = try openTimelineWindow(app)
        let row = timelineRows(window).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the seeded row should be on the timeline")

        row.click()
        let menu = contextMenu(of: row, in: app)
        menu.menuItems["Export Selection…"].click()
        XCTAssertTrue(
            app.staticTexts["Export 1 Notification"].waitForExistence(timeout: 10),
            "a one-row selection should title the sheet in the singular"
        )
        app.control("export.cancel").click()
    }

    // MARK: Private

    private var archiveDirectory: URL?
    private var app: XCUIApplication?

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluralRenderingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A running app with capture running (so the label carries no state clause) and
    /// `seedUnread` synthetic rows already archived, unread.
    private func launch(seedUnread: Int) throws -> XCUIApplication {
        let launch = BackglanceLaunch(
            fullDiskAccess: "granted",
            hasCompletedOnboarding: true,
            storePath: BackglanceLaunch.fixtureStorePath,
            seedUnread: seedUnread
        )
        let app = try launch.app(archiveDirectory: XCTUnwrap(archiveDirectory))
        app.launch()
        self.app = app
        return app
    }

    private func statusItem(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["statusItem.button"]
    }

    /// The label settles once the engine has reported `running` and the unread count
    /// has been read, a beat after launch — same waiting shape as
    /// `StatusItemMenuTests.waitForItemLabel`.
    private func waitForItemLabel(
        _ app: XCUIApplication,
        equalTo expected: String,
        timeout: TimeInterval = 15
    ) -> Bool {
        let predicate = NSPredicate(format: "label == %@", expected)
        let matched = expectation(for: predicate, evaluatedWith: statusItem(app))
        return XCTWaiter.wait(for: [matched], timeout: timeout) == .completed
    }

    /// Opens the full window the way a person does — the status item menu's first item.
    private func openTimelineWindow(_ app: XCUIApplication) throws -> XCUIElement {
        let item = statusItem(app)
        XCTAssertTrue(item.waitForExistence(timeout: 10), "the menu bar item is the app's only permanent UI")
        item.rightClick()
        let menu = item.descendants(matching: .menu).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "a right click should open the item's menu")
        menu.menuItems["Open Full Window"].click()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Open Full Window should open one")
        return window
    }

    /// Every timeline row, seeded or otherwise, by its stable identifier prefix.
    private func timelineRows(_ window: XCUIElement) -> XCUIElementQuery {
        window.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'timeline.row.'"))
    }

    /// Right-clicks the row and returns *its* menu. Scoping matters for the same
    /// reason it does in `StatusItemMenuTests` — the app's main menu bar has a
    /// "Delete" of its own, so an app-wide `menuItems` query matches twice — but
    /// SwiftUI attaches a `.contextMenu` at the application level rather than under
    /// the row (an `NSStatusItem`'s menu, by contrast, is the item's descendant), so
    /// the row menu is picked out by its content: only it carries
    /// "Export Selection…".
    private func contextMenu(of row: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        row.rightClick()
        let menu = app.menus.containing(.menuItem, identifier: "Export Selection…").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "a right click should open the row's context menu")
        return menu
    }

    /// The app under test's own bundle, which sits next to the runner in the
    /// built-products directory.
    private func builtAppBundle() throws -> Bundle {
        let products = Bundle(for: Self.self).bundleURL // …/PlugIns/BackglanceAppUITests.xctest
            .deletingLastPathComponent() // PlugIns/
            .deletingLastPathComponent() // Contents/
            .deletingLastPathComponent() // BackglanceAppUITests-Runner.app
            .deletingLastPathComponent() // the products directory
        return try XCTUnwrap(
            Bundle(url: products.appendingPathComponent("Backglance.app")),
            "Backglance.app should sit next to the runner in the products directory"
        )
    }
}
