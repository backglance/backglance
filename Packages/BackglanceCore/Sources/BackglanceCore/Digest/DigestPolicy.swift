import Foundation

// MARK: - DigestPolicy

/// Whether a finished away session earns a digest at all.
///
/// The threshold answers "long enough?" and the disabled-reason set answers "this kind of
/// away?". Both are the user's settings, and both are checked *before* anything is built:
/// a digest that is written and then not shown is a row nobody asked for, and rule 7 of
/// the never-nagging contract ("never means never") is only true if `never` stops the
/// build rather than the presentation.
///
/// See docs/features/MISSED_DIGEST.md#never-nagging-rules.
public struct DigestPolicy: Sendable, Equatable {
    // MARK: Lifecycle

    public init(threshold: DigestThreshold, disabledReasons: Set<AwayReason> = []) {
        self.threshold = threshold
        self.disabledReasons = disabledReasons
    }

    /// Reads both settings, defaulting to "5 minutes, every reason counts".
    ///
    /// An unreadable or unrecognised reason is dropped rather than treated as a reason to
    /// suppress: a preference written by a newer build must not silently switch digests
    /// off for a reason this build cannot name.
    public init(defaults: UserDefaults = .standard) {
        let stored = defaults.stringArray(forKey: Self.disabledReasonsKey) ?? []
        self.init(
            threshold: DigestThreshold(defaults: defaults),
            disabledReasons: Set(stored.compactMap(AwayReason.init(rawValue:)))
        )
    }

    // MARK: Public

    public static let disabledReasonsKey = "digest.disabledReasons"

    public let threshold: DigestThreshold

    /// Kinds of away the user does not want summarised. Empty by default.
    public let disabledReasons: Set<AwayReason>

    public static func save(disabledReasons: Set<AwayReason>, to defaults: UserDefaults) {
        defaults.set(disabledReasons.map(\.rawValue).sorted(), forKey: disabledReasonsKey)
    }

    /// Whether this session should have a digest built for it.
    ///
    /// Three gates, in the order they can each say no:
    ///
    /// 1. `never` means never — nothing is built, though the session is still recorded so
    ///    `is:missed` keeps working.
    /// 2. The session has to have met the duration threshold. `AwaySessionTracker` already
    ///    decided this against the same setting; re-checking `never` above rather than
    ///    trusting that flag is deliberate, because the flag is computed from a closure
    ///    the caller supplies and this is the invariant that must not depend on it.
    /// 3. At least one of the session's causes has to be one the user wants summarised.
    ///    *One*, not the primary: locking the lid during a Focus is still a lock, and
    ///    someone who switched off Focus digests did not thereby ask to stop hearing
    ///    about what arrived while their Mac was shut.
    public func allows(reasons: Set<AwayReason>, meetsThreshold: Bool) -> Bool {
        guard !threshold.isDisabled, meetsThreshold else {
            return false
        }
        return !reasons.isEmpty && !reasons.isSubset(of: disabledReasons)
    }

    /// Convenience over ``allows(reasons:meetsThreshold:)`` for a session straight from
    /// the tracker, which is the only place the full cause set still exists — the
    /// `away_sessions` row keeps just the primary one.
    public func allows(_ ended: AwaySessionTracker.EndedSession) -> Bool {
        allows(reasons: ended.reasons, meetsThreshold: ended.meetsDigestThreshold)
    }
}
