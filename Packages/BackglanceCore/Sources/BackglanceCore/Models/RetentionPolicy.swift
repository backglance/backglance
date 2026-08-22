import Foundation

// MARK: - RetentionPolicy

/// How long an app's notifications survive before `RetentionJob` prunes them.
///
/// Raw values are the archive column vocabulary: `apps.retention` and the
/// global default both store one of these strings verbatim (never JSON,
/// never a Swift case name) — see
/// docs/architecture/DATABASE_SCHEMA.md#column-reference and
/// docs/api/API_DOCUMENTATION.md's `RetentionPolicy` entry ("Stability:
/// Stable"). Changing a raw value is therefore a schema-breaking change, not
/// a rename.
public enum RetentionPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case hours24 = "24h"
    case days7 = "7d"
    case days30 = "30d"
    case forever
    case never

    // MARK: Public

    /// The policy in force before the user has chosen one.
    ///
    /// Thirty days is meant to match what people expect of a "recent history": long
    /// enough to find last week's delivery code or Monday's meeting link, short enough
    /// that the archive does not become a years-long log of someone's life by accident.
    /// `forever` is one click away for anyone who wants a real archive, which is the
    /// right way round — keeping less by default and more on request.
    public static let globalDefault = RetentionPolicy.days30

    /// How far back from now a notification is kept, or `nil` when the
    /// policy has no time bound.
    ///
    /// `nil` for both `.forever` (never prune) and `.never` (this app is
    /// never stored at all — enforced by `ExclusionList` before insert, not
    /// by a retention window, so there is no interval to express).
    public var interval: TimeInterval? {
        switch self {
        case .hours24: 60 * 60 * 24
        case .days7: 60 * 60 * 24 * 7
        case .days30: 60 * 60 * 24 * 30
        case .forever,
             .never: nil
        }
    }

    /// The instant before which a notification has expired, or `nil` when nothing
    /// expires by age.
    ///
    /// Measured from `delivered_at`, not `captured_at`. A first-launch import that brings
    /// in a six-day-old notification under a seven-day policy sees it expire tomorrow,
    /// which is what the policy says: the user asked to keep a week of *notifications*,
    /// not a week of Backglance having run.
    public func cutoff(from now: Date) -> Date? {
        interval.map { now.addingTimeInterval(-$0) }
    }
}

// MARK: - AppRetention

/// Per-app retention as stored in `apps.retention`: every `RetentionPolicy`
/// case plus `'inherit'`, meaning "use the global default".
///
/// `RetentionPolicy` alone cannot express "no per-app override" without
/// reserving one of its cases for it — `AppRetention` layers that meaning on
/// top instead of overloading `RetentionPolicy` itself, which stays the
/// stable, reusable policy vocabulary (also used for the global default,
/// which has no "inherit" of its own).
public enum AppRetention: RawRepresentable, Codable, Hashable, Sendable {
    case inherit
    case policy(RetentionPolicy)

    // MARK: Lifecycle

    public init?(rawValue: String) {
        if rawValue == "inherit" {
            self = .inherit
            return
        }
        guard let policy = RetentionPolicy(rawValue: rawValue) else {
            return nil
        }
        self = .policy(policy)
    }

    // MARK: Public

    public var rawValue: String {
        switch self {
        case .inherit: "inherit"
        case let .policy(policy): policy.rawValue
        }
    }
}

// MARK: - AppRetention + effective policy

public extension AppRetention {
    /// The policy that actually applies to this app.
    ///
    /// `inherit` is not a policy, it is the absence of one — which is why it cannot be a
    /// `RetentionPolicy` case. Resolving it needs the global default, and the global
    /// default has no "inherit" of its own to resolve.
    func effectivePolicy(global: RetentionPolicy) -> RetentionPolicy {
        switch self {
        case .inherit: global
        case let .policy(policy): policy
        }
    }
}

public extension AppRecord {
    /// The retention policy in force for this app's notifications.
    func effectiveRetention(global: RetentionPolicy) -> RetentionPolicy {
        retention.effectivePolicy(global: global)
    }
}
