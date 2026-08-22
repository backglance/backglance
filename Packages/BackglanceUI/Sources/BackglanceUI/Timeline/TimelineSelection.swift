import Foundation

// MARK: - TimelineSelection

/// The full timeline window's multi-select state: which notification ids are
/// selected, and which one is the ⇧-click anchor.
///
/// docs/features/ACTIONS.md#selection-model: "a `Set<Int64>` of selected
/// notification ids plus an 'anchor' id for ⇧-click ranges. Ranges are
/// computed over the *currently visible* ordering ... so a range never
/// silently includes hidden rows." Every range operation below is handed
/// that ordering explicitly as `[Int64]` rather than reaching for one
/// itself — the point of "currently visible" is that this type never
/// guesses what is on screen, it is told.
///
/// This is a pure value type: no store, no archive, nothing beyond what the
/// compiler asks of `Sendable`. `TimelineStore+Selection` is where it meets
/// the store and the popover/window split.
///
/// The one thing this type deliberately does **not** do: prune `ids` that
/// have left `order`. Rows leave the visible ordering for two very
/// different reasons — the user changed the filter, in which case the
/// caller clears the selection outright (see `TimelineStore.appFilter`'s
/// `didSet`), or the store dropped older rows from memory while paging
/// (`TimelineStore.maxRows`), in which case it should not — silently
/// shrinking a selection because the user scrolled would be a bug: a row
/// they selected and then scrolled past should still be there, and still
/// deletable, when they scroll back to it. Actions are safe against stale
/// ids on their own: `Archive.softDelete` returns only the ids it actually
/// flipped, and `setPinned`/`setRead` skip rows that are gone.
public struct TimelineSelection: Equatable, Sendable {
    // MARK: Lifecycle

    public init(ids: Set<Int64> = [], anchor: Int64? = nil) {
        self.ids = ids
        self.anchor = anchor
    }

    // MARK: Public

    public private(set) var ids: Set<Int64>
    public private(set) var anchor: Int64?

    public var count: Int {
        ids.count
    }

    public var isEmpty: Bool {
        ids.isEmpty
    }

    public func contains(_ id: Int64) -> Bool {
        ids.contains(id)
    }

    /// A plain click: the selection becomes exactly `[id]`, and the anchor
    /// moves to it — the next ⇧-click ranges from the row just clicked.
    public mutating func select(_ id: Int64) {
        ids = [id]
        anchor = id
    }

    /// ⌘-click: inserts or removes `id`. The anchor moves to `id` either
    /// way — added or removed — because the next ⇧-click ranges from
    /// whichever row the user last touched, which is what every list on the
    /// platform does.
    public mutating func toggle(_ id: Int64) {
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        anchor = id
    }

    /// ⇧-click: selects the closed range between the anchor and `id` in
    /// `order`, **replacing** the current selection rather than unioning
    /// with it. The anchor itself does not move, so successive ⇧-clicks
    /// re-range from the same origin instead of ratcheting one end forward
    /// on every click.
    ///
    /// Falls back to `select(id)` — never a partial or reversed range —
    /// when there is no anchor, or when the anchor or `id` is no longer in
    /// `order` (the anchor row scrolled out of memory, or was deleted).
    public mutating func extend(to id: Int64, over order: [Int64]) {
        guard let anchor,
              let anchorIndex = order.firstIndex(of: anchor),
              let targetIndex = order.firstIndex(of: id)
        else {
            select(id)
            return
        }
        let range = anchorIndex < targetIndex ? anchorIndex ... targetIndex : targetIndex ... anchorIndex
        ids = Set(order[range])
        // Anchor is untouched on purpose — see the doc comment above.
    }

    /// ⌘A: every id in `order`, anchor at the first, so a following
    /// ⇧-click ranges from the top of the visible list.
    public mutating func selectAll(_ order: [Int64]) {
        ids = Set(order)
        anchor = order.first
    }

    public mutating func clear() {
        ids = []
        anchor = nil
    }

    /// The selection in visible order — what action calls need.
    /// `ActionDispatching.copy(ids:includeAppAndTimestamp:)` documents `ids`
    /// as "the order they should appear in the copied text, which for a
    /// multi-select is the selection's order"; a `Set` has no order of its
    /// own, so this is where that order comes from. Ids no longer present in
    /// `order` are simply skipped here, not pruned from `ids` — see this
    /// type's own doc comment for why stale ids are kept rather than
    /// dropped.
    public func ordered(over order: [Int64]) -> [Int64] {
        order.filter { ids.contains($0) }
    }
}
