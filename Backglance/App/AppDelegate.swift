import AppKit
import os

/// Application delegate for the Backglance agent app.
///
/// Backglance has no Dock icon and no windows at launch: `LSUIElement` in `Info.plist`
/// makes it an agent, and everything the user sees hangs off the status item.
///
/// The delegate is where the pieces that cannot live in a package get wired together —
/// `Archive.shared`, `CaptureEngine`, `StatusItemController`, the ⌃⌥N hotkey, the
/// `backglance://` handler and the Sparkle controller. None of that exists yet; this is
/// the launch skeleton the rest of Phase 0 builds on.
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: Internal

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement already does this at launch. Setting it again is what keeps the app
        // an agent if it is ever launched in a way that bypasses the Info.plist key, and
        // it documents the intent at the one place a reader looks for it.
        NSApp.setActivationPolicy(.accessory)
        logger.notice("Backglance launched as an agent app")
    }

    /// macOS 14 warns on delegates that do not answer this; Backglance restores no state.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Private

    private let logger = Logger(subsystem: "app.backglance.Backglance", category: "ui")
}
