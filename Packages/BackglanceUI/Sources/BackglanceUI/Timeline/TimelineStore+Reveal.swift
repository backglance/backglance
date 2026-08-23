import BackglanceCore
import Foundation

// MARK: - Reveal

/// Bringing one already-known row on screen — what `backglance://open?id=` needs once
/// the uuid has been resolved to an ``BackglanceCore/ArchivedNotification`` by
/// ``BackglanceCore/Archive/notification(uuid:)``.
/// See docs/api/API_DOCUMENTATION.md#url-scheme-backglance.
public extension TimelineStore {
    /// What ``reveal(_:)`` managed to do.
    enum RevealOutcome: Equatable, Sendable {
        /// On screen, selected, and a scroll requested.
        case revealed

        /// In the archive, but not reachable from this store: hidden behind
        /// ``appFilter``, or sitting in a day's collapsed "Muted" group. The URL
        /// scheme's contract does not distinguish this from "not in the archive at
        /// all" (docs/api/API_DOCUMENTATION.md#error-behavior) — either way there is
        /// nothing on screen to point at, so the caller's fallback is the same toast.
        case unreachable
    }

    /// Loads older pages, if needed, until `notification` is among ``rows``, then
    /// selects it and publishes a ``ScrollRequest`` for `TimelineView` to act on.
    ///
    /// Safe to call for a row this store can never show — a filtered-out app, or a
    /// row collapsed into a "Muted" group nobody has expanded. Neither hangs: both
    /// terminate in ``RevealOutcome/unreachable`` once paging runs out of pages
    /// (``hasMorePages``), which is the same bound ``loadNextPage()`` already has.
    @discardableResult
    func reveal(_ notification: ArchivedNotification) async -> RevealOutcome {
        guard let id = notification.id else {
            return .unreachable
        }

        while !rows.contains(where: { $0.id == id }), hasMorePages {
            await loadNextPage()
        }
        guard rows.contains(where: { $0.id == id }) else {
            return .unreachable
        }

        // `loadNextPage()` already calls `regroup()` on every page it appends, but the
        // row can also have been sitting in `rows` from the start — the loop above
        // never ran, so `sections` needs its own refresh before the reachability check
        // below can trust it.
        regroup()
        guard visibleItems.contains(where: { $0.id == id }) else {
            return .unreachable
        }

        selectedID = id
        scrollRequest = ScrollRequest(rowID: id)
        return .revealed
    }

    /// Puts `text` up as a toast and starts its own dismiss clock — see
    /// ``TimelineMessage``.
    func showMessage(_ text: String) {
        message = TimelineMessage(text: text)
    }

    /// Clears whatever ``message`` is currently showing. Called by `TimelineView`'s
    /// auto-dismiss timer; safe to call with nothing showing.
    func clearMessage() {
        message = nil
    }
}
