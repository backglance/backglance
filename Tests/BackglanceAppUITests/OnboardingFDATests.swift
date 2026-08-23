import XCTest

/// Setup, driven the way a person drives it, on a Mac with the permission and on one without.
///
/// The reason this is a UI test rather than more `OnboardingModelTests` is the wiring: the
/// model's transitions are already covered, and what is left to go wrong is everything between
/// it and the screen — a window that never opens, a button bound to nothing, a step whose view
/// was never added to the switch. None of that is visible from a unit test.
///
/// Both permission states are reachable because `BACKGLANCE_FAKE_FDA` forces the probe's answer
/// in DEBUG builds. There is no API to grant or revoke Full Disk Access, so without that seam
/// exactly one of these tests could run on any given machine.
final class OnboardingFDATests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        archiveDirectory = try Self.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let archiveDirectory {
            try? FileManager.default.removeItem(at: archiveDirectory)
        }
        archiveDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Without the permission

    /// The path most first-time users take: read the three explanation screens, arrive at
    /// Grant, and find Continue unavailable because the permission is not there.
    func testSetupStopsAtGrantWithoutAccess() throws {
        let app = try launch(fullDiskAccess: "denied")

        XCTAssertTrue(app.waitForStep("onboarding.welcome"), "setup should open on a fresh Mac")
        app.control("onboarding.continue").click()
        XCTAssertTrue(app.waitForStep("onboarding.whyFDA"))
        app.control("onboarding.continue").click()
        XCTAssertTrue(app.waitForStep("onboarding.whatWeRead"))
        app.control("onboarding.continue").click()

        XCTAssertTrue(app.waitForStep("onboarding.grant"))
        XCTAssertTrue(app.waitForStep("onboarding.grant.status.waiting"), "it should say it is waiting")
        XCTAssertFalse(app.control("onboarding.continue").isEnabled, "Continue is the one blocked transition")
    }

    /// 🔒 Skipping is a supported outcome, not a failure. Someone evaluating the app is
    /// entitled to look around before granting it the ability to read every notification they
    /// receive, and the way out has to work from the first screen.
    func testSkippingClosesSetupAndLeavesTheAppRunning() throws {
        let app = try launch(fullDiskAccess: "denied")
        XCTAssertTrue(app.waitForStep("onboarding.welcome"))

        app.control("onboarding.skip").click()

        XCTAssertTrue(waitForWindowToClose(app), "the setup window should close")
        XCTAssertNotEqual(app.state, .notRunning, "and the app should still be running")
    }

    func testBackReturnsToThePreviousScreen() throws {
        let app = try launch(fullDiskAccess: "denied")
        XCTAssertTrue(app.waitForStep("onboarding.welcome"))
        app.control("onboarding.continue").click()
        XCTAssertTrue(app.waitForStep("onboarding.whyFDA"))

        app.control("onboarding.back").click()

        XCTAssertTrue(app.waitForStep("onboarding.welcome"))
    }

    // MARK: - With the permission

    /// The Grant screen on a Mac that already has the permission: it says so, and Continue
    /// works.
    func testGrantIsAcknowledgedAndSetupCanFinish() throws {
        let app = try launch(fullDiskAccess: "granted")
        XCTAssertTrue(app.waitForStep("onboarding.welcome"))
        advance(app, times: 3)

        XCTAssertTrue(app.waitForStep("onboarding.grant"))
        XCTAssertTrue(app.waitForStep("onboarding.grant.status.granted"), "it should acknowledge the grant")
        XCTAssertTrue(app.control("onboarding.continue").isEnabled)

        app.control("onboarding.continue").click()
        XCTAssertTrue(app.waitForStep("onboarding.done"))
    }

    /// Finishing closes setup. The last screen's button says "Open Backglance", and that is
    /// what it does.
    func testFinishingClosesSetup() throws {
        let app = try launch(fullDiskAccess: "granted")
        XCTAssertTrue(app.waitForStep("onboarding.welcome"))
        advance(app, times: 4)
        XCTAssertTrue(app.waitForStep("onboarding.done"))

        app.control("onboarding.continue").click()

        XCTAssertTrue(waitForWindowToClose(app))
    }

    /// The one rendered plural a test can reach, and the reason it can: the app resolves
    /// `Localizable.xcstrings` against `Bundle.main`, which is `Backglance.app` here and the
    /// xctest runner in every other bundle (BACKGLANCE-238).
    ///
    /// It shipped for one release as the literal string `Imported ^[0 notification](inflect:
    /// true).` — automatic grammar agreement compiles to nothing in this project, so the
    /// markup went to the screen (BACKGLANCE-248). Nothing below asserts the count itself;
    /// what it asserts is that a *catalog* answered, because the fallback for a missing key
    /// is the key, and the key still has the markup in it.
    func testTheImportLineIsPluralisedByTheCatalog() throws {
        let app = try launch(fullDiskAccess: "granted", storePath: BackglanceLaunch.fixtureStorePath)
        XCTAssertTrue(app.waitForStep("onboarding.welcome"))
        advance(app, times: 4)
        XCTAssertTrue(app.waitForStep("onboarding.done"))

        // `onboarding.import.finished` *is* the sentence — the running state shows the same
        // one with a climbing count, so waiting for the finished element is both the wait for
        // the import and the way to read what it reported.
        let line = app.control("onboarding.import.finished")
        XCTAssertTrue(
            line.waitForExistence(timeout: 60),
            "the first-launch import should finish against a 250-record fixture"
        )
        let sentence = (line.value as? String) ?? line.label
        XCTAssertFalse(sentence.contains("^["), "markup on screen means the catalog was not consulted: \(sentence)")
        XCTAssertFalse(sentence.contains("inflect"), "markup on screen: \(sentence)")
        // The macOS 26 fixture holds 250 records, and importing it is what this screen reports.
        XCTAssertEqual(sentence, "Imported 250 notifications.")
    }

    // MARK: - Not on every launch

    /// Setup is a first-run thing. Someone who has been through it — or skipped it — gets the
    /// banner and nothing else; there is no reminder, by design.
    func testSetupDoesNotOpenAgainOnceItIsDone() throws {
        let app = try launch(fullDiskAccess: "denied", hasCompletedOnboarding: true)

        XCTAssertFalse(
            app.waitForStep("onboarding.welcome", timeout: 3),
            "a Mac that has been through setup should not see it again"
        )
        XCTAssertNotEqual(app.state, .notRunning)
    }

    // MARK: Private

    private var archiveDirectory: URL?

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnboardingFDATests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func launch(
        fullDiskAccess: String,
        hasCompletedOnboarding: Bool = false,
        storePath: String? = nil
    ) throws -> XCUIApplication {
        let launch = BackglanceLaunch(
            fullDiskAccess: fullDiskAccess,
            hasCompletedOnboarding: hasCompletedOnboarding,
            storePath: storePath
        )
        let app = try launch.app(archiveDirectory: XCTUnwrap(archiveDirectory))
        app.launch()
        return app
    }

    private func advance(_ app: XCUIApplication, times: Int) {
        for _ in 0 ..< times {
            let button = app.control("onboarding.continue")
            guard button.waitForExistence(timeout: 5), button.isEnabled else {
                return
            }
            button.click()
        }
    }

    /// Backglance is an agent app with no Dock icon, so "setup finished" is the window going
    /// away rather than the app quitting.
    private func waitForWindowToClose(_ app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        let gone = expectation(for: NSPredicate(format: "count == 0"), evaluatedWith: app.windows)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }
}
