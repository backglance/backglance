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
/// `NotificationActionHandler` (BACKGLANCE-196) was the coordinator skeleton — its
/// `Archive`, its shared `fetch` helper, and this seam, with no requirements yet.
/// Open (BACKGLANCE-197) is the first action to land on top of it; Copy, Delete/Undo,
/// Pin/Read, System Settings and Export are still separate follow-up tasks, each
/// adding its own method here as it ships, rather than this task guessing signatures
/// for work that has not been designed yet.
///
/// See docs/features/ACTIONS.md#notificationactionhandler.
@MainActor
public protocol ActionDispatching: AnyObject {
    /// The ↩ / "Open in ‹App›" path — see
    /// docs/features/ACTIONS.md#open-openaction-and-deeplinkresolver. `async`
    /// because it may activate an app through `NSWorkspace`, which is
    /// itself async; `throws` for the `ActionError` cases the ordering can
    /// end in.
    func openNotification(id: Int64) async throws

    /// The ⌘↩ "Open Link only" path — opens `deep_link` alone, with no app
    /// fallback. Synchronous: unlike ``openNotification(id:)`` it never
    /// reaches `openApplication`, only the synchronous `NSWorkspace.open(_:)`.
    func openLink(id: Int64) throws
}

// MARK: - ActionDispatcherKey

public struct ActionDispatcherKey: EnvironmentKey {
    /// `nil`, not a stub conformance: a stub would have to fabricate an outcome for
    /// every method (does `openNotification` "succeed" with no archive behind it?),
    /// and `nil` is also what lets a row preview detect "no host" and skip wiring up
    /// menu items that would do nothing.
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
