import Foundation

// MARK: - DigestThreshold

/// How long the user has to have been away before a digest is worth showing.
///
/// The point of a threshold is that a digest is an interruption, however quiet. Stepping
/// away for two minutes and coming back to a summary of the one notification that arrived
/// is worse than no summary at all, so the default asks for five minutes.
///
/// A session below the threshold is still **recorded**. The row costs nothing, `is:missed`
/// reads it, and the away model stays honest about what happened; only the presentation
/// is suppressed. See docs/features/MISSED_DIGEST.md#session-merging-and-thresholds.
///
/// Raw values are the stored vocabulary and must not change without a migration of the
/// preference.
public enum DigestThreshold: String, CaseIterable, Codable, Sendable {
    /// Any away session with at least one notification earns a digest.
    case always

    /// The default.
    case after5min

    /// For people who step away often.
    case after15min

    /// No digests at all. Away sessions are still tracked, so `is:missed` keeps working.
    case never

    // MARK: Lifecycle

    /// Reads the user's choice, defaulting to ``after5min`` when unset or unrecognised.
    ///
    /// An unrecognised value means a preference written by a newer build, and falling back
    /// to the default is better than refusing to start.
    public init(defaults: UserDefaults) {
        self = defaults.string(forKey: Self.defaultsKey).flatMap(Self.init(rawValue:)) ?? .after5min
    }

    // MARK: Public

    public static let defaultsKey = "digest.threshold"

    /// What the tracker compares a finished session's duration against.
    ///
    /// ``never`` is `.infinity` rather than a large number: no finite duration is `>=` it,
    /// so "never" is never a threshold someone can outlast by being away long enough.
    public var minimumDuration: TimeInterval {
        switch self {
        case .always: 0
        case .after5min: 300
        case .after15min: 900
        case .never: .infinity
        }
    }

    /// Whether digests are switched off entirely.
    ///
    /// Distinct from a long threshold: the digest build can skip its work altogether
    /// rather than build something it will not show.
    public var isDisabled: Bool {
        self == .never
    }

    public static func save(_ threshold: DigestThreshold, to defaults: UserDefaults) {
        defaults.set(threshold.rawValue, forKey: defaultsKey)
    }

    /// The `minDuration` closure ``AwaySessionTracker`` takes.
    ///
    /// A closure rather than a value because the tracker reads it once per finished
    /// session: changing the setting takes effect on the next session rather than the
    /// next launch, with nothing to rebuild.
    public static func minDuration(
        reading defaults: UserDefaults = .standard
    ) -> @Sendable () -> TimeInterval {
        { DigestThreshold(defaults: defaults).minimumDuration }
    }
}
