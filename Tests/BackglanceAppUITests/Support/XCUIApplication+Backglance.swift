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

    init(fullDiskAccess: String, hasCompletedOnboarding: Bool = false, storePath: String? = nil) {
        self.fullDiskAccess = fullDiskAccess
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.storePath = storePath
    }

    // MARK: Internal

    /// The synthetic macOS 26 store, which is the one every fixture test already reads.
    static var fixtureStorePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Support/
            .deletingLastPathComponent() // BackglanceAppUITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // the repository root
            .appendingPathComponent("Tests/Fixtures/SystemStore/macOS26/store.db")
            .path
    }

    /// `granted`, `denied`, or `storeMissing`.
    let fullDiskAccess: String
    let hasCompletedOnboarding: Bool
    /// A fixture store to capture from, for a test that needs capture *running* rather than
    /// degraded. Faking the permission does not conjure a readable store: on a Mac without the
    /// real grant the engine still ends up in `noFullDiskAccess`, and anything that varies by
    /// capture state — the status item's glyph, its label, the pause menu — would be asserted
    /// against the wrong state. `BACKGLANCE_STORE_PATH` is DEBUG-only, like the FDA override.
    let storePath: String?

    /// A launched app, waiting for its first screen.
    func app(archiveDirectory: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BACKGLANCE_FAKE_FDA"] = fullDiskAccess
        app.launchEnvironment["BACKGLANCE_ARCHIVE_PATH"] = archiveDirectory
            .appendingPathComponent("archive.sqlite").path
        if let storePath {
            app.launchEnvironment["BACKGLANCE_STORE_PATH"] = storePath
        }
        app.launchArguments += [
            "-onboarding.completedVersion", hasCompletedOnboarding ? "1" : "0",
            "-onboarding.skippedFDA", "NO",
            // `BACKGLANCE_ARCHIVE_PATH` redirects the archive, but not `UserDefaults` — pause
            // lives there (`PauseSettings.pausedUntilKey`) so that it survives a relaunch, and
            // the domain is the real app's. Without this a pause left behind by an earlier run,
            // or by the developer's own Backglance, decides what this run's menu offers.
            "-capture.pausedUntil", "0",
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

    /// A control by identifier, whatever AppKit decided it was.
    ///
    /// Matching on `.any` rather than `.button` because "Skip for now" is
    /// `.buttonStyle(.link)`, which macOS exposes with the link role — a `buttons[…]` query
    /// misses it and reports "does not exist", which reads like a missing button rather than
    /// a role mismatch. `isEnabled` and `click()` work the same on either role.
    func control(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier].firstMatch
    }
}
