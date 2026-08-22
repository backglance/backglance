import BackglanceCore
import Foundation

// MARK: - Selection

/// Multi-select operations for the full timeline window, wrapping
/// ``TimelineSelection`` with the store's notion of "currently visible" and
/// keeping the keyboard focus (``TimelineStore/selectedID``) in step.
///
/// Every method here returns without effect unless `host == .window` — the
/// popover has a single focused row and no multi-select
/// (docs/features/ACTIONS.md#selection-model) — so that check is documented
/// once, here, rather than repeated on every method below.
///
/// Each range operation resolves the visible ordering as
/// `visibleItems.map(\.id)`, which is already "after filters, with muted
/// groups collapsed" — exactly the ordering the doc names. A plain click, a
/// ⌘-click and a ⇧-click all also move ``TimelineStore/selectedID`` to the
/// row that was clicked, so the keyboard focus and the multi-selection can
/// never drift apart on screen.
public extension TimelineStore {
    /// A plain click on a row: the selection becomes exactly that row.
    func selectOnly(_ id: Int64) {
        guard host == .window else {
            return
        }
        selection.select(id)
        selectedID = id
    }

    /// ⌘-click: toggles the row's membership in the selection.
    func toggleSelection(_ id: Int64) {
        guard host == .window else {
            return
        }
        selection.toggle(id)
        selectedID = id
    }

    /// ⇧-click: extends the selection from the anchor to `id` over the
    /// currently visible ordering.
    func extendSelection(to id: Int64) {
        guard host == .window else {
            return
        }
        selection.extend(to: id, over: visibleItems.map(\.id))
        selectedID = id
    }

    /// ⌘A: selects every row currently visible.
    func selectAllVisible() {
        guard host == .window else {
            return
        }
        selection.selectAll(visibleItems.map(\.id))
    }

    /// Esc, or any other place the multi-selection needs to empty out
    /// without touching ``TimelineStore/selectedID``.
    func clearSelection() {
        guard host == .window else {
            return
        }
        selection.clear()
    }

    /// The ids an action should act on, in the order they should appear —
    /// what `copy`/`delete`/`setPinned`/`setRead` are called with.
    ///
    /// Falls back to ``TimelineStore/selectedID``'s single row when the
    /// multi-selection is empty: in the popover (and in the window before
    /// any multi-select has been made), the focused row *is* the target of
    /// ⌘C or ⌫. This fallback is what lets one action call serve both
    /// hosts, rather than every call site branching on `host` itself.
    var selectedIDsInVisibleOrder: [Int64] {
        guard !selection.isEmpty else {
            return selectedID.map { [$0] } ?? []
        }
        return selection.ordered(over: visibleItems.map(\.id))
    }
}
