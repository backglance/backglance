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
