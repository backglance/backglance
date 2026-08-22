import Foundation

// MARK: - RuleLimits

/// The constants that keep rule compilation and evaluation cheap and bounded.
///
/// Shared by `RulesEngine` and, later, the settings editor (BACKGLANCE-209), so the
/// pattern-length cap the editor enforces while typing is the same one `compile(_:)`
/// enforces on a hand-edited import. The first four match
/// docs/security/SECURITY.md's "Regex rules and pathological patterns" section exactly —
/// pattern length, per-field input length, the per-evaluation time budget, and how many
/// budget violations auto-disable a rule. They live here rather than only inside a v1.x
/// regex evaluator because `maxPatternLength` and `maxInputLength` already bound v1.0's
/// substring and word matchers today: "bound the work, not the time" is not a
/// regex-only idea, it is how `compile`/`evaluate` stay a table-testable, allocation-cheap
/// pass over `[Rule]` regardless of what a caller hands them.
public enum RuleLimits {
    /// A pattern longer than this is rejected at compile and at import
    /// (`RuleCompileError.Kind.patternTooLong`). SECURITY.md's ceiling for the v1.x regex
    /// case; v1.0's substring/word matchers inherit the same bound rather than getting
    /// their own, since a 256-character keyword is already absurd and a shared limit is
    /// one fewer number for the editor to explain.
    public static let maxPatternLength = 256

    /// Each folded `MatchInput` field (`title`, `body`, `sender`, `any`) is truncated to
    /// this many characters, once, before any rule is tested against it.
    ///
    /// This is the enforcement point that keeps a pathological body — a multi-megabyte
    /// paste, or a body a malformed store adapter handed through unbounded — from turning
    /// `evaluate(_:compiled:bundleID:)` into an unbounded scan: `.substring`/`.word`
    /// containment costs `O(haystack)` per rule, so bounding the haystack once bounds the
    /// whole per-notification cost regardless of how many rules are compiled. Enforced in
    /// `MatchInput`'s folding step (`RulesEngine+Evaluate.swift`), not per-matcher, so
    /// every matcher — including the v1.x regex one — gets the bound for free instead of
    /// re-implementing it.
    public static let maxInputLength = 4_096

    /// Per-evaluation time budget for a `kind = .regex` rule (v1.x). Nothing in this
    /// package enforces it yet — v1.0 has no `.regex` case in `CompiledRules.Matcher`, see
    /// that type's doc comment for why — but the constant lives here, next to the other
    /// three SECURITY.md numbers, so the v1.x task that adds `RegexRuleEvaluator` finds
    /// one shared constant instead of introducing a second copy that could drift from it.
    public static let budget: Duration = .milliseconds(50)

    /// How many times a `regex` rule may exceed ``budget`` before it is auto-disabled
    /// (`is_enabled = 0`). v1.x only; see the note on ``budget``.
    public static let budgetViolationsBeforeDisable = 3

    /// Whether `kind = .regex` rules compile to a real matcher. `false` for the whole of
    /// v1.0: `RulesEngine.compile(_:)` reports every regex rule as
    /// `RuleCompileError.Kind.notAvailableInThisVersion` and never produces a `.regex`
    /// matcher, because there is no such case to produce — see `CompiledRules.Matcher`.
    /// Flips to `true` in the v1.x milestone that adds both `.regex` and
    /// `RegexRuleEvaluator` together.
    public static let regexRulesEnabled = false

    /// The instance-side triage cache's row cap (`RulesEngine`'s `Snapshot.triage`, not
    /// built by this task — see `RulesEngine.swift`'s doc comment). Documented here
    /// because it is a limits constant like the others, alongside the numbers it is meant
    /// to be read next to; `compile(_:)` and `evaluate(_:compiled:bundleID:)` never read
    /// it themselves.
    public static let triageCacheLimit = 5_000
}
