import XCTest

/// Helpers every UI test needs for launching Backglance under test.
///
/// Backglance is an agent app with no windows at launch, so a UI test has to drive the
/// status item. The real helpers land with the first UI test in Phase 2; this file exists
/// so the bundle's `Support/` directory has the shape TESTING.md describes.
extension XCUIApplication {
    /// Launch arguments that put the app in a deterministic state for UI tests: a scratch
    /// archive, no updater, and capture pointed at a fixture rather than the system store.
    static var backglanceTestArguments: [String] {
        ["-BackglanceUITesting", "YES"]
    }
}
