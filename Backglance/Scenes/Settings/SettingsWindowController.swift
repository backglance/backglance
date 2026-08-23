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
        updates: UpdatesSettingsModel,
        permissions: PermissionsSettingsModel,
        status: StatusSettingsModel
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 620),
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
                updates: updates,
                permissions: permissions,
                status: status
            )
        )
        // The window owns its size. Left to the hosting controller, the form's
        // fitting size came back zero-width — measured, not guessed: the
        // autosaved frame was "0 260 0 32".
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: Self.contentWidth, height: 620))
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    // MARK: Internal

    /// Wide enough for the tab bar to be a tab bar.
    ///
    /// macOS 26 draws a `TabView`'s tabs in the window's toolbar and collapses them into a `»`
    /// overflow menu when they do not fit. At the 520 this window shipped with, that meant
    /// seven panes and not one visible tab (BACKGLANCE-249).
    ///
    /// Both thresholds below were measured, by opening the window at a series of widths and
    /// reading the toolbar out of the accessibility tree — not guessed from label lengths:
    ///
    /// - 770 collapses, 780 shows all seven.
    /// - The **Apps** pane is the one that matters: its `NavigationSplitView` puts a "Hide
    ///   Sidebar" button in the same toolbar, and that pushes the tabs back into the overflow
    ///   at 820. 860 is where all seven survive with Apps selected.
    ///
    /// 900 leaves headroom over that, because a width chosen at its threshold collapses the
    /// first time a label gets longer — which the v2.0 translations will do
    /// (docs/reference/INTERNATIONALIZATION.md). `SettingsWindowTests` fails if the tabs stop
    /// being visible, on any pane, for any reason.
    static let contentWidth: CGFloat = 900

    func show() {
        // An agent app is never frontmost on its own, so a settings window that
        // did not activate would open behind whatever the user was doing.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
