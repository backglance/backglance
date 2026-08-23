import Foundation

// MARK: - RulesEngine + compile

/// `compile(_:)` turns a raw `[Rule]` into ``CompiledRules`` plus whatever problems it had
/// to skip past on the way — see
/// docs/features/RULES.md#business-logic-rulesengine.
///
/// Never throws, and never lets one bad rule take down the rest: a rule is either folded
/// into a working ``CompiledRules/Entry`` or it is skipped and reported as a
/// ``RuleCompileError``. That single contract covers a hand-edited import, a rules file
/// from a future version, and a rule the editor let through before a validation change —
/// all fail the same soft way, and the other rules in the set keep working.
extension RulesEngine {
    /// Folds `rules` into a sorted ``CompiledRules`` ready for
    /// `evaluate(_:compiled:bundleID:appIsMuted:)`, plus the ``RuleCompileError``s for
    /// whatever was skipped.
    ///
    /// - Parameter rules: every rule, enabled or not — disabled rules are filtered here,
    ///   not by the caller, so a caller that forgets to filter still behaves correctly.
    /// - Returns: entries sorted `priority DESC, id ASC` (the order `evaluate` walks), and
    ///   the compile problems in `rules`' original order.
    public static func compile(_ rules: [Rule]) -> (CompiledRules, [RuleCompileError]) {
        var entries: [CompiledRules.Entry] = []
        var problems: [RuleCompileError] = []

        for rule in rules where rule.isEnabled {
            let id = rule.id ?? Rule.draftID
            let raw = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !raw.isEmpty else {
                problems.append(RuleCompileError(
                    ruleID: id,
                    message: String(localized: "Pattern is empty."),
                    kind: .emptyPattern
                ))
                continue
            }
            guard raw.count <= RuleLimits.maxPatternLength else {
                problems.append(RuleCompileError(
                    ruleID: id,
                    message: String(localized: "Pattern is over \(RuleLimits.maxPatternLength) characters."),
                    kind: .patternTooLong
                ))
                continue
            }

            var color: HighlightColor?
            if rule.kind == .highlight || rule.kind == .regex {
                guard let resolved = rule.color.flatMap(HighlightColor.init(rawValue:)) else {
                    problems.append(RuleCompileError(
                        ruleID: id,
                        message: String(localized: "Unknown highlight colour."),
                        kind: .unknownColorToken
                    ))
                    continue
                }
                color = resolved
            }

            guard let matcher = compiledMatcher(for: rule, id: id, pattern: raw, problems: &problems) else {
                continue
            }

            entries.append(CompiledRules.Entry(
                id: id,
                priority: rule.priority,
                kind: rule.kind,
                field: rule.matchField,
                scope: rule.appBundleId?.lowercased(),
                color: color,
                matcher: matcher
            ))
        }

        entries.sort { lhs, rhs in
            lhs.priority == rhs.priority ? lhs.id < rhs.id : lhs.priority > rhs.priority
        }
        return (CompiledRules(entries: entries), problems)
    }

    /// The matcher for one already length- and colour-validated rule, or `nil` if none
    /// could be built. In v1.0 that is exactly `kind == .regex`, reported as
    /// `.notAvailableInThisVersion` — split out of `compile(_:)` so that method reads as
    /// the linear validation pipeline it is, instead of nesting the one case that actually
    /// branches on `kind` inside it.
    private static func compiledMatcher(
        for rule: Rule,
        id: Int64,
        pattern: String,
        problems: inout [RuleCompileError]
    ) -> CompiledRules.Matcher? {
        if rule.kind == .regex {
            guard RuleLimits.regexRulesEnabled else {
                problems.append(RuleCompileError(
                    ruleID: id,
                    message: String(localized: "Regex rules arrive in a later version."),
                    kind: .notAvailableInThisVersion
                ))
                return nil
            }
            // `RuleLimits.regexRulesEnabled` only ever flips to `true` in the v1.x task
            // that adds `CompiledRules.Matcher.regex` and `RegexRuleEvaluator` in the same
            // change — see the note on `CompiledRules.Matcher`. Reaching this point today
            // would mean the flag flipped without the matcher arriving alongside it, which
            // is a build the fixture/adapter playbook would call a broken invariant, not a
            // recoverable input — hence the loud failure rather than a silent skip.
            preconditionFailure(
                "RuleLimits.regexRulesEnabled is true but CompiledRules.Matcher has no .regex case yet"
            )
        }

        if rule.matchField == .app {
            return .bundleID(pattern.lowercased())
        }
        if pattern.count >= 2, pattern.hasPrefix("\""), pattern.hasSuffix("\"") {
            return .word(String(pattern.dropFirst().dropLast()).matchKey)
        }
        return .substring(pattern.matchKey)
    }
}
