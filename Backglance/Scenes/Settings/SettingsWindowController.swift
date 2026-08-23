import AppKit
import BackglanceUI
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

    convenience init(
        general: GeneralSettingsModel,
        apps: AppsSettingsModel,
        privacy: PrivacySettingsModel,
        rules: RulesSettingsModel,
        permissions: PermissionsSettingsModel,
        status: StatusSettingsModel
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Backglance Settings")
        window.setFrameAutosaveName("SettingsWindow")
        let hosting = NSHostingController(
            rootView: SettingsView(
                general: general,
                apps: apps,
                privacy: privacy,
                rules: rules,
                permissions: permissions,
                status: status
            )
        )
        // The window owns its size. Left to the hosting controller, the form's
        // fitting size came back zero-width — measured, not guessed: the
        // autosaved frame was "0 260 0 32".
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 520, height: 620))
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
