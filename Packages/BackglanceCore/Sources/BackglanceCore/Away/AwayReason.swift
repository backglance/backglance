import Foundation

// MARK: - AwayReason

/// Why the Mac counted as unattended.
///
/// Raw values are the archive column vocabulary (`away_sessions.reason`) — never a
/// Swift case name change without a migration.
///
/// A session can have several causes at once: locking the lid while a Focus is on
/// produces one session whose causes are `{focus, locked, asleep}`. The column keeps
/// only the *primary* reason — the first cause chronologically — and the full set
/// lives in ``AwaySessionTracker/EndedSession/reasons`` for as long as it is useful.
/// See docs/features/MISSED_DIGEST.md#the-away-session-model.
public enum AwayReason: String, Codable, Hashable, Sendable, CaseIterable {
    /// Screen lock. Reliable: `com.apple.screenIsLocked`.
    case locked

    /// System or display sleep. Reliable: `NSWorkspace` public API.
    case asleep

    /// ⚠️ A Focus swallowed the banner. Fragile — inferred from a private file, and
    /// absent entirely when that file cannot be read.
    case focus

    /// ⚠️ A presentation or screen share was running. Heuristic.
    case presenting

    /// The user said so. Exact by definition.
    case manual
}
