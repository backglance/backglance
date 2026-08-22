import Foundation

// MARK: - RuleCompileError

/// Why one rule could not be compiled into a working ``CompiledRules/Entry``.
///
/// Never thrown: `RulesEngine.compile(_:)` collects these into an array alongside the
/// rules it *did* compile, so one bad pattern in a forty-rule set skips that one rule and
/// reports it, rather than taking down triage for the other thirty-nine. Surfaced twice in
/// the settings UI (BACKGLANCE-209, not this task): inline under the pattern field while
/// editing, and as an orange warning badge on the row in the rules list, with `message` in
/// its tooltip. A rule with a problem is skipped by the engine but never deleted or
/// silently rewritten — the user's data stays theirs to fix. See
/// docs/features/RULES.md#business-logic-rulesengine.
public struct RuleCompileError: Error, Equatable, Sendable, Identifiable {
    // MARK: Lifecycle

    public init(ruleID: Int64, message: String, kind: Kind) {
        self.ruleID = ruleID
        self.message = message
        self.kind = kind
    }

    // MARK: Public

    /// Why the rule was skipped.
    public enum Kind: String, Equatable, Sendable {
        /// The pattern was empty after trimming leading/trailing whitespace.
        case emptyPattern
        /// The pattern was over `RuleLimits.maxPatternLength` characters.
        case patternTooLong
        /// A `kind = .regex` pattern failed to compile as a `Regex`. v1.x only — unused
        /// while `RuleLimits.regexRulesEnabled` is `false`, since every regex rule is
        /// rejected with `.notAvailableInThisVersion` before its pattern is ever parsed.
        case invalidRegex
        /// A `highlight` (or, in v1.x, `regex`) rule's `color` was `nil` or not one of
        /// ``HighlightColor``'s five tokens.
        case unknownColorToken
        /// `kind = .regex` while `RuleLimits.regexRulesEnabled` is `false` — the whole of
        /// v1.0.
        case notAvailableInThisVersion
    }

    /// The rule this problem belongs to. `Rule.draftID` for an unsaved editor draft that
    /// has no archive id yet.
    public let ruleID: Int64

    /// Which kind of problem this is — drives the icon and grouping in the settings list.
    public let kind: Kind

    /// A short, user-facing sentence describing the rule's own pattern or configuration.
    /// Never notification content: this type never carries anything read from an
    /// `ArchivedNotification`.
    public let message: String

    /// `Identifiable` by rule id, not a synthesized UUID, so SwiftUI's `ForEach` over the
    /// settings list's problems can key directly off the rule the badge belongs to.
    public var id: Int64 {
        ruleID
    }
}
