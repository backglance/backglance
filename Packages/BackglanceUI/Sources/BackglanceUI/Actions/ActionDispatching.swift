import BackglanceCore
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
/// Open (BACKGLANCE-197) was the first action to land on top of it; Copy
/// (BACKGLANCE-198) was the second; Delete/Undo (BACKGLANCE-199) was the third;
/// Pin/Read (BACKGLANCE-200) was the fourth; System Settings (BACKGLANCE-201) was
/// the fifth; Export (BACKGLANCE-204) was the sixth; Mute (BACKGLANCE-239) is the
/// seventh and last, added below now that the `RulesEngine` Phase 4.2 introduced
/// has landed. Every action in docs/features/ACTIONS.md's context menu has now
/// shipped.
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

    /// The ⌘C / ⌥⌘C path — see docs/features/ACTIONS.md#copy. `ids` in the
    /// order they should appear in the copied text, which for a multi-select
    /// is the selection's order, not necessarily delivery order. Synchronous:
    /// the write goes straight to `NSPasteboard`, with no async AppKit call
    /// on the way, unlike ``openNotification(id:)``.
    func copy(ids: [Int64], includeAppAndTimestamp: Bool) throws

    /// The ⌫ / ⌦ path — see docs/features/ACTIONS.md#delete-and-undo. Soft-deletes
    /// `ids` and starts (or, if one was already running, replaces and restarts) the
    /// 5-second undo window. Synchronous, like ``copy(ids:includeAppAndTimestamp:)``:
    /// `Archive.softDelete` is an ordinary `pool.write` call with no `await` on it, and
    /// the 5-second wait itself happens on a detached ``NotificationActionHandler``
    /// timer, not on the caller's stack.
    func delete(ids: [Int64]) throws

    /// The ⌘Z path, valid only while the undo toast this handler renders through
    /// ``NotificationActionHandler/pendingUndo`` is showing. Restores exactly the ids
    /// the most recent ``delete(ids:)`` call flipped and clears the toast. A silent
    /// no-op with nothing pending — ⌘Z with no toast on screen is a keyboard miss, not
    /// a mistake worth a beep.
    func undoDelete() throws

    /// The pin / unpin toggle — see
    /// docs/features/ACTIONS.md#pin-unpin-read-unread. Pinning is what moves a row to
    /// the top of its day in ``TimelineStore/buildSections(items:groupByApp:anchor:calendar:now:)``,
    /// manual pin before a VIP-triage pin. Synchronous, like
    /// ``delete(ids:)``: `Archive.setPinned` is an ordinary `pool.write` call with no
    /// `await` on it.
    func setPinned(ids: [Int64], _ pinned: Bool) throws

    /// The read / unread toggle — see
    /// docs/features/ACTIONS.md#pin-unpin-read-unread. Marking read affects only the
    /// unread badge; opening a notification marks it read implicitly through
    /// ``openNotification(id:)``, so this method is for the explicit toggle only.
    /// Marking unread is not a lesser path than marking read — a row unread again
    /// re-enters the badge count if it was delivered since the last popover open, per
    /// the doc above. Synchronous, like ``delete(ids:)``: `Archive.setRead` is an
    /// ordinary `pool.write` call with no `await` on it.
    func setRead(ids: [Int64], _ read: Bool) throws

    /// Item 9 of the context menu ("Notification Settings for ‹App›…") — see
    /// docs/features/ACTIONS.md#open-in-system-settings--notifications. Takes a
    /// bundle id, not a notification id: per the Context Menu Specification table,
    /// items 1, 2, 8 and 9 act on the row that was right-clicked — its app — not on
    /// the whole selection, unlike ``copy(ids:includeAppAndTimestamp:)``,
    /// ``delete(ids:)``, ``setPinned(ids:_:)`` and ``setRead(ids:_:)``, which act on
    /// every id passed in. Synchronous: the underlying `NSWorkspace.open(_:)` call is
    /// itself synchronous, unlike ``openNotification(id:)``'s app-activation
    /// fallback.
    func openNotificationSettings(bundleID: String) throws

    /// Item 8 of the context menu ("Mute ‹App› in Timeline" / "Unmute ‹App›") and
    /// its ⇧⌘M shortcut — see docs/features/ACTIONS.md#mute-this-app-in-timeline.
    /// Acts on the right-clicked (or keyboard-focused) row's app, like
    /// ``openNotificationSettings(bundleID:)``, never the whole selection —
    /// "mute 3 different apps at once" has no single meaning the way "delete 3
    /// rows" does. Routes through ``AppMuting/setAppMuted(bundleID:muted:)``
    /// rather than a direct `Archive` write to `apps.is_muted`, so the same
    /// write that flips the column also invalidates the timeline's triage
    /// cache — see ``AppMuting``'s own doc comment for why that is a seam of
    /// its own rather than one more requirement on ``BackglanceCore/TriageEvaluating``.
    /// Synchronous, like ``setPinned(ids:_:)`` and ``setRead(ids:_:)``:
    /// `RulesEngine.setAppMuted(bundleID:muted:)` is an ordinary lock-guarded
    /// write with no `await` on it.
    func setAppMuted(bundleID: String, _ muted: Bool) throws

    /// Item 10 of the context menu ("Export Selection…") — see
    /// docs/features/ACTIONS.md#select-and-export. `ids` acts on the whole selection, like
    /// ``copy(ids:includeAppAndTimestamp:)``, ``delete(ids:)``, ``setPinned(ids:_:)`` and
    /// ``setRead(ids:_:)`` — never on just the right-clicked row. `async` because it runs the
    /// save panel and then `ExportService.export`, itself `async`; `throws` only for a failure
    /// after the user confirmed a destination — cancelling the panel returns silently, per
    /// docs/features/ACTIONS.md's edge-case table, never an ``ActionError``.
    func exportSelection(_ ids: [Int64], format: ExportFormat) async throws
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
