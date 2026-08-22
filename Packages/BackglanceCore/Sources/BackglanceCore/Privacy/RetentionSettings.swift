import Foundation

// MARK: - RetentionSettings

/// The global retention default, and where it is stored.
///
/// A value rather than a service, read fresh where it is needed — `RetentionJob` reads it
/// at the top of each pass, the pane reads it on appearance. There is no cache to
/// invalidate and no "apply" step to forget, which matters for a setting whose whole
/// effect is deletion: a user who shortens the window and then sees nothing happen for six
/// hours should at least be sure the setting itself took.
///
/// Only the *global* default lives here. Per-app overrides are `apps.retention`, because
/// they are facts about that archive's apps and have to travel with it — the same split as
/// redaction and exclusions.
///
/// See docs/features/PRIVACY_CONTROLS.md#policy-values-and-inheritance.
public struct RetentionSettings: Sendable, Equatable {
    // MARK: Lifecycle

    /// No default value on purpose. With one, `RetentionSettings()` compiles as either
    /// this or ``init(defaults:)`` — ambiguous to the compiler, and worse, ambiguous to a
    /// reader, who cannot tell whether it means "the shipped policy" or "whatever this Mac
    /// has stored". Naming the argument makes the two say what they mean.
    public init(global: RetentionPolicy) {
        self.global = global
    }

    /// Reads the global default.
    ///
    /// An unreadable or unrecognised value falls back to the shipped default rather than
    /// to `forever`. Both are "safe" in the sense of losing nothing, and that is exactly
    /// why the choice needs stating: falling back to `forever` would mean a preference
    /// written by a newer build silently turned pruning off, and an archive that quietly
    /// keeps everything is the failure this feature exists to prevent.
    public init(defaults: UserDefaults = .standard) {
        let stored = defaults.string(forKey: Self.globalKey) ?? ""
        self.init(global: RetentionPolicy(rawValue: stored) ?? .globalDefault)
    }

    // MARK: Public

    public static let globalKey = "privacy.globalRetention"

    /// The choices the global picker offers, in the order it offers them.
    public static let globalChoices: [RetentionPolicy] = [.hours24, .days7, .days30, .forever]

    /// What applies to every app that has not been given an override.
    ///
    /// `never` is not offered here. It means "this app is never stored", which is a
    /// statement about one app; as a global it would be a way to switch the whole product
    /// off from a picker labelled "Keep notifications for", and someone who wants that
    /// wants to quit Backglance rather than run it archiving nothing.
    public let global: RetentionPolicy

    public static func save(global: RetentionPolicy, to defaults: UserDefaults) {
        defaults.set(global.rawValue, forKey: globalKey)
    }

    /// The policy in force for `app`.
    public func effectiveRetention(for app: AppRecord) -> RetentionPolicy {
        app.effectiveRetention(global: global)
    }

    /// The instant before which `app`'s notifications have expired, or `nil` if none do.
    public func cutoff(for app: AppRecord, from now: Date) -> Date? {
        effectiveRetention(for: app).cutoff(from: now)
    }
}
