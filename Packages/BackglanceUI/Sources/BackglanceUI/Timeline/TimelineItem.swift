import BackglanceCore
import Foundation

// MARK: - TimelineViewMode

/// How much of a notification a row shows.
///
/// The two hosts remember this separately (docs/features/TIMELINE.md#view-mode-persistence):
/// glancing at the popover and reading in the window are different jobs.
public enum TimelineViewMode: String, CaseIterable, Sendable {
    /// Icon, app, title, time — one line, and the body is never even passed to a
    /// `Text`, which is what keeps the popover's first paint under 100 ms.
    case compact

    /// Adds subtitle, a bounded body, the attachments chip and the thread marker.
    case detailed
}

// MARK: - TimelineItem

/// One row, ready to render: the archived notification plus the two things the
/// view would otherwise have to look up for itself.
///
/// The view never joins, never evaluates rules and never queries — it is handed
/// a value and draws it. That is what lets grouping stay a pure function the
/// tests can call directly, and what keeps `NotificationRow` cheap enough to
/// instantiate two hundred at a time.
public struct TimelineItem: Identifiable, Equatable, Sendable {
    // MARK: Lifecycle

    public init(
        id: Int64,
        notification: ArchivedNotification,
        appName: String,
        bundleID: String? = nil,
        triage: Triage = .none,
        isSelected: Bool = false,
        isAppMuted: Bool = false
    ) {
        self.id = id
        self.notification = notification
        self.appName = appName
        self.bundleID = bundleID
        self.triage = triage
        self.isSelected = isSelected
        self.isAppMuted = isAppMuted
    }

    /// Builds an item for a stored row, resolving app metadata from the app
    /// table.
    ///
    /// Returns `nil` for a row with no id: an unsaved row has no stable identity
    /// for `ForEach`, and leaving it out is better than diffing it against an
    /// invented one.
    public init?(
        row: ArchivedNotification,
        apps: [Int64: AppRecord],
        triage: Triage = .none,
        isSelected: Bool = false
    ) {
        guard let id = row.id else {
            return nil
        }
        let app = apps[row.appId]
        self.init(
            id: id,
            notification: row,
            appName: app?.displayName ?? app?.bundleId ?? String(localized: "Unknown app"),
            bundleID: app?.bundleId,
            triage: triage,
            isSelected: isSelected,
            isAppMuted: app?.isMuted ?? false
        )
    }

    // MARK: Public

    /// The archive row id. Stable across refreshes, which is why `ForEach` keys
    /// on it rather than on an index or a fresh `UUID`.
    public let id: Int64

    public let notification: ArchivedNotification

    /// `apps.display_name`, falling back to the bundle id when the app was never
    /// named, and to a placeholder when the app row is gone entirely.
    public let appName: String

    /// The owning app's bundle id — what the filter chips and per-app mute key
    /// on. `nil` only when the app row could not be found.
    public let bundleID: String?

    /// Derived at read time, never stored — see ``BackglanceCore/Triage``.
    public let triage: Triage

    /// Whether this is the keyboard selection. Part of the value so a selection
    /// change redraws exactly two rows.
    public var isSelected: Bool

    /// The raw `apps.is_muted` flag for this row's app, carried onto the item
    /// at build time so the context menu's item 8 ("Mute ‹App› in Timeline" /
    /// "Unmute ‹App›", BACKGLANCE-239) can label itself without a synchronous
    /// archive read from inside menu construction.
    ///
    /// Deliberately **not** the same question as ``Triage/muted``. VIP beats
    /// mute (docs/features/RULES.md#edge-cases-and-error-handling): a row that
    /// matched both a `mute` rule for its app and a `vip` rule for itself has
    /// `triage.muted == false` — it is not collapsed into the Muted group —
    /// even though `apps.is_muted` is still `true` underneath. Labelling item
    /// 8 from `triage.muted` would flip to "Mute" on exactly that one
    /// VIP-pinned row while every unmatched sibling notification from the same
    /// app still correctly says "Unmute", which is confusing in a way a raw
    /// per-app flag is not: this property answers "is the app muted", not "is
    /// this particular row showing muted".
    public let isAppMuted: Bool

    /// Pinned by the user's own toggle or by a VIP rule — either floats the row
    /// to the top of its day.
    public var isPinned: Bool {
        notification.isPinned || triage.pinned
    }
}
