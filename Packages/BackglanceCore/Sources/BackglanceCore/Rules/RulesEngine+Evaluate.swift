import Foundation

// MARK: - RulesEngine + evaluate

/// `evaluate(_:compiled:bundleID:appIsMuted:)` turns one notification into its ``Triage``
/// by walking a ``CompiledRules`` in compiled order — this mirrors, step for step,
/// docs/features/RULES.md#evaluation-order-and-conflict-resolution's numbered algorithm.
///
/// Pure, synchronous, and never throws: no archive access, no locking, nothing for the
/// instance side's cache to guard against. Per-app mute (`apps.is_muted`) cannot be looked
/// up here — this function has no archive access — so it is taken as the `appIsMuted`
/// parameter instead; the instance-side `RulesEngine.evaluate(_:)` (BACKGLANCE-208's
/// problem, not this task) is what resolves both `bundleID` and `appIsMuted` before
/// calling in.
public extension RulesEngine {
    /// Triage for one notification against an already-compiled rule set.
    ///
    /// - Parameters:
    ///   - notification: the row to triage. Its `title`, `subtitle`, `body` and `sender`
    ///     are folded into a `MatchInput` once, up front, regardless of how many rules are
    ///     compiled — rule count multiplies comparisons, not foldings.
    ///   - compiled: the sorted, pre-folded rule set from `compile(_:)`.
    ///   - bundleID: the notification's app's bundle id, if resolved. `nil` is a
    ///     fail-closed signal, not "match everything": app-scoped rules and
    ///     `match_field == .app` rules are skipped rather than assumed to match, because a
    ///     mute or a VIP pin that cannot be proven to apply to this app must not apply to
    ///     it.
    ///   - appIsMuted: mirrors `apps.is_muted` for `bundleID`. `evaluate` has no archive
    ///     access to look this up itself, so it is a parameter. Applied last, after the
    ///     rule-driven VIP-beats-mute resolution below, with the same VIP exemption — this
    ///     is what lets a caller fold per-app mute into the same `Triage` without a second
    ///     code path or a second definition of "VIP wins".
    /// - Returns: every matching rule's contribution, resolved per the doc's ordering.
    ///   `matchedRuleIDs` records every rule that matched — including ones a later,
    ///   higher-priority rule outvoted for the highlight colour — in compiled order.
    static func evaluate(
        _ notification: ArchivedNotification,
        compiled: CompiledRules,
        bundleID: String? = nil,
        appIsMuted: Bool = false
    ) -> Triage {
        guard !compiled.isEmpty else {
            // Fast path: no rules to walk, but per-app mute is not a rule — it must still
            // apply even when `compiled` is `.empty`, or muting an app with zero
            // configured rules would silently do nothing.
            return appIsMuted ? Triage(muted: true) : .none
        }

        let input = MatchInput(notification)
        let app = bundleID?.lowercased()
        var triage = Triage()
        var bestHighlightPriority = Int.min

        for entry in compiled.entries {
            if let scope = entry.scope {
                guard let app, scope == app else {
                    continue
                } // scoped to a different app
            }
            guard matches(entry, input: input, bundleID: app) else {
                continue
            }

            triage.matchedRuleIDs.append(entry.id)
            switch entry.kind {
            case .highlight,
                 .regex: // regex behaves like highlight once v1.x compiles one
                if let color = entry.color, entry.priority > bestHighlightPriority {
                    triage.highlight = color
                    bestHighlightPriority = entry.priority
                }

            case .vip:
                triage.pinned = true

            case .mute:
                triage.muted = true
            }
        }

        if triage.pinned {
            triage.muted = false // VIP beats mute, unconditionally, regardless of priority
        } else if appIsMuted {
            triage.muted = true // per-app mute, applied last, with the same VIP exemption
        }

        return triage
    }

    /// Convenience for callers that already hold `[Rule]` rather than a compiled set —
    /// search's `is:vip` post-filter and the digest, per docs/features/RULES.md. Compile
    /// problems are dropped here; call `compile(_:)` directly when they need to be
    /// surfaced to the user.
    static func evaluate(
        _ notification: ArchivedNotification,
        rules: [Rule],
        bundleID: String? = nil,
        appIsMuted: Bool = false
    ) -> Triage {
        let (compiled, _) = compile(rules)
        return evaluate(notification, compiled: compiled, bundleID: bundleID, appIsMuted: appIsMuted)
    }

    /// Whole-word containment over already-folded keys: `needle` must be bounded by a
    /// non-word character or a string end on both sides. `Character.isWordCharacter`
    /// (below) is Unicode-aware — `isLetter || isNumber` — so "İstanbul" and "Ünal" bound
    /// correctly without any locale-sensitive API involved.
    ///
    /// Not `private`: `RuleMatcherTests` exercises it directly as the one function that
    /// owns the word-boundary definition, rather than re-deriving boundary rules from
    /// `evaluate`'s behaviour end to end.
    internal static func containsWord(_ needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty, !haystack.isEmpty else {
            return false
        }

        var start = haystack.startIndex
        while let found = haystack.range(of: needle, options: .literal, range: start ..< haystack.endIndex) {
            let leftOK = found.lowerBound == haystack.startIndex
                || !haystack[haystack.index(before: found.lowerBound)].isWordCharacter
            let rightOK = found.upperBound == haystack.endIndex
                || !haystack[found.upperBound].isWordCharacter
            if leftOK, rightOK {
                return true
            }
            guard found.lowerBound < haystack.endIndex else {
                return false
            }
            start = haystack.index(after: found.lowerBound)
        }
        return false
    }

    /// Whether one compiled entry matches the folded input. `.bundleID` compares
    /// `bundleID` directly and never reads a `MatchInput` field; the other two matchers
    /// read whichever field `entry.field` names.
    private static func matches(_ entry: CompiledRules.Entry, input: MatchInput, bundleID: String?) -> Bool {
        switch entry.matcher {
        case let .bundleID(wanted): bundleID == wanted // nil id decides nothing
        case let .substring(needle): input.field(entry.field).contains(needle)
        case let .word(needle): containsWord(needle, in: input.field(entry.field))
        }
    }
}

// MARK: - Character + isWordCharacter

extension Character {
    /// `isLetter || isNumber`, Unicode-aware rather than ASCII-only — the definition
    /// `containsWord(_:in:)` bounds a whole-word match with.
    var isWordCharacter: Bool {
        isLetter || isNumber
    }
}

// MARK: - MatchInput

/// The notification's match fields, folded once per `evaluate` call and truncated to
/// `RuleLimits.maxInputLength` — the actual enforcement point for that limit, so a
/// pathological multi-megabyte body cannot turn matching into an unbounded scan no matter
/// how many rules are compiled against it.
struct MatchInput {
    // MARK: Lifecycle

    init(_ notification: ArchivedNotification) {
        title = Self.fold(notification.title)
        body = Self.fold(notification.body)
        sender = Self.fold(notification.sender)
        // `any` folds and truncates the combined text as one string, not the
        // concatenation of the already-truncated individual fields, so it matches the
        // doc's "title + subtitle + body + sender joined with newlines" definition exactly
        // rather than truncating each field twice.
        let joined = [notification.title, notification.subtitle, notification.body, notification.sender]
            .compactMap { $0 }
            .joined(separator: "\n")
        any = Self.fold(joined)
    }

    // MARK: Internal

    let title: String
    let body: String
    let sender: String
    /// `title` + `subtitle` + `body` + `sender`, newline-joined. Subtitles have no
    /// dedicated field of their own in v1.0 — they are only ever reachable through `any`.
    let any: String

    /// `Rule.MatchField.title/body/sender/any` → the matching folded field.
    ///
    /// `.app` has no text field: rules with `match_field == .app` always compile to
    /// `CompiledRules.Matcher.bundleID`, and `RulesEngine.matches(_:input:bundleID:)`
    /// branches on the matcher, not on `entry.field`, for that case — so this branch is
    /// unreachable in practice. It returns the empty string rather than `any` precisely so
    /// a future caller that *did* reach it would see "matches nothing", not "matches
    /// everything".
    func field(_ field: Rule.MatchField) -> String {
        switch field {
        case .any: any
        case .title: title
        case .body: body
        case .sender: sender
        case .app: ""
        }
    }

    // MARK: Private

    private static func fold(_ value: String?) -> String {
        String((value ?? "").matchKey.prefix(RuleLimits.maxInputLength))
    }
}
