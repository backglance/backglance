import Foundation

// MARK: - Triage

/// The result of evaluating the rule set against one notification: derived,
/// never stored.
///
/// There is no `triage` column anywhere in the archive and there will not be
/// one. Triage is computed at read time in `TimelineStore.regroup()` so that
/// editing a rule re-triages all of history on the next render, rather than
/// needing a full-table rewrite — the trade-off is argued in
/// docs/features/RULES.md#when-rules-are-evaluated.
///
/// It maps to presentation in exactly three places, all in
/// docs/features/TIMELINE.md: ``highlight`` tints the row background,
/// ``pinned`` floats it to the top of its day with a pin glyph, and ``muted``
/// moves it into the trailing "Muted (n)" group and out of the unread badge.
/// Nothing here reaches `UNUserNotificationCenter` or the system store: rules
/// are visual triage only and never change what macOS delivers.
public struct Triage: Equatable, Sendable {
    // MARK: Lifecycle

    public init(
        highlight: HighlightColor? = nil,
        pinned: Bool = false,
        muted: Bool = false,
        matchedRuleIDs: [Int64] = []
    ) {
        self.highlight = highlight
        self.pinned = pinned
        self.muted = muted
        self.matchedRuleIDs = matchedRuleIDs
    }

    // MARK: Public

    /// No rule matched. The fast path for an empty rule set, and the value the
    /// timeline uses everywhere until `RulesEngine` ships.
    public static let none = Triage()

    /// Row background tint, from the winning `highlight` rule's colour token.
    public var highlight: HighlightColor?

    /// Pinned to the top of its day. Set by a `vip` rule; the user's manual
    /// `ArchivedNotification/isPinned` is honoured alongside it by the timeline,
    /// which is why this stays purely rule-derived.
    public var pinned = false

    /// Collapsed into the day's trailing "Muted (n)" group and excluded from the
    /// unread badge. Never excluded from the archive, search, export or analytics.
    public var muted = false

    /// Matching rule ids in compiled order — the row inspector's "Matched: …"
    /// line and the `is:vip` search filter read this.
    public var matchedRuleIDs: [Int64] = []
}
