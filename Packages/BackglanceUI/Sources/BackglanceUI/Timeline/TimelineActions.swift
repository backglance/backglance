import SwiftUI

// MARK: - TimelineActions

/// The two things the timeline can ask its *host* to do.
///
/// Opening a window and closing a popover are AppKit's business, and this
/// package has no idea which surface it is being drawn in — the same
/// `TimelineView` renders inside an `NSPopover` and inside an `NSWindow`. So
/// the host supplies the verbs and the view calls them, which is also what lets
/// a preview render the timeline with no host at all.
///
/// Both are optional. A `nil` action means the surface cannot do that thing,
/// and the key stroke falls through rather than pretending to work — the window
/// has no "open the window" and no popover to close.
public struct TimelineActions: Sendable {
    // MARK: Lifecycle

    public init(
        openWindow: (@MainActor @Sendable () -> Void)? = nil,
        dismiss: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.openWindow = openWindow
        self.dismiss = dismiss
    }

    // MARK: Public

    /// ⌘↩ from the popover: open the full window, closing the popover behind it.
    public let openWindow: (@MainActor @Sendable () -> Void)?

    /// Esc with no search text: close this surface.
    public let dismiss: (@MainActor @Sendable () -> Void)?
}

// MARK: - TimelineActionsKey

public struct TimelineActionsKey: EnvironmentKey {
    public static let defaultValue = TimelineActions()
}

public extension EnvironmentValues {
    /// What the surface hosting the timeline can do on its behalf.
    var timelineActions: TimelineActions {
        get { self[TimelineActionsKey.self] }
        set { self[TimelineActionsKey.self] = newValue }
    }
}
