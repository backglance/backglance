import SwiftUI

// MARK: - ActionDispatching

/// The seam row views dispatch notification actions through.
///
/// `NotificationRow`, `TimelineView` and the hover buttons all need one thing in
/// common: a place to send "open this", "copy that", "delete these" that does not
/// require knowing whether they are drawn inside the popover, the full window, or an
/// Xcode preview with no host at all. Routing through a protocol rather than a
/// concrete `NotificationActionHandler` reference is what makes the third case
/// possible — a preview can hand the environment `nil` and every row still renders,
/// same as ``TimelineActionsKey``'s `nil` actions do for a host that cannot open a
/// window.
///
/// This protocol has no requirements yet. `NotificationActionHandler` (this task,
/// BACKGLANCE-196) is the coordinator skeleton — its `Archive`, its shared `fetch`
/// helper, and this seam — and the action methods land on top of it one at a time in
/// their own follow-up tasks: Open, Copy, Delete/Undo, Pin/Read, System Settings,
/// Export. Each of those tasks adds its method to this protocol as it ships, rather
/// than this task guessing signatures for work that has not been designed yet.
///
/// See docs/features/ACTIONS.md#notificationactionhandler.
@MainActor
public protocol ActionDispatching: AnyObject {}

// MARK: - ActionDispatcherKey

public struct ActionDispatcherKey: EnvironmentKey {
    /// `nil`, not a no-op implementation: a protocol with no requirements has nothing
    /// for a stub conformance to implement anyway, and `nil` is also what lets a row
    /// preview detect "no host" and skip wiring up menu items that would do nothing.
    public static let defaultValue: (any ActionDispatching)? = nil
}

public extension EnvironmentValues {
    /// The live coordinator for row actions, or `nil` in a preview that has not wired
    /// one up.
    var actionDispatcher: (any ActionDispatching)? {
        get { self[ActionDispatcherKey.self] }
        set { self[ActionDispatcherKey.self] = newValue }
    }
}
