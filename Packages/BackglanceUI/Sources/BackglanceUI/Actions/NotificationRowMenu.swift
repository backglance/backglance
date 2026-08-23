import Foundation

// MARK: - NotificationRowMenu

/// A pure, testable model of the row context menu's contents —
/// docs/features/ACTIONS.md#context-menu-specification.
///
/// Which items appear, what each is labelled, and which are disabled are all
/// decidable from values alone, with no SwiftUI anywhere in this file. That is
/// the whole point of splitting it out: a menu whose regressions can only be
/// caught by driving a real `.contextMenu` (which XCTest cannot inspect) is a
/// menu a human has to click through by hand after every change.
/// `NotificationRow` is the only caller — it turns each ``Item`` into a
/// `Button` or `Divider` and wires up the actual dispatch, which is
/// deliberately the one thing this type does not know how to do.
enum NotificationRowMenu {
    // MARK: Internal

    /// One entry's identity. `.separator` is a layout slot, not an action —
    /// the caller draws a `Divider()` for it and never reads its `title` or
    /// `isEnabled`.
    enum Kind: Equatable {
        case open
        case openLink
        case copy
        case copyWithAppAndTime
        case pin
        case unpin
        case markRead
        case markUnread
        case mute
        case unmute
        case notificationSettings
        case exportSelection
        case delete
        case separator
    }

    /// One row of the menu: what it says, and whether it can be tapped.
    ///
    /// `isEnabled` is a separate question from *presence*. Item 1 ("Open in
    /// ‹App›") is the table's one explicit "disabled, not hidden" case, kept
    /// on screen so a right-click on a row whose app was uninstalled still
    /// shows why nothing happens. Every other item that would otherwise
    /// render inert is simply absent from the array instead — item 2 when
    /// there is no more specific link than plain app activation, item 10
    /// outside the window or with nothing selected.
    struct Item: Equatable {
        /// A `Divider()` placeholder. `title`/`isEnabled` are never read for
        /// a separator; they exist only so `Item` can stay one concrete type
        /// instead of an enum-of-two-shapes the caller would have to unwrap.
        static let separator = Item(kind: .separator, title: "", isEnabled: true)

        let kind: Kind
        let title: String
        let isEnabled: Bool
    }

    /// Builds the menu for one right-click, in the exact order and with the
    /// exact separator placement of docs/features/ACTIONS.md's table.
    ///
    /// - Parameters:
    ///   - item: the row that was right-clicked. Items 5 and 6's labels read
    ///     its *manual* state — see the note on
    /// ``items(for:appName:selectionCount:host:canActivateApp:showsOpenLink:)``'s
    ///     item-5 branch below for why that is not the same as
    ///     `item.isPinned`.
    ///   - appName: `apps.display_name` (or its bundle-id/placeholder
    ///     fallback), for items 1, 8 and 9's titles. Taken as its own parameter
    ///     rather than read off `item` so a caller with a fetched app record
    ///     but no `TimelineItem` (there is none today, but nothing here
    ///     should assume one) is never forced to build one just to get a
    ///     name.
    ///   - selectionCount: how many rows are currently multi-selected in the
    ///     window (``TimelineStore/selection``'s count) — 0 in the popover,
    ///     which has no multi-select, or in the window before one has been
    ///     made. Drives item 11's "Delete" vs "Delete N Notifications" and
    ///     item 10's visibility.
    ///   - host: popover or window. Item 10 ("Export Selection…") only ever
    ///     appears in the window — the popover has no selection to export.
    ///   - canActivateApp: whether `NSWorkspace` can resolve `item`'s app —
    ///     see ``NotificationActionHandler/canActivateApp(bundleID:)``. Item
    ///     1 is disabled, not hidden, when this is `false`.
    ///   - showsOpenLink: whether `item`'s `deep_link` is more specific than
    ///     plain app activation — see
    ///     ``NotificationActionHandler/showsOpenLink(deepLink:)``. Item 2 is
    ///     hidden entirely, not disabled, when this is `false`.
    ///
    /// Multi-select semantics, from the paragraph under
    /// docs/features/ACTIONS.md's table: items 3–6, 10 and 11 are dispatched
    /// with the *whole selection*'s ids; items 1, 2, 8 and 9 always act on the
    /// right-clicked row's own app, never the selection — "open the app for
    /// 3 selected rows" has no single meaning, but "copy 3 rows" or "delete
    /// 3 rows" does. This function only decides what the items say; which ids
    /// each one is dispatched with is `NotificationRow`'s job at the call
    /// site, following exactly that split.
    static func items(
        for item: TimelineItem,
        appName: String,
        selectionCount: Int,
        host: TimelineStore.Host,
        canActivateApp: Bool,
        showsOpenLink: Bool
    ) -> [Item] {
        var result: [Item] = []

        // 1. Open in ‹App› — acts on the right-clicked row's app. Always
        // present; disabled with "App not found" (the view layer's tooltip,
        // not this type's concern) when the bundle id does not resolve.
        result.append(Item(
            kind: .open,
            title: String(localized: "Open in \(appName)"),
            isEnabled: canActivateApp
        ))

        // 2. Open Link — acts on the right-clicked row's app. Hidden, not
        // disabled, when there is nothing more specific to offer than what
        // item 1 already does.
        if showsOpenLink {
            result.append(Item(kind: .openLink, title: String(localized: "Open Link"), isEnabled: true))
        }

        result.append(.separator)

        // 3–4. Copy / Copy with App and Time — act on the whole selection.
        // Always available: text stays copyable even when nothing else about
        // the row works (an uninstalled app, a dead link).
        result.append(Item(kind: .copy, title: String(localized: "Copy"), isEnabled: true))
        result.append(Item(
            kind: .copyWithAppAndTime,
            title: String(localized: "Copy with App and Time"),
            isEnabled: true
        ))

        result.append(.separator)

        // 5. Pin / Unpin — acts on the whole selection. The label follows
        // `item.notification.isPinned`, the *manual* flag this item actually
        // flips, never `item.isPinned` (which also folds in a VIP-triage
        // pin — see `TimelineItem.isPinned`). A row that is pinned only
        // because a VIP rule matched it must still offer "Pin": clicking it
        // is exactly what would set the manual flag, and offering "Unpin"
        // instead would flip a flag that was never true, doing nothing to
        // the row's actual pinned appearance.
        result.append(item.notification.isPinned
            ? Item(kind: .unpin, title: String(localized: "Unpin"), isEnabled: true)
            : Item(kind: .pin, title: String(localized: "Pin"), isEnabled: true))

        // 6. Mark as Read / Mark as Unread — acts on the whole selection.
        // Same toggle-label reasoning as item 5, over `isRead` instead.
        result.append(item.notification.isRead
            ? Item(kind: .markUnread, title: String(localized: "Mark as Unread"), isEnabled: true)
            : Item(kind: .markRead, title: String(localized: "Mark as Read"), isEnabled: true))

        // 7. Snooze… is v1.x (docs/features/SNOOZE_RESURFACE.md) — omitted entirely, not disabled.

        result.append(.separator)

        // 8. Mute ‹App› in Timeline / Unmute ‹App› (BACKGLANCE-239) — see
        // ``muteItem(appName:isAppMuted:)``'s own doc comment for the full
        // reasoning behind its label and its hidden-when-no-bundle-id
        // condition.
        if item.bundleID != nil {
            result.append(muteItem(appName: appName, isAppMuted: item.isAppMuted))
        }

        // 9. Notification Settings for ‹App›… — acts on the right-clicked
        // row's app, like items 1 and 2, never the selection.
        result.append(Item(
            kind: .notificationSettings,
            title: String(localized: "Notification Settings for \(appName)…"),
            isEnabled: true
        ))

        result.append(.separator)

        // 10. Export Selection… — acts on the whole selection. Window only,
        // and only once at least one row is selected — the popover has no
        // multi-select to export (docs/features/ACTIONS.md#selection-model).
        if host == .window, selectionCount >= 1 {
            result.append(Item(
                kind: .exportSelection,
                title: String(localized: "Export Selection…"),
                isEnabled: true
            ))
        }

        // 11. Delete — acts on the whole selection. The only item whose
        // title itself carries the count, per the table ("Delete 3
        // Notifications" for multi-select). A lone right-clicked row with
        // nothing else selected reads as plain "Delete", not "Delete 1
        // Notification" — `selectionCount` is 0 or 1 in that case, never a
        // count worth saying out loud.
        result.append(selectionCount > 1
            ? Item(
                kind: .delete,
                title: String(localized: "Delete \(selectionCount) Notifications"),
                isEnabled: true
            )
            : Item(kind: .delete, title: String(localized: "Delete"), isEnabled: true))

        return result
    }

    // MARK: Private

    /// Item 8's `.mute`/`.unmute` entry, split out of
    /// ``items(for:appName:selectionCount:host:canActivateApp:showsOpenLink:)``
    /// only to keep that function under SwiftLint's body-length limit — the
    /// reasoning below is exactly as load-bearing as it would be inline.
    ///
    /// Acts on the right-clicked row's app, like items 1, 2 and 9, never the
    /// selection. The caller only calls this when `item.bundleID != nil`:
    /// item 8 is hidden entirely, the same treatment item 2 gets, when there
    /// is no bundle id for `RulesEngine.setAppMuted` to act on.
    ///
    /// The label reads `isAppMuted` — the raw `apps.is_muted` flag carried
    /// onto `TimelineItem` at build time — and deliberately not
    /// `item.triage.muted`, which is `false` on a VIP-pinned row from a muted
    /// app even though the app itself is still muted underneath (VIP beats
    /// mute; see `TimelineItem.isAppMuted`'s own doc comment). Reading triage
    /// here would flip this one row's label to "Mute" while every unmatched
    /// sibling from the same app still correctly says "Unmute".
    private static func muteItem(appName: String, isAppMuted: Bool) -> Item {
        isAppMuted
            ? Item(kind: .unmute, title: String(localized: "Unmute \(appName)"), isEnabled: true)
            : Item(kind: .mute, title: String(localized: "Mute \(appName) in Timeline"), isEnabled: true)
    }
}
