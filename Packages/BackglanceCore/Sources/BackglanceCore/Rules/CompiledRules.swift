import Foundation

// MARK: - CompiledRules

/// The output of `RulesEngine.compile(_:)`: a rule set pre-folded and pre-sorted into
/// exactly the shape `RulesEngine.evaluate(_:compiled:bundleID:)` walks on every
/// notification, so the hot path does no trimming, folding, or colour parsing of its own.
///
/// Plain `Sendable`, not `@unchecked Sendable`. Every stored value — `Entry`'s `Int64`s,
/// `String`s, `Rule.Kind`, `Rule.MatchField`, `HighlightColor?` and `Matcher` — is a
/// naturally `Sendable` `let`, so there is nothing here the compiler cannot already
/// verify. That is only true because ``Matcher`` carries no `Regex`; see its doc comment.
public struct CompiledRules: Sendable {
    // MARK: Lifecycle

    public init(entries: [Entry]) {
        self.entries = entries
    }

    // MARK: Public

    /// One compiled rule. `compile(_:)` sorts its output `priority DESC, id ASC`, so
    /// `entries` is already in the order `evaluate` needs — the id tie-break makes that
    /// order deterministic across runs, which the worked example in
    /// docs/features/RULES.md#evaluation-order-and-conflict-resolution depends on.
    public struct Entry: Sendable {
        // MARK: Lifecycle

        public init(
            id: Int64,
            priority: Int,
            kind: Rule.Kind,
            field: Rule.MatchField,
            scope: String?,
            color: HighlightColor?,
            matcher: Matcher
        ) {
            self.id = id
            self.priority = priority
            self.kind = kind
            self.field = field
            self.scope = scope
            self.color = color
            self.matcher = matcher
        }

        // MARK: Public

        /// The originating `rules.id`, or `Rule.draftID` for an unsaved editor draft.
        public let id: Int64

        /// Higher wins ties among matching `highlight`/`regex` rules; also the primary
        /// compiled sort key.
        public let priority: Int

        public let kind: Rule.Kind

        /// Which of the notification's folded fields `matcher` is tested against.
        /// Meaningless for a `.bundleID` matcher, which compares `bundleID` directly and
        /// never reads a `MatchInput` field.
        public let field: Rule.MatchField

        /// Lowercased app-scope bundle id from `rules.app_bundle_id`. `nil` means the rule
        /// applies to every app.
        public let scope: String?

        /// Set only for `kind == .highlight` (and, in v1.x, `.regex`); `compile(_:)`
        /// rejects those kinds outright when this would be `nil`, so a `highlight` entry
        /// here always has a colour.
        public let color: HighlightColor?

        public let matcher: Matcher
    }

    /// How a compiled rule's pattern is compared against a folded field.
    ///
    /// v1.0 ships three cases. docs/features/RULES.md#business-logic-rulesengine's sketch
    /// also lists a fourth, `.regex(RegexRuleEvaluator)`, for the `kind = .regex` rules
    /// planned in v1.x. It is deliberately **absent** here: `RuleLimits.regexRulesEnabled`
    /// is `false` for the whole of v1.0, so `RulesEngine.compile(_:)` rejects every regex
    /// rule with `.notAvailableInThisVersion` before a matcher would ever be built for it
    /// — see `RulesEngine+Compile.swift`. A `.regex` case could therefore never be
    /// constructed in this version, which makes it dead code that would exist only to
    /// carry a compiled `Regex` around — and carrying one would force this whole type back
    /// to `@unchecked Sendable` for a case nothing can reach. The v1.x task that flips
    /// `regexRulesEnabled` adds the case, `RegexRuleEvaluator`, and the `@unchecked
    /// Sendable` it requires, together, so the two never drift apart.
    public enum Matcher: Sendable {
        /// Plain containment: the folded needle appears anywhere in the folded haystack.
        /// Compiled from a bare (unquoted) pattern.
        case substring(String)
        /// Word-bounded containment: the folded needle is bounded by a non-word character
        /// or a string end on both sides. Compiled from a pattern wrapped in double
        /// quotes. See `RulesEngine.containsWord(_:in:)`.
        case word(String)
        /// Exact equality against a lowercased bundle id. Compiled whenever
        /// `match_field == .app`, regardless of `kind`.
        case bundleID(String)
    }

    /// The rule-free rule set. `evaluate(_:compiled:bundleID:)` takes its fast path on
    /// `isEmpty`, so an app with no rules configured pays nothing for triage.
    public static let empty = CompiledRules(entries: [])

    public let entries: [Entry]

    public var isEmpty: Bool {
        entries.isEmpty
    }
}
