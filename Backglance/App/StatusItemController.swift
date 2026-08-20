import AppKit
import BackglanceCore
import BackglanceUI
import SwiftUI

// MARK: - StatusItemController

/// The menu bar item: Backglance's only permanent piece of UI.
///
/// AppKit owns the status item and the popover; SwiftUI starts inside the
/// hosting controller. The split is not incidental — `NSPopover` positioning,
/// transient click-away behaviour and the status item's own click handling have
/// no SwiftUI equivalent that behaves correctly in an `LSUIElement` app.
///
/// This is also where "the user looked" is decided: opening the popover
/// snapshots the unread anchor and closing it advances it, so the divider and
/// the badge agree with what was actually on screen
/// (docs/features/TIMELINE.md#statusitemcontroller).
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    // MARK: Lifecycle

    init(store: TimelineStore, menuActions: MenuActions) {
        self.store = store
        self.menuActions = menuActions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let hosting = NSHostingController(rootView: MenuBarPopoverView().environment(store))
        // We own the size; letting the hosting view drive it makes the popover
        // resize itself as rows load, which reads as a flicker on every open.
        hosting.sizingOptions = []
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: BackglanceUI.popoverSize.width, height: BackglanceUI.popoverSize.height)
        popover.behavior = .transient
        // One of the three things that keep open-to-first-paint under 100 ms,
        // together with the prebuilt hosting controller and a store that
        // already holds the newest page (docs/deployment/PERFORMANCE_GUIDE.md).
        popover.animates = false
        popover.delegate = self

        if let button = statusItem.button {
            button.image = Self.image(named: "StatusIcon")
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel(String(localized: "Backglance"))
        }
        observeStore()
    }

    // MARK: Internal

    /// What the right-click menu can do. Passed in rather than reached for:
    /// pausing capture belongs to the app delegate, which owns the engine.
    struct MenuActions {
        var openWindow: () -> Void
        var pauseForAnHour: () -> Void
        var resume: () -> Void
    }

    /// Shows the popover, or hides it if it is already up. Bound to the status
    /// item's left click and to ⌃⌥N.
    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else {
            return
        }
        // Snapshot before showing: the divider the user sees has to reflect the
        // moment before they clicked, not after.
        store.surfaceWillOpen()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // An agent app is never frontmost on its own, so the popover has to ask
        // for key status or the timeline cannot take a keystroke.
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_: Notification) {
        store.surfaceDidClose()
    }

    // MARK: Private

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let store: TimelineStore
    private let menuActions: MenuActions

    /// The status item's template image by asset name.
    ///
    /// A named lookup rather than an image literal because the name is chosen
    /// at run time from the capture state — there is no literal to write.
    private static func image(named name: String) -> NSImage? {
        NSImage(named: name)
    }

    private static func imageName(for state: TimelineCaptureState) -> String {
        switch state {
        case .running:
            "StatusIcon"

        case .paused:
            "StatusIconPaused"

        case .noFullDiskAccess,
             .degraded,
             .stopped:
            "StatusIconDegraded"
        }
    }

    private static func tooltip(count: Int, state: TimelineCaptureState) -> String {
        switch state {
        case .paused:
            String(localized: "Backglance — capture paused")

        case .noFullDiskAccess:
            String(localized: "Backglance — needs Full Disk Access")

        case let .degraded(message):
            String(localized: "Backglance — \(message)")

        case .stopped:
            String(localized: "Backglance — capture stopped")

        case .running:
            if count == 0 {
                String(localized: "Backglance")
            } else {
                String(localized: "Backglance — \(count) unread")
            }
        }
    }

    @objc
    private func statusItemClicked(_: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            // Assigning a menu makes the *next* click open it, so the click is
            // re-sent and the menu detached again — otherwise the left click
            // would open the menu instead of the popover from then on.
            statusItem.menu = contextMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        togglePopover()
    }

    /// Re-arms itself: `withObservationTracking` fires once per change, so the
    /// callback subscribes again for the next one.
    private func observeStore() {
        withObservationTracking {
            render(badge: store.unreadBadgeCount, state: store.captureState)
        } onChange: {
            Task { @MainActor [weak self] in self?.observeStore() }
        }
    }

    private func render(badge count: Int, state: TimelineCaptureState) {
        guard let button = statusItem.button else {
            return
        }
        button.image = Self.image(named: Self.imageName(for: state))
        // The count is a suffix on the icon rather than a red dot: a menu bar
        // is monochrome, and a number is legible at a glance where a dot is not.
        button.title = count == 0 ? "" : (count >= Archive.unreadBadgeCap ? " 99+" : " \(count)")
        button.imagePosition = count == 0 ? .imageOnly : .imageLeft
        button.toolTip = Self.tooltip(count: count, state: state)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(String(localized: "Open Full Window"), #selector(openWindow)))
        menu.addItem(.separator())
        if case .paused = store.captureState {
            menu.addItem(item(String(localized: "Resume Capture"), #selector(resumeCapture)))
        } else {
            menu.addItem(item(String(localized: "Pause Capture for 1 Hour"), #selector(pauseCapture)))
        }
        // "Settings…" belongs here (docs/features/TIMELINE.md#statusitemcontroller)
        // and joins the menu with the settings scene itself. A menu item that
        // opens nothing is worse than one that is not there yet.
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Backglance"),
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc
    private func openWindow() {
        menuActions.openWindow()
    }

    @objc
    private func pauseCapture() {
        menuActions.pauseForAnHour()
    }

    @objc
    private func resumeCapture() {
        menuActions.resume()
    }
}
