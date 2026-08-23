import BackglanceCore
import Foundation

// MARK: - TimelineKeyboard

/// The pure decisions behind `TimelineView`'s keyboard shortcuts — everything
/// that can be worked out from values alone, with no `SwiftUI` anywhere in
/// this file. Split out of `TimelineView+Keyboard.swift` the same way
/// `NotificationRowMenu` is split out of `NotificationRow+ContextMenu.swift`:
/// an `.onKeyPress` closure cannot be driven from XCTest, so whatever a
/// handler needs to *decide* has to live somewhere a test can call directly —
/// see `Tests/BackglanceUITests/TimelineKeyboardTests.swift`.
enum TimelineKeyboard {
    /// Esc's combined order — docs/features/TIMELINE.md#keyboard-navigation
    /// ("Clear search if active, else close popover / window") and
    /// docs/features/ACTIONS.md#keyboard-shortcuts ("Clear selection, or
    /// close popover if nothing selected"), read together innermost first:
    /// search (handled above `TimelineView`, not here), then the
    /// multi-selection, then the surface itself.
    enum EscapeOutcome: Equatable {
        /// A multi-selection exists: Esc clears it and stops there. The
        /// surface does not also close on the same keypress — a second Esc,
        /// with nothing left selected, is what reaches `.dismiss`.
        case clearSelection
        /// Nothing is selected and the surface can close.
        case dismiss
        /// Nothing is selected and there is nothing to close (a preview, or
        /// a host that never wired `timelineActions.dismiss`). The keypress
        /// falls through rather than being swallowed for no effect.
        case ignored
    }

    /// - Parameters:
    ///   - hasSelection: `!store.selection.isEmpty` — the window's
    ///     multi-selection. Always `false` in the popover, which never
    ///     accumulates one (docs/features/ACTIONS.md#selection-model), so
    ///     this function alone is what makes Esc "just dismiss" there.
    ///   - canDismiss: whether `timelineActions.dismiss` is non-`nil`.
    static func escapeOutcome(hasSelection: Bool, canDismiss: Bool) -> EscapeOutcome {
        if hasSelection {
            return .clearSelection
        }
        return canDismiss ? .dismiss : .ignored
    }

    /// ⌫ / ⌦: what `TimelineStore.selectedID` should become once `ids` are
    /// gone — docs/features/TIMELINE.md's ⌫ row, "selection moves to the
    /// next row". Must be computed from `items` — the ordering *before* the
    /// delete lands — because once the archive write is dispatched and the
    /// subscription rebuilds `sections`, the deleted rows' positions no
    /// longer exist to ask about.
    ///
    /// Generalizes past a single deleted id to a whole multi-selection: the
    /// row returned is the first surviving row *after the last deleted one*,
    /// so deleting a contiguous block moves focus to whatever follows the
    /// whole block rather than into the middle of it. Returns `nil` when
    /// nothing survives after that point — deleting the last visible row (or
    /// a multi-selection that runs to the end of the list) leaves nothing to
    /// move focus to, which is a valid outcome, not a failure to compute one.
    static func nextSelectedID(afterDeleting ids: [Int64], in items: [TimelineItem]) -> Int64? {
        let deleted = Set(ids)
        guard let lastDeletedIndex = items.lastIndex(where: { deleted.contains($0.id) }) else {
            return nil
        }
        return items[(lastDeletedIndex + 1)...].first { !deleted.contains($0.id) }?.id
    }

    /// ⇧⌘P / ⇧⌘U: the single value to apply to the whole target set.
    ///
    /// Both are toggles, and both read *one* row's current state to decide
    /// which way to flip — the row the keyboard is actually focused on, not
    /// a majority vote over the selection. That is what keeps a mixed
    /// selection (some pinned, some not) landing on one consistent state
    /// instead of every row flipping its own way independently, per this
    /// task's own instruction: "apply that one value to the whole target
    /// set".
    ///
    /// - Parameters:
    ///   - targetIDs: `store.selectedIDsInVisibleOrder` — what the toggle is
    ///     about to be applied to.
    ///   - focusedID: `store.selectedID`. Falls back to `targetIDs.first`
    ///     when `nil` — possible after `store.selectAllVisible()`, which
    ///     builds a multi-selection without moving the keyboard focus onto
    ///     any one row of it — so the derivation always has some row to
    ///     read from rather than silently doing nothing.
    ///   - items: `store.visibleItems`, to resolve the anchor id to a row.
    ///   - current: `\.isPinned` or `\.isRead` on `ArchivedNotification` —
    ///     the *manual* flag, never `TimelineItem.isPinned` (which folds in
    ///     VIP triage), matching `NotificationRowMenu`'s item 5 reasoning.
    /// - Returns: the value to pass as `setPinned`/`setRead`'s second
    ///   argument. Defaults to `true` when the anchor row cannot be resolved
    ///   at all (stale id, empty `items`) — an edge case with no row to read
    ///   a state from, where "turn it on" is the safer of two arbitrary
    ///   answers.
    static func toggledValue(
        targetIDs: [Int64],
        focusedID: Int64?,
        items: [TimelineItem],
        current: (ArchivedNotification) -> Bool
    ) -> Bool {
        let anchorID = focusedID ?? targetIDs.first
        guard let anchorNotification = items.first(where: { $0.id == anchorID })?.notification else {
            return true
        }
        return !current(anchorNotification)
    }

    /// ⇧⌘M: which app to mute or unmute, and which way — the row the keyboard
    /// is actually focused on, per item 8's own scoping in
    /// docs/features/ACTIONS.md#context-menu-specification ("act on the
    /// right-clicked row's app, never the selection"), which this shortcut
    /// mirrors with "focused" standing in for "right-clicked". `nil` when
    /// there is no focused row, or the focused row's app has no bundle id to
    /// mute — the same two conditions `NotificationRowMenu`'s item 8 hides
    /// itself for (`items(for:appName:selectionCount:host:canActivateApp:showsOpenLink:)`),
    /// so the keyboard and the menu can never disagree about which rows this
    /// shortcut reaches.
    ///
    /// - Returns: the bundle id to pass to
    ///   ``ActionDispatching/setAppMuted(bundleID:_:)`` and the value to pass
    ///   with it — the opposite of ``TimelineItem/isAppMuted``, the *raw*
    ///   `apps.is_muted` flag, never `triage.muted` (see
    ///   ``TimelineItem/isAppMuted``'s own doc comment for why those two can
    ///   disagree on a VIP-pinned row from a muted app).
    static func muteTarget(focusedID: Int64?, items: [TimelineItem]) -> (bundleID: String, muted: Bool)? {
        guard let focusedID,
              let item = items.first(where: { $0.id == focusedID }),
              let bundleID = item.bundleID
        else {
            return nil
        }
        return (bundleID, !item.isAppMuted)
    }
}
