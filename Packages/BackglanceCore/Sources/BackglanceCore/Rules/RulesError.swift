import Foundation

// MARK: - RulesError

/// Errors from the instance side of `RulesEngine` — everything that is not a per-rule
/// compile problem. A bad pattern is a ``RuleCompileError``, collected in
/// `RulesEngine.problems` and never thrown, because one bad rule must never take triage down
/// for the other rules in the set. `RulesError` is for the handful of things that really are
/// exceptional: an archive write that named a row which is not there.
///
/// docs/features/RULES.md's sketch of this type also lists `.invalidEntry(index:reason:)`,
/// `.importFormatMismatch(String)` and `.importVersionUnsupported(Int)` for `importRules(from:)`
/// — BACKGLANCE-210's `backglance.rules` JSON envelope, not this task's problem. They are left
/// out here rather than guessed at: `RulesEngine` has no import path yet to give them a real
/// shape, and inventing associated values now would commit BACKGLANCE-210 to a choice this
/// task has no way to validate.
public enum RulesError: Error, Equatable, Sendable {
    /// `setAppMuted(bundleID:muted:)` touched no row: no archived app has this bundle id.
    case unknownApp(String)
}

// MARK: LocalizedError

extension RulesError: LocalizedError {
    /// One plain sentence for the UI, matching `ArchiveError.userMessage`'s posture: no
    /// paths, no SQL. `bundleID` is safe here — it is the app identifier the settings pane
    /// already shows next to every rule and every per-app setting, never notification
    /// content.
    public var errorDescription: String? {
        switch self {
        case let .unknownApp(bundleID):
            "No archived app with bundle id \(bundleID)."
        }
    }
}
