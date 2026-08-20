import AppKit
import SwiftUI

// MARK: - SettingsWindowController

/// One settings window, created on first use and reused after.
///
/// `NSWindowController` rather than SwiftUI's `Settings` scene: `Settings` only
/// exists inside a SwiftUI `App`, and Backglance's shell is an `NSApplication`
/// delegate with no scenes at all — everything hangs off the status item.
@MainActor
final class SettingsWindowController: NSWindowController {
    // MARK: Lifecycle

    convenience init(search: SearchService) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Backglance Settings")
        window.setFrameAutosaveName("SettingsWindow")
        window.contentViewController = NSHostingController(rootView: SettingsView(search: search))
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    // MARK: Internal

    func show() {
        // An agent app is never frontmost on its own, so a settings window that
        // did not activate would open behind whatever the user was doing.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
