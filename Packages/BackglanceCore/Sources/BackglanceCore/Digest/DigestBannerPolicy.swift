import Foundation

// MARK: - DigestBannerPolicy

/// Whether a built digest also earns a local notification banner.
///
/// Separate from ``DigestPolicy``, which decides whether a digest exists at all. This one
/// only ever *narrows* that: a banner is an interruption on top of a summary, so every
/// gate here can say no and none can say yes on its own.
///
/// The decision is a pure function of settings, timings and one authorization flag, so the
/// never-nagging rules it implements are testable without `UserNotifications` anywhere near
/// them. The app target's `DigestBannerPoster` does the actual posting and holds the only
/// import of that framework.
///
/// See docs/features/MISSED_DIGEST.md#the-local-notification-banner.
public struct DigestBannerPolicy: Sendable, Equatable {
    // MARK: Lifecycle

    public init(isEnabled: Bool, includesFocus: Bool = false, playsSound: Bool = false) {
        self.isEnabled = isEnabled
        self.includesFocus = includesFocus
        self.playsSound = playsSound
    }

    /// Reads the three settings. All default **off**.
    ///
    /// Off is not timidity, it is the permission rule: Backglance asks for Notifications
    /// authorization only from an explicit user action
    /// (docs/features/PERMISSIONS_PRIVACY.md#notifications-backglances-own-local-notifications),
    /// and a banner that defaulted on would have to ask for it on its own behalf the first
    /// time a session ended. The digest's default presentation is the popover, which needs
    /// no permission at all.
    public init(defaults: UserDefaults = .standard) {
        self.init(
            isEnabled: defaults.bool(forKey: Self.enabledKey),
            includesFocus: defaults.bool(forKey: Self.focusKey),
            playsSound: defaults.bool(forKey: Self.soundKey)
        )
    }

    // MARK: Public

    public static let enabledKey = "digest.banner.enabled"
    public static let focusKey = "digest.banner.focus"
    public static let soundKey = "digest.banner.sound"

    /// How soon after coming back an opened popover cancels the banner.
    ///
    /// They are already looking at the digest; posting a banner about the thing on their
    /// screen is the definition of nagging (rule 2).
    public static let popoverGrace: TimeInterval = 30

    public let isEnabled: Bool

    /// Whether Focus sessions get a banner too. Off even when banners are on: a Focus
    /// usually means "do not ping me", and honouring that after the fact is the point.
    public let includesFocus: Bool

    /// Off by default, and the reason `content.sound` is `nil` unless someone asks (rule 4).
    public let playsSound: Bool

    /// The whole decision, in the order the gates can each say no.
    ///
    /// - Parameters:
    ///   - reason: the session's primary cause.
    ///   - sessionEndedAt: when the user came back.
    ///   - popoverLastOpenedAt: when they last opened the popover, or `nil` if never.
    ///   - isAuthorized: whether `UNUserNotificationCenter` will actually deliver. A flag
    ///     rather than a `UNAuthorizationStatus` so this stays free of the framework —
    ///     and so "denied" and "never asked" collapse into the one thing that matters
    ///     here, which is that nothing would appear.
    public func allowsBanner(
        reason: AwayReason,
        sessionEndedAt: Date,
        popoverLastOpenedAt: Date?,
        isAuthorized: Bool
    ) -> Bool {
        guard isEnabled, isAuthorized else {
            return false
        }
        guard reason != .focus || includesFocus else {
            return false
        }
        return !alreadyLooked(endedAt: sessionEndedAt, lastOpenedAt: popoverLastOpenedAt)
    }

    // MARK: Private

    /// Whether the user opened the popover in the grace window after coming back.
    ///
    /// Anchored to the session's end rather than to "now minus 30 s": a digest that takes
    /// a moment to build must not slip past a popover the user opened the instant they sat
    /// down. An open from *before* they left is not looking at this digest, so it does not
    /// count either — which is why this is a window and not just "opened since".
    private func alreadyLooked(endedAt: Date, lastOpenedAt: Date?) -> Bool {
        guard let lastOpenedAt else {
            return false
        }
        return lastOpenedAt >= endedAt && lastOpenedAt <= endedAt.addingTimeInterval(Self.popoverGrace)
    }
}
