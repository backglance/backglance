import BackglanceCore
import SwiftUI

// MARK: - TimelineKeyboardShortcuts

/// Every `.onKeyPress` `TimelineView` wires up — ↑/↓, ↩, ⌘↩, Space, Esc, and
/// the eight BACKGLANCE-203 part 2 adds (⌘C, ⌥⌘C, ⌫, ⌦, ⌘Z, ⇧⌘P, ⇧⌘U, ⌘E,
/// ⌘A) — docs/features/ACTIONS.md#keyboard-shortcuts and
/// docs/features/TIMELINE.md#keyboard-navigation.
///
/// Split out of `TimelineView.swift` for the same reason part 1 split
/// `NotificationRow+ContextMenu.swift` off `NotificationRow.swift`: this is
/// the one part of the view that *does* things rather than draws them, and
/// SwiftLint's 500-line file limit does not leave room for a dozen key
/// handlers' worth of doc comments inside `body` as well.
///
/// A `ViewModifier`, not a plain extension method on `TimelineView`, because
/// every handler below needs the same environment a view would
/// (``TimelineStore``, the dispatcher, `timelineActions`) and needs to write
/// back into two of `TimelineView`'s own `@State` properties (`exportIDs`,
/// `actionError`) — a `Binding` to each is what makes that legal from a type
/// declared in a different file, without loosening either property's access
/// level the way `NotificationRow`'s `actionDispatcher` had to be loosened
/// for `NotificationRow+ContextMenu.swift` to reach it.
///
/// ## The two conflicts this file resolves
///
/// **⌘↩.** docs/features/ACTIONS.md's keyboard table says ⌘↩ is "Open Link
/// only"; docs/features/TIMELINE.md's says ⌘↩ is "Open the full window
/// (popover only)". Both are honoured by scoping on `store.host`: in the
/// popover ⌘↩ opens the full window (the pre-existing behaviour, unchanged),
/// in the window ⌘↩ is "Open Link only". See ``handleCommandReturn(_:)``.
///
/// **Esc.** docs/features/TIMELINE.md: "Clear search if active, else close
/// popover / window". docs/features/ACTIONS.md: "Clear selection, or close
/// popover if nothing selected". Combined, innermost first: clear search —
/// already handled by `SearchBar`'s own `.onKeyPress(.escape)` on the search
/// field itself, which `TimelineView` neither renders nor needs to touch —
/// then clear the multi-selection if there is one, then dismiss the surface.
/// See ``TimelineKeyboard/escapeOutcome(hasSelection:canDismiss:)``.
struct TimelineKeyboardShortcuts: ViewModifier {
    // MARK: Internal

    /// The ids to hand `ExportSheet` — set by ⌘E here, and by the row
    /// context menu's "Export Selection…" (`TimelineSectionSlots`'
    /// `onRequestExport`, which `TimelineView` also writes into this same
    /// property). `nil` means no sheet is presented.
    @Binding var exportIDs: [Int64]?

    /// The most recent dispatch failure worth showing inline — see
    /// `TimelineView`'s own doc comment on the property this binds.
    @Binding var actionError: ActionError?

    func body(content: Content) -> some View {
        content
            .onKeyPress(.upArrow) {
                store.moveSelection(-1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                store.moveSelection(1)
                return .handled
            }
            .onKeyPress(.return) {
                guard let id = store.selectedID else {
                    return .ignored
                }
                store.open(id)
                return .handled
            }
            // Space peeks: the selected row expands to detailed and back,
            // without changing what the surface remembers for next time.
            .onKeyPress(.space) {
                store.viewMode = store.viewMode == .compact ? .detailed : .compact
                return .handled
            }
            .onKeyPress(.escape, phases: .down, action: handleEscape)
            // Attached *after* the plain Return handler above so it is the
            // one SwiftUI checks first for a Return keydown: two
            // `.onKeyPress` registrations for the same `KeyEquivalent` are
            // tried in reverse of their attachment order, and only a
            // `.ignored` result here (no ⌘ held) falls through to the plain
            // handler above. Kept at `phases: .down` rather than as a
            // `keyboardShortcut`, the same choice the pre-existing code
            // already made, for the same reason: a hidden `Button` would
            // have no way to also let the plain Return above keep working.
            .onKeyPress(.return, phases: .down, action: handleCommandReturn)
            .onKeyPress(KeyEquivalent("c"), phases: .down) { press in
                handleCopy(press, includeAppAndTimestamp: false)
            }
            .onKeyPress(KeyEquivalent("c"), phases: .down) { press in
                handleCopy(press, includeAppAndTimestamp: true)
            }
            .onKeyPress(.delete, phases: .down, action: handleDelete)
            .onKeyPress(.deleteForward, phases: .down, action: handleDelete)
            .onKeyPress(KeyEquivalent("z"), phases: .down, action: handleUndo)
            // Registered twice each, lowercase and uppercase. Both shortcuts
            // hold Shift, and SwiftUI is not documented to promise which case
            // `KeyPress.key` carries for a shifted letter — an implementation
            // that normalizes to "p" and one that reports "P" are both
            // plausible readings of the same API. Registering the pair costs
            // two lines and cannot double-fire (the first to match returns
            // `.handled`, and a keypress is only ever one of the two), where
            // guessing wrong costs a shortcut that is silently dead on a
            // machine nobody can key-test here — the XCUITest bundle that
            // would catch it cannot run on this host (BACKGLANCE-195).
            .onKeyPress(KeyEquivalent("p"), phases: .down, action: handlePinToggle)
            .onKeyPress(KeyEquivalent("P"), phases: .down, action: handlePinToggle)
            .onKeyPress(KeyEquivalent("u"), phases: .down, action: handleReadToggle)
            .onKeyPress(KeyEquivalent("U"), phases: .down, action: handleReadToggle)
            .onKeyPress(KeyEquivalent("e"), phases: .down, action: handleExportRequest)
            .onKeyPress(KeyEquivalent("a"), phases: .down, action: handleSelectAll)
    }

    // MARK: Private

    @Environment(TimelineStore.self)
    private var store

    @Environment(\.actionDispatcher)
    private var actionDispatcher

    @Environment(\.timelineActions)
    private var actions

    private func handleEscape(_ press: KeyPress) -> KeyPress.Result {
        let outcome = TimelineKeyboard.escapeOutcome(
            hasSelection: !store.selection.isEmpty,
            canDismiss: actions.dismiss != nil
        )
        switch outcome {
        case .clearSelection:
            store.clearSelection()
            return .handled

        case .dismiss:
            actions.dismiss?()
            return .handled

        case .ignored:
            return .ignored
        }
    }

    /// ⌘↩ — see this file's own doc comment for the conflict this resolves.
    private func handleCommandReturn(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command) else {
            return .ignored
        }
        guard store.host == .window else {
            guard let openWindow = actions.openWindow else {
                return .ignored
            }
            openWindow()
            return .handled
        }
        // The window: "Open Link only", no app fallback
        // (docs/features/ACTIONS.md#keyboard-shortcuts). Beeps on
        // `.deepLinkUnresolvable` — via `ActionDispatchRouting` — the same
        // way `NotificationRow+ContextMenu`'s `.openLink` branch does; this
        // is the one shortcut in this file that is never silently ignored
        // just because the focused row has nothing to open
        // (docs/features/ACTIONS.md's edge-case table: "except ⌘↩ which
        // beeps by design").
        guard let id = store.selectedID, let dispatcher = actionDispatcher else {
            return .ignored
        }
        ActionDispatchRouting.run {
            try dispatcher.openLink(id: id)
        } onError: {
            actionError = $0
        }
        return .handled
    }

    /// ⌘C (`includeAppAndTimestamp == false`) and ⌥⌘C (`true`). Two
    /// `.onKeyPress` registrations for the same `"c"` key share this one
    /// function — see `body`'s two calls above — each checking for
    /// (or explicitly against) Option so the pair stays mutually exclusive
    /// regardless of which one SwiftUI happens to try first.
    private func handleCopy(_ press: KeyPress, includeAppAndTimestamp: Bool) -> KeyPress.Result {
        guard press.modifiers.contains(.command),
              press.modifiers.contains(.option) == includeAppAndTimestamp
        else {
            return .ignored
        }
        let ids = store.selectedIDsInVisibleOrder
        guard !ids.isEmpty, let dispatcher = actionDispatcher else {
            return .ignored
        }
        ActionDispatchRouting.run {
            try dispatcher.copy(ids: ids, includeAppAndTimestamp: includeAppAndTimestamp)
        }
        onError: {
            actionError = $0
        }
        return .handled
    }

    /// ⌫ and ⌦ share this one handler — docs/features/TIMELINE.md's ⌫ row
    /// documents "selection moves to the next row", and nothing distinguishes
    /// the two keys beyond which physical key was pressed.
    private func handleDelete(_ press: KeyPress) -> KeyPress.Result {
        let ids = store.selectedIDsInVisibleOrder
        guard !ids.isEmpty, let dispatcher = actionDispatcher else {
            return .ignored
        }
        // Computed *before* dispatching: once the delete lands and the
        // subscription rebuilds `sections`, these ids are gone from
        // `store.visibleItems`, and their position in *this* ordering is the
        // only way left to know what "the next row" meant.
        let nextID = TimelineKeyboard.nextSelectedID(afterDeleting: ids, in: store.visibleItems)
        let succeeded = ActionDispatchRouting.run {
            try dispatcher.delete(ids: ids)
        } onError: {
            actionError = $0
        }
        if succeeded {
            store.selectedID = nextID
        }
        return .handled
    }

    /// ⌘Z, while the undo toast is visible.
    private func handleUndo(_ press: KeyPress) -> KeyPress.Result {
        // ⇧⌘Z is Redo everywhere on this platform, and there is nothing to
        // redo here — undoing a delete that was itself an undo is not a state
        // this handler can reach. Excluding Shift means ⇧⌘Z falls through
        // rather than quietly performing an Undo the user asked to reverse.
        guard press.modifiers.contains(.command), !press.modifiers.contains(.shift) else {
            return .ignored
        }
        // Downcast to the concrete handler to read `pendingUndo`, the same
        // way `NotificationRow+ContextMenu`'s `canActivateApp` reaches
        // `NotificationActionHandler` past the `ActionDispatching` protocol —
        // see that property's own doc comment for why `pendingUndo` is not
        // on the protocol either. `undoDelete()` is already a silent no-op
        // with nothing pending, but checking here first means a ⌘Z with no
        // toast on screen falls through (`.ignored`) instead of being
        // swallowed for a keypress that changed nothing.
        guard let handler = actionDispatcher as? NotificationActionHandler, !handler.pendingUndo.isEmpty else {
            return .ignored
        }
        ActionDispatchRouting.run {
            try handler.undoDelete()
        } onError: {
            actionError = $0
        }
        return .handled
    }

    /// ⇧⌘P.
    private func handlePinToggle(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command), press.modifiers.contains(.shift) else {
            return .ignored
        }
        return toggle(current: \.isPinned) { dispatcher, ids, value in try dispatcher.setPinned(ids: ids, value) }
    }

    /// ⇧⌘U.
    private func handleReadToggle(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command), press.modifiers.contains(.shift) else {
            return .ignored
        }
        return toggle(current: \.isRead) { dispatcher, ids, value in try dispatcher.setRead(ids: ids, value) }
    }

    /// Shared by ``handlePinToggle(_:)`` and ``handleReadToggle(_:)``: both
    /// derive one value from the focused row (``TimelineKeyboard/toggledValue(targetIDs:focusedID:items:current:)``)
    /// and apply it to the whole target set, differing only in which manual
    /// flag they read and which `ActionDispatching` method they call.
    private func toggle(
        current: (ArchivedNotification) -> Bool,
        apply: (any ActionDispatching, [Int64], Bool) throws -> Void
    ) -> KeyPress.Result {
        let ids = store.selectedIDsInVisibleOrder
        guard !ids.isEmpty, let dispatcher = actionDispatcher else {
            return .ignored
        }
        let newValue = TimelineKeyboard.toggledValue(
            targetIDs: ids,
            focusedID: store.selectedID,
            items: store.visibleItems,
            current: current
        )
        ActionDispatchRouting.run {
            try apply(dispatcher, ids, newValue)
        } onError: {
            actionError = $0
        }
        return .handled
    }

    /// ⌘E — window only, matching item 10's own condition in
    /// docs/features/ACTIONS.md#context-menu-specification. Only presents
    /// `ExportSheet` when there is something to export; `selectedIDsInVisibleOrder`
    /// already folds the single focused row in when nothing is multi-selected.
    private func handleExportRequest(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command), store.host == .window else {
            return .ignored
        }
        let ids = store.selectedIDsInVisibleOrder
        guard !ids.isEmpty else {
            return .ignored
        }
        exportIDs = ids
        return .handled
    }

    /// ⌘A — window only; `TimelineStore.selectAllVisible()` is itself
    /// host-gated (docs/features/ACTIONS.md#selection-model), but this
    /// checks `store.host` too so a ⌘A in the popover falls through
    /// (`.ignored`) instead of being silently swallowed for nothing.
    private func handleSelectAll(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command), store.host == .window else {
            return .ignored
        }
        store.selectAllVisible()
        return .handled
    }
}
