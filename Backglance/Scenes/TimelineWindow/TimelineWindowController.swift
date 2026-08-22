import AppKit
import BackglanceUI
import SwiftUI

// MARK: - TimelineWindowController

/// The full timeline window: one `NSWindow`, created the first time it is asked
/// for and reused forever after.
///
/// Closing hides it rather than destroying it (`isReleasedWhenClosed = false`),
/// because the store behind it keeps observing either way — rebuilding the
/// window would throw away scroll position and selection to save nothing. The
/// frame is left to AppKit's autosave, so the window reopens where the user put
/// it, on the display they put it on
/// (docs/features/TIMELINE.md#window-management).
///
/// Backglance is `LSUIElement`, so showing a window means activating the app by
/// hand: an agent app is never frontmost on its own, and a window that opens
/// behind whatever the user was doing reads as a window that did not open.
@MainActor
final class TimelineWindowController: NSWindowController {
    // MARK: Lifecycle

    convenience init(
        store: TimelineStore,
        banners: CaptureBannerModel? = nil,
        actions dispatcher: (any ActionDispatching)? = nil
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Backglance")
        window.minSize = NSSize(width: 480, height: 360)
        window.setFrameAutosaveName("TimelineWindow")
        // The window has no popover to close and no window to open, so it
        // supplies neither verb: Esc and ⌘↩ fall through instead of pretending.
        let hosting = NSHostingController(
            rootView: TimelineWindowContent()
                .environment(store)
                .environment(banners)
                .environment(\.timelineActions, TimelineActions())
                // Shared with the popover's, so a delete in either surface offers its undo
                // in both — see `AppDelegate.startInterface()` (BACKGLANCE-242).
                .environment(\.actionDispatcher, dispatcher)
        )
        // The window's size is the window's business. Left to its default, the
        // hosting controller propagates SwiftUI's fitting size and an empty
        // timeline opens the window at its 480 × 360 minimum — measured, not
        // guessed: the autosaved frame came back at exactly the minimum.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 720, height: 640))
        window.isReleasedWhenClosed = false
        self.init(window: window)
        self.store = store
    }

    // MARK: Internal

    /// Brings the window up, creating nothing and losing nothing if it was only
    /// hidden.
    func show() {
        // Opening the window counts as looking, exactly as opening the popover
        // does — the anchor is shared, so the divider means the same thing in
        // both surfaces.
        store?.surfaceWillOpen()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Private

    private var store: TimelineStore?
}

// MARK: - TimelineWindowContent

/// The window's timeline, with the same capture banner the popover shows.
///
/// A view rather than a modifier chain at the call site because the banner has to react to
/// `TimelineStore`, and the store only becomes observable inside a `View` body — building the
/// strip where the window is constructed would freeze it at whatever the state was at launch.
private struct TimelineWindowContent: View {
    // MARK: Internal

    var body: some View {
        VStack(spacing: 0) {
            TimelineView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let banners {
                CaptureBannerStrip(state: store.captureState, model: banners)
            }
        }
    }

    // MARK: Private

    @Environment(TimelineStore.self)
    private var store

    @Environment(CaptureBannerModel.self)
    private var banners: CaptureBannerModel?
}
