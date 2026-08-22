import XCTest

// MARK: - BackglanceLaunch

/// How a UI test decides what kind of Mac Backglance thinks it is running on.
///
/// The three things a test has to control, and why each needs controlling:
///
/// - **Full Disk Access.** There is no API to grant or revoke it, and the machine running the
///   test has whatever state it has. `BACKGLANCE_FAKE_FDA` is the DEBUG-only override that
///   makes "a Mac without the grant" and "a Mac with it" both reachable in one run.
/// - **The archive.** `BACKGLANCE_ARCHIVE_PATH` points the whole support directory at a
///   temporary one, so a UI test never touches the notifications of whoever is running it.
/// - **Onboarding's own state.** Passed through the *argument domain*, which outranks anything
///   already written, so a developer whose real Backglance has completed setup still gets a
///   first run.
struct BackglanceLaunch {
    // MARK: Lifecycle

    init(fullDiskAccess: String, hasCompletedOnboarding: Bool = false) {
        self.fullDiskAccess = fullDiskAccess
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    // MARK: Internal

    /// `granted`, `denied`, or `storeMissing`.
    let fullDiskAccess: String
    let hasCompletedOnboarding: Bool

    /// A launched app, waiting for its first screen.
    func app(archiveDirectory: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BACKGLANCE_FAKE_FDA"] = fullDiskAccess
        app.launchEnvironment["BACKGLANCE_ARCHIVE_PATH"] = archiveDirectory
            .appendingPathComponent("archive.sqlite").path
        app.launchArguments += [
            "-onboarding.completedVersion", hasCompletedOnboarding ? "1" : "0",
            "-onboarding.skippedFDA", "NO",
        ]
        return app
    }
}

// MARK: - XCUIApplication + onboarding

extension XCUIApplication {
    /// The onboarding window, once it exists.
    var onboarding: XCUIElement {
        windows.element(boundBy: 0)
    }

    /// Waits for a screen to be the one showing.
    ///
    /// By accessibility identifier rather than by copy: these tests are about the flow, and a
    /// reworded headline should not fail them (docs/reference/ACCESSIBILITY.md#identifiers-for-ui-tests).
    @discardableResult
    func waitForStep(_ identifier: String, timeout: TimeInterval = 10) -> Bool {
        descendants(matching: .any)[identifier].waitForExistence(timeout: timeout)
    }

    func button(_ identifier: String) -> XCUIElement {
        descendants(matching: .button)[identifier]
    }
}
