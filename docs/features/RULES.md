# Rules

Last Updated: 2026-08-18

Rules are Backglance's triage layer: highlight a keyword in a colour, pin a VIP sender to the top of the timeline, and push a noisy app into a collapsed group at the bottom. **Rules are visual triage only — in v1.0 they do not affect system delivery in any way.** Muting Slack in Backglance does not stop Slack's banner, sound, or Dock badge; it changes only how Backglance renders Slack's notifications after macOS has already delivered them. This document covers the rule kinds, matching semantics, evaluation order and conflict resolution, the `RulesEngine` API, when triage is computed and cached, the settings UI, the digest and search interactions, the edge cases, and the tests.

> ⚠️ **Warning:** Rules change **Backglance's presentation only**. They never touch macOS notification delivery. A muted app still shows its banner, plays its sound, and updates its Dock badge exactly as before. To actually stop delivery, use System Settings ▸ Notifications — Backglance has a one-click deep link to the app's page there, documented in [ACTIONS.md](./ACTIONS.md#open-in-system-settings--notifications).

## Table of Contents

- [Does muting stop the banner? No.](#does-muting-stop-the-banner-no)
- [Feature Overview](#feature-overview)
- [Architecture](#architecture)
- [Archive Tables Involved](#archive-tables-involved)
- [Rule Kinds](#rule-kinds)
- [Matching Semantics](#matching-semantics)
- [Evaluation Order and Conflict Resolution](#evaluation-order-and-conflict-resolution)
- [Business Logic: RulesEngine](#business-logic-rulesengine)
- [When Rules Are Evaluated](#when-rules-are-evaluated)
- [Triage in the Timeline](#triage-in-the-timeline)
- [UI Components](#ui-components)
- [Digest, Search and Defaults](#digest-search-and-defaults)
- [Edge Cases and Error Handling](#edge-cases-and-error-handling)
- [Testing](#testing)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Does muting stop the banner? No.

This question comes up often enough that it gets its own section.

| Question | Answer in v1.0 |
|---|---|
| Does a `mute` rule stop the banner, the sound, or the Dock badge? | **No.** macOS has already delivered all three before Backglance ever sees the record. |
| Does it stop the notification being archived? | **No.** Muted notifications are archived, searchable, exportable, counted in analytics. |
| What does it actually do? | Collapses the app into a "Muted (n)" group at the bottom of each day in the timeline, and removes it from the unread badge. |
| How do I actually stop delivery? | System Settings ▸ Notifications ▸ ‹App›. |

Backglance reads a system store *after* delivery. It has no notification-service extension, no `UNNotificationFilter`, no private entitlement, and it is deliberately not asking for one. The honest framing: Backglance is a *record* of your notifications, not a *gate* in front of them.

Every place that offers a mute also offers the System Settings deep link. The context menu item "Notification Settings for ‹App›…" opens `x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=<bundle id>` with per-version fallbacks; the URL table and its failure handling live in [ACTIONS.md](./ACTIONS.md#open-in-system-settings--notifications). The rules pane repeats that link next to every `mute` rule.

> ℹ️ **Info:** If you want an app to leave *no trace at all*, that is exclusion, not muting — a different feature with a different guarantee, documented in [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md). Excluded apps are never written to the archive; muted apps are stored in full and merely de-prioritized.

## Feature Overview

| Capability | v1.0 | Where it shows |
|---|---|---|
| Highlight a keyword or phrase in a colour | ✅ | Row background tint in the timeline and digest |
| Pin a VIP sender or app to the top | ✅ | Top of the day group; first in the digest; `is:vip` in search |
| Mute an app or keyword | ✅ | Collapsed "Muted (n)" group; excluded from the unread badge |
| Scope a rule to a single app | ✅ | `rules.app_bundle_id` |
| Whole-word vs substring matching, with a live preview over the last 50 notifications | ✅ | Quoted pattern = whole word; preview in the rule editor sheet |
| Import / export rules JSON (`backglance.rules` v1) | ✅ | Settings ▸ Rules ▸ ••• |
| Regular-expression rules (`kind = 'regex'`) | ❌ planned for v1.x | Compiles, then reports "not available in 1.0" |
| Suggested "noisy apps" prompt after 7 days | ❌ planned for v1.x | Needs the counters in [ANALYTICS.md](./ANALYTICS.md) |

## Architecture

```
  archive: rules (kind, pattern, match_field, app_bundle_id, color, priority, …)
           apps  (bundle_id, is_muted)
                                  │ GRDB ValueObservation (rules OR apps write)
                                  ▼
 ┌────────────────────────────────────────────────────────────────────────────┐
 │ RulesEngine                          Packages/BackglanceCore/…/Rules/       │
 │  compile([Rule]) ──▶ (CompiledRules, [RuleCompileError])                    │
 │    trim · reject empty / >256 chars · parse colour · pre-fold to matchKeys  │
 │    sort priority DESC, id ASC · invalid rules SKIPPED + reported, not thrown │
 │  Snapshot { version, compiled, problems, bundleIDs, mutedBundleIDs, cache } │
 │    ▲ replaced wholesale on every change; the triage cache dies with it      │
 └──────────────┬─────────────────────────────────────────────────────────────┘
                │ evaluate(notification) -> Triage   (pure, synchronous, cached)
   ┌────────────┼───────────────┬──────────────────┐
   ▼            ▼               ▼                  ▼
┌─────────┐ ┌─────────┐ ┌──────────────┐ ┌────────────────┐
│Timeline │ │ Digest  │ │ HybridSearch │ │ RulesSettings  │
│pin/tint/│ │VIP first│ │ is:vip       │ │ list + editor  │
│collapse │ │muted end│ │ post-filter  │ │ live preview   │
└─────────┘ └─────────┘ └──────────────┘ └────────────────┘

  ✗ No arrow points at macOS. Nothing here reaches delivery. That is the whole point.
```

## Archive Tables Involved

The canonical DDL lives in [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md); this is the `rules` table verbatim.

```sql
CREATE TABLE rules (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,                          -- 'highlight' | 'vip' | 'mute' | 'regex'
  pattern TEXT NOT NULL,                       -- keyword, sender, bundle id, or regex source
  match_field TEXT NOT NULL DEFAULT 'any',     -- 'any' | 'title' | 'body' | 'sender' | 'app'
  app_bundle_id TEXT,                          -- scope to one app (nullable)
  color TEXT,                                  -- highlight color token e.g. 'amber'
  priority INTEGER NOT NULL DEFAULT 0,
  is_enabled INTEGER NOT NULL DEFAULT 1,
  created_at REAL NOT NULL
);
```

| Table / column | Role |
|---|---|
| `rules.*` | The rule set, read on every change through one `ValueObservation`. |
| `apps.is_muted` | Per-app mute from the row context menu. Behaves exactly like a `mute` rule scoped to that app and is folded into `Triage.muted`, so there is one code path. |
| `apps.bundle_id` | Resolves `notifications.app_id` to the bundle id a rule is scoped to. |
| `notifications.title`, `subtitle`, `body`, `sender` | The match fields. `match_field = 'any'` searches all four. |
| `notifications.is_pinned` | The *manual* pin, independent of VIP pinning, which is computed and never stored ([ACTIONS.md](./ACTIONS.md)). |

There is no `triage` column anywhere, and there will not be one. Triage is derived state.

## Rule Kinds

| Kind | Pattern means | Effect | Notes |
|---|---|---|---|
| `highlight` | keyword or phrase | Row background tinted with `color` | `color` required; tokens `amber`, `red`, `green`, `blue`, `purple` |
| `vip` | sender name, keyword, or bundle id (`match_field = 'app'`) | Pinned to the top of its day, first in the digest, matched by `is:vip` | Beats mute unconditionally |
| `mute` | keyword, or bundle id (`match_field = 'app'`) | Collapsed into the trailing "Muted (n)" group, excluded from the unread badge | **Never** excluded from the archive, search, export, or analytics |
| `regex` | ICU regular expression, with full `match_field` support | Same as `highlight`; uses `color` | 🧪 Planned for v1.x |

> ℹ️ **Status:** `kind = 'regex'` is **planned for v1.x**. The column, the model case, the compile path, and the safety bounds are specified now so a rules file imported from a future version fails *visibly* rather than silently doing nothing. In v1.0 a `regex` rule produces a `RuleCompileError` and shows a warning badge in the list.

`HighlightColor` is a `String`-backed enum over those five tokens. Each one resolves to a system colour, not an asset-catalog entry: `amber` → `.orange`, `red` → `.red`, `green` → `.green`, `blue` → `.blue`, `purple` → `.purple`, in the `swiftUIColor` property of `Packages/BackglanceUI/Sources/BackglanceUI/Timeline/HighlightColor+SwiftUI.swift`. `BackglanceUI` ships no resource bundle — see the dependency-direction note in `AppIconView.swift` for why the package stays free of one — so there is no catalog for a `bundle: .module` lookup to resolve against, and a system colour already carries the light, dark and increased-contrast variants a hand-rolled catalog would otherwise have to reproduce one entry at a time. The contrast of `Color.primary` over each tint is owed a unit test ([ACCESSIBILITY.md](../reference/ACCESSIBILITY.md)); that test is not written yet, and the swap to system colours does not excuse it.

## Matching Semantics

**Case- and diacritic-insensitive, locale-neutral.** Every keyword comparison runs on `matchKey`, the folding helper defined in [INTERNATIONALIZATION.md](../reference/INTERNATIONALIZATION.md):

```swift
extension String {
    var matchKey: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased() // lowercased() without a locale is locale-independent
    }
}
```

The `locale: nil` is not decoration. On a Turkish-locale Mac, `"INVOICE".lowercased(with: Locale(identifier: "tr"))` is `"ınvoıce"` with dotless `ı`, so a rule for `invoice` would silently stop matching for exactly the users most likely to set that locale — including the developer. The same class of bug exists in Azerbaijani and Lithuanian, so the fix is locale *neutrality*, not a Turkish special case. German `ä`/`ö`/`ü` fold to `a`/`o`/`u` and `ß` folds to `ss`, so a rule for `strasse` matches `Straße` and `bestatigung` matches `Bestätigung`.

**Whole word vs substring.** The editor has a "Match whole words only" checkbox. The `rules` DDL has no boolean for it, so the flag is encoded in the stored pattern with the convention the search `QueryParser` already uses: a pattern wrapped in double quotes is a whole-word / phrase match, a bare pattern is a substring match. The editor adds and strips the quotes; users never have to know.

| Stored `pattern` | Mode | Matches | Does not match |
|---|---|---|---|
| `invoice` | substring | "Invoice #1", "invoices", "reinvoiced" | — |
| `"invoice"` | whole word | "Invoice #1", "an invoice arrived" | "invoices", "reinvoiced" |
| `"deploy failed"` | phrase | "deploy failed on main" | "deploy has failed" |
| `strasse` | either | "Hauptstraße 5" | — |

Whole-word bounds are computed on the folded key: the needle must be preceded and followed by a non-word character or a string end, where a word character is `Character.isLetter || Character.isNumber`. That definition is Unicode-aware, so `İstanbul` and `Ünal` bound correctly.

**Match field and app scope.** `match_field` selects what the pattern is compared against: `title`, `body`, `sender`, `app` (the bundle id, compared with plain `lowercased()` — bundle ids are ASCII, but a locale-sensitive lowercase would still be a latent bug), or `any`, which is title + subtitle + body + sender joined with newlines. Subtitles have no dedicated field in v1.0; they are searched under `any`. `app_bundle_id` then restricts the rule to one app regardless of `match_field`: a rule scoped to `com.tinyspeck.slackmacgap` with pattern `deploy` never tints a Mail notification, even one that says "deploy".

## Evaluation Order and Conflict Resolution

Every matching rule contributes; there is no first-match-wins short circuit.

1. **Sort** at compile time: `priority DESC`, then `id ASC`. The `id` tie-break makes ordering deterministic, which matters for the tests and for the editor's "which colour won?" answer.
2. **Skip** rules whose app scope does not match the notification's bundle id.
3. **Accumulate.** `highlight` (and `regex` in v1.x): the **highest-priority matching rule wins** the colour. Highlight is **additive** — a highlighted row can also be pinned, or muted. `vip` sets `pinned = true`; multiple VIP matches are not "more pinned". `mute` sets `muted = true`.
4. **Resolve: VIP beats mute, always.** After the loop, `if pinned { muted = false }`. Priority does not override this — a `mute` rule with priority 100 still loses to a `vip` rule with priority 0. The reasoning is asymmetric risk: a wrongly-muted VIP notification is a missed message, a wrongly-shown muted notification is mild noise.
5. **Per-app mute** (`apps.is_muted`) is applied last, with the same VIP exemption.
6. `matchedRuleIDs` records every rule that matched, in evaluation order, for the editor's "why did this match?" popover and for the `is:vip` search filter.

Worked example. Notification: Slack, sender "Ayşe", title "URGENT: deploy failed on main".

| # | Rule | Kind | Pattern | Field | Scope | Prio | Match? | Contribution |
|---|---|---|---|---|---|---|---|---|
| 1 | Noisy Slack | `mute` | `com.tinyspeck.slackmacgap` | `app` | — | 10 | ✅ | `muted = true` |
| 2 | Urgent | `highlight` | `urgent` | `any` | — | 0 | ✅ | colour `red` (best so far) |
| 3 | Deploys | `highlight` | `"deploy failed"` | `title` | Slack | 5 | ✅ | colour `amber` (5 > 0, wins) |
| 4 | Manager | `vip` | `ayse` | `sender` | — | 0 | ✅ (`Ayşe`.matchKey == `ayse`) | `pinned = true` |
| 5 | Invoices | `highlight` | `invoice` | `body` | — | 20 | ❌ | — |
| 6 | Mail only | `mute` | `newsletter` | `any` | `com.apple.mail` | 0 | ❌ (scope) | — |

Result: `Triage(highlight: .amber, pinned: true, muted: false, matchedRuleIDs: [1, 3, 2, 4])` — rule 3 beats rule 2 on priority, rule 4's VIP cancels rule 1's mute, and `matchedRuleIDs` is in compiled order.

## Business Logic: RulesEngine

`RulesEngine` lives in `Packages/BackglanceCore/Sources/BackglanceCore/Rules/`: two pure static functions — `compile` and `evaluate` — plus an instance that owns the cached snapshot and the archive writes. The static functions never throw and never touch the archive, which is what makes the whole feature testable as a table.

```swift
// Rules/Triage.swift — the result of evaluating the rule set against one notification.
public struct Triage: Equatable, Sendable {
    public var highlight: HighlightColor?
    public var pinned = false
    public var muted = false
    public var matchedRuleIDs: [Int64] = []
    public init() {}
    public static let none = Triage()              // fast path for an empty rule set
}

/// Why one rule could not be compiled. Shown inline in the editor and as a warning
/// badge in the list; never thrown, never fatal.
public struct RuleCompileError: Error, Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case emptyPattern, patternTooLong, invalidRegex, unknownColorToken, notAvailableInThisVersion
    }
    public let ruleID: Int64, kind: Kind, message: String
    public var id: Int64 { ruleID }
    public init(ruleID: Int64, message: String, kind: Kind = .invalidRegex) {
        self.ruleID = ruleID; self.message = message; self.kind = kind
    }
}
```

`CompiledRules` is a `@unchecked Sendable` struct — every stored value is immutable after `init`, but `Regex` carries no conformance we can rely on — wrapping `entries: [Entry]`, `isEmpty`, and `static let empty`. Each `Entry` carries `id`, `priority`, `kind`, `field`, `scope` (lowercased bundle id, `nil` = all apps), `color`, and a `Matcher`:

| `Matcher` case | Payload | Comparison |
|---|---|---|
| `.substring(String)` | folded needle | plain containment |
| `.word(String)` | folded needle | word-bounded containment |
| `.bundleID(String)` | lowercased bundle id | exact equality |
| `.regex(RegexRuleEvaluator)` | compiled `Regex` | v1.x; bounds in [SECURITY.md](../security/SECURITY.md) |

`RuleLimits` holds the constants the engine and the editor share: `maxPatternLength = 256`, `maxInputLength = 4_096`, `budget = .milliseconds(50)`, `budgetViolationsBeforeDisable = 3`, `regexRulesEnabled = false` (flips to `true` in v1.x) and `triageCacheLimit = 5_000`. The first four match [SECURITY.md](../security/SECURITY.md) exactly.

`compile(_:)` folds every pattern once, up front, and reports what it had to skip — it never throws, so one bad pattern can never break triage for everything else.

```swift
// Rules/RulesEngine+Compile.swift
extension RulesEngine {
    public static func compile(_ rules: [Rule]) -> (CompiledRules, [RuleCompileError]) {
        var entries: [CompiledRules.Entry] = []
        var problems: [RuleCompileError] = []
        for rule in rules where rule.isEnabled {
            let id = rule.id ?? Rule.draftID       // unsaved editor draft evaluates as -1
            let raw = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                problems.append(.init(ruleID: id, message: "Pattern is empty.", kind: .emptyPattern)); continue
            }
            guard raw.count <= RuleLimits.maxPatternLength else {
                problems.append(.init(ruleID: id, message: "Pattern is over 256 characters.",
                                      kind: .patternTooLong)); continue
            }
            var color: HighlightColor?             // mandatory for the kinds that paint
            if rule.kind == .highlight || rule.kind == .regex {
                guard let c = rule.color.flatMap(HighlightColor.init(rawValue:)) else {
                    problems.append(.init(ruleID: id, message: "Unknown highlight colour.",
                                          kind: .unknownColorToken)); continue
                }
                color = c
            }
            let matcher: CompiledRules.Matcher
            switch rule.kind {
            case .regex:
                guard RuleLimits.regexRulesEnabled else {
                    problems.append(.init(ruleID: id, message: "Regex rules arrive in a later version.",
                                          kind: .notAvailableInThisVersion)); continue
                }
                do { matcher = .regex(try RegexRuleEvaluator(pattern: raw)) }
                catch {                            // skipped and reported, never thrown
                    problems.append(.init(ruleID: id, message: "Invalid pattern: \(error)",
                                          kind: .invalidRegex)); continue
                }
            case .highlight, .vip, .mute:
                if rule.matchField == .app { matcher = .bundleID(raw.lowercased()) }
                else if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
                    matcher = .word(String(raw.dropFirst().dropLast()).matchKey)   // quoted = whole word
                } else { matcher = .substring(raw.matchKey) }
            }
            entries.append(.init(id: id, priority: rule.priority, kind: rule.kind,
                                 field: rule.matchField, scope: rule.appBundleId?.lowercased(),
                                 color: color, matcher: matcher))
        }
        entries.sort { $0.priority == $1.priority ? $0.id < $1.id : $0.priority > $1.priority }
        return (CompiledRules(entries: entries), problems)
    }
}
```

`evaluate` folds the notification's four fields once into a `MatchInput` (`title`, `body`, `sender`, and `any` = title + subtitle + body + sender joined with newlines, all `matchKey`-folded), then walks the compiled entries in order. It is pure, synchronous, and never throws.

```swift
// Rules/RulesEngine+Evaluate.swift
extension RulesEngine {
    /// Hot path. `bundleID` is optional because `ArchivedNotification` stores `app_id`, not the
    /// bundle id; when it is nil, app-scoped and `match_field == .app` rules are skipped
    /// (fail-closed). Timeline, digest and settings preview all pass the resolved id.
    public static func evaluate(_ n: ArchivedNotification, compiled: CompiledRules,
                                bundleID: String? = nil) -> Triage {
        guard !compiled.isEmpty else { return .none }      // success fast path: no rules, no work
        let input = MatchInput(n)
        let app = bundleID?.lowercased()
        var triage = Triage.none
        var bestHighlight = Int.min
        for entry in compiled.entries {
            if let scope = entry.scope {
                guard let app, scope == app else { continue }   // scoped to a different app
            }
            guard matches(entry, input: input, bundleID: app) else { continue }
            triage.matchedRuleIDs.append(entry.id)
            switch entry.kind {
            case .highlight, .regex:
                if let color = entry.color, entry.priority > bestHighlight {
                    triage.highlight = color; bestHighlight = entry.priority
                }
            case .vip: triage.pinned = true
            case .mute: triage.muted = true
            }
        }
        if triage.pinned { triage.muted = false }          // VIP beats mute, unconditionally
        return triage
    }

    /// Convenience for search and the digest, which already hold `[Rule]`. Compile
    /// problems are dropped here; call `compile(_:)` directly to surface them.
    public static func evaluate(_ n: ArchivedNotification, rules: [Rule],
                                bundleID: String? = nil) -> Triage {
        let (compiled, _) = compile(rules)
        return evaluate(n, compiled: compiled, bundleID: bundleID)
    }

    private static func matches(_ e: CompiledRules.Entry, input: MatchInput, bundleID: String?) -> Bool {
        switch e.matcher {
        case .bundleID(let wanted):  return bundleID == wanted   // nil id decides nothing
        case .substring(let needle): return input.field(e.field).contains(needle)
        case .word(let needle):      return containsWord(needle, in: input.field(e.field))
        case .regex(let evaluator):                        // v1.x; runs against the folded text
            let (matched, elapsed) = evaluator.evaluate(input.field(e.field))
            if elapsed > RuleLimits.budget { BudgetLedger.shared.note(ruleID: e.id) }
            return matched
        }
    }

    /// Whole-word containment over folded keys: bounded by a non-word character or a string end.
    static func containsWord(_ needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty, !haystack.isEmpty else { return false }
        var start = haystack.startIndex
        while let found = haystack.range(of: needle, options: .literal, range: start..<haystack.endIndex) {
            let leftOK = found.lowerBound == haystack.startIndex
                || !haystack[haystack.index(before: found.lowerBound)].isWordCharacter
            let rightOK = found.upperBound == haystack.endIndex
                || !haystack[found.upperBound].isWordCharacter
            if leftOK && rightOK { return true }
            guard found.lowerBound < haystack.endIndex else { return false }
            start = haystack.index(after: found.lowerBound)
        }
        return false
    }
}

extension Character { var isWordCharacter: Bool { isLetter || isNumber } }
```

The instance holds an immutable `Snapshot` — `version`, `compiled`, `problems`, an `app_id → bundle_id` map, the set of `apps.is_muted` bundle ids, and the triage cache — behind an `NSLock`, so the timeline can call `evaluate` synchronously from the main actor while a `ValueObservation` over `rules` and `apps` replaces the whole snapshot from a background task. `install(rules:apps:)` recompiles, bumps `version`, installs the new snapshot with an **empty** cache, and logs each problem once by rule id. If the observation itself fails — panic wipe, disk error — the last good snapshot stays installed and the failure is logged, so triage keeps working with slightly stale rules rather than reverting to none.

```swift
// Rules/RulesEngine.swift, excerpt
public final class RulesEngine: @unchecked Sendable {
    /// Cached triage for one row; callable from any isolation.
    public func evaluate(_ n: ArchivedNotification) -> Triage {
        lock.lock(); defer { lock.unlock() }
        if let id = n.id, let cached = snapshot.triage[id] { return cached }
        let bundleID = snapshot.bundleIDs[n.appId]
        var triage = Self.evaluate(n, compiled: snapshot.compiled, bundleID: bundleID)
        // Per-app mute is a mute rule by another name — same VIP exemption.
        if let bundleID, snapshot.mutedBundleIDs.contains(bundleID.lowercased()), !triage.pinned {
            triage.muted = true
        }
        if snapshot.triage.count >= RuleLimits.triageCacheLimit {
            snapshot.triage.removeAll(keepingCapacity: true)         // bounded, never unbounded growth
        }
        if let id = n.id { snapshot.triage[id] = triage }
        return triage
    }
}
```

`setAppMuted(bundleID:muted:) async throws` is the one path that toggles `apps.is_muted` — used by the row context menu ([ACTIONS.md](./ACTIONS.md)) and by the settings pane. It runs a single `updateAll` on `apps`, throws `RulesError.unknownApp` when the update touched no row (error path), and on success does nothing else: the observation reinstalls the snapshot and the triage cache dies with it.

Errors from the instance side are one `RulesError` enum conforming to `LocalizedError`: `.unknownApp(String)` ("No archived app with bundle id …"), `.invalidEntry(index:reason:)`, `.importFormatMismatch(String)` and `.importVersionUnsupported(Int)`. A `problems` accessor returns the snapshot's `[RuleCompileError]` for the warning badges in the settings list. A `regex` rule that blows its 50 ms budget three times is auto-disabled by `BudgetLedger`, matching the bound in [SECURITY.md](../security/SECURITY.md): it counts violations per rule id and, on the third, writes `is_enabled = 0` in a detached task, logging both the success ("rule 12 auto-disabled: over 50 ms three times") and a failure to persist — in which case the in-memory count survives and the disable is retried on the next violation.

## When Rules Are Evaluated

**At read time, in `TimelineStore.regroup()`, cached per session.** Capture writes rows; it does not write triage ([CAPTURE.md](./CAPTURE.md)). The cache key is effectively `(notification id, snapshot version)`: entries live in the snapshot, and every rules or apps write installs a new snapshot with an empty cache. A rule edit therefore re-triages all of history on the next render, with no migration and no background job.

| Option | Cost | Verdict |
|---|---|---|
| **Read time, cached per session** ✅ | ≤ 1,000 rows × N rules per regroup; the cache makes scrolling free | Chosen. Rules change *retroactively*: editing "highlight invoice" must tint the invoice from March, not only tomorrow's. |
| Capture time, stored `triage` columns | One evaluation per notification, ever | ❌ **Rejected.** Every rule edit would need a full-table rewrite of 100k rows, and a rules file imported from another Mac would leave the archive stale until that job finished. It also puts derived state in a table we want to keep as a faithful record of what arrived. |
| Read time, no cache | Re-evaluates on every scroll tick | ❌ Rejected: wasteful for no benefit; the snapshot already gives correct invalidation. |

The trade-off we accept: the first render after a rules change costs one evaluation per visible row — measured under a frame, so no spinner is needed.

## Triage in the Timeline

`Triage` maps to presentation in exactly three places, all in [TIMELINE.md](./TIMELINE.md):

| Field | Presentation |
|---|---|
| `highlight` | `RoundedRectangle(…).fill(color.swiftUIColor.opacity(0.12))` behind the row; under Increase Contrast the tint becomes a border |
| `pinned` | Floats to the top of its day group with the manual `is_pinned` rows (manual first, then VIP, then `delivered_at DESC`), with a pin glyph |
| `muted` | Moves into the trailing "Muted (n)" group for its day, collapsed by default, and excluded from the unread badge |
| `matchedRuleIDs` | Feeds the row inspector's "Matched: Urgent, Deploys" line and the `is:vip` search filter |

Nothing else reads `Triage`, and there is no code path from it to `UNUserNotificationCenter`, to the system store, or to any Apple API that affects delivery.

**How `muted` reaches the badge.** Two different things produce `Triage.muted`, and only one of them is a column. `apps.is_muted` is written by `RulesEngine.setAppMuted(bundleID:muted:)` — the row context menu's "Mute ‹App› in Timeline". A `mute` **rule** is not written anywhere; it is evaluated in Swift, per row, at read time. `Archive.unreadBadgeCount(_:since:triage:)` therefore has two paths, chosen by `TriageEvaluating.hasMuteRules`:

| Rules present | How the badge is counted | Exact? |
|---|---|---|
| No enabled `mute` rule — the default install, since Backglance ships with no rules | Index-only SQL `COUNT`, `… AND a.is_muted = 0`, capped by `LIMIT unreadBadgeCap` | Yes, to the cap |
| At least one enabled `mute` rule | Up to `unreadBadgeScanCap` (3 × the cap) candidate rows are fetched newest-first and evaluated through `triage`, counting survivors until the cap is reached | Yes, unless more than `unreadBadgeScanCap` candidates exist |

The second path is bounded on purpose. The badge is recomputed inside the timeline's `ValueObservation`, so it runs on every write; an unbounded scan there would make every captured notification pay for the rule set. Past `unreadBadgeScanCap` unread candidates the count can under-report — at which point the badge is already rendering "99+", a number that is approximate by design.

Until BACKGLANCE-240 there was only the SQL path, so a `mute` rule collapsed its rows into the Muted group and went on counting them in the badge — the Rule Kinds table above promises both halves, and now both happen.

## UI Components

| Component | File | Responsibility |
|---|---|---|
| `RulesSettingsView` | `Packages/BackglanceUI/…/Settings/RulesSettingsView.swift` | `Table` of rules: enable toggle per row, orange warning badge with the compile message in its tooltip, priority column, Add / Edit / Delete, and a ••• menu with Export Rules…, Import Rules…, Open Notification Settings… |
| `RuleEditorSheet` | `…/Settings/RuleEditorSheet.swift` | Kind, pattern, match field, app scope, colour, whole-word toggle, priority, inline error, live preview |
| `RulesSettingsModel` | `…/Settings/RulesSettingsModel.swift` | `@Observable` view model; owns the draft and the debounced preview task |

The pane opens with one sentence under the title — "Rules change how Backglance shows notifications. They do not change what macOS delivers." — and any `mute` rule scoped to an app gets a "Notification Settings for ‹App›…" button next to it, the same deep link as the row context menu ([ACTIONS.md](./ACTIONS.md#open-in-system-settings--notifications)). The live preview is what makes rules trustworthy: before saving, the user sees which of their **last 50 archived notifications** the draft would have matched, debounced at 200 ms over a one-rule compiled set, so a mistyped pattern costs nothing.

```swift
// Settings/RulesSettingsModel.swift, excerpt
extension RulesSettingsModel {
    /// Recompiles the draft and re-runs it over the newest 50 notifications.
    /// Errors show inline under the pattern field; they never abort editing.
    func refreshPreview(for draft: Rule) async {
        previewTask?.cancel()
        previewTask = Task { [archive] in
            try? await Task.sleep(for: .milliseconds(200))       // debounce keystrokes
            guard !Task.isCancelled else { return }
            let (compiled, problems) = RulesEngine.compile([draft])
            await MainActor.run { self.compileError = problems.first }
            guard problems.isEmpty else {
                await MainActor.run { self.preview = [] }        // error path: nothing to preview
                return
            }
            do {
                let sample = try await archive.reader.read { db in try Self.recentFifty(db) }
                let hits = sample.filter { row, bundleID in      // (notification, bundle id) pairs
                    !RulesEngine.evaluate(row, compiled: compiled, bundleID: bundleID)
                        .matchedRuleIDs.isEmpty
                }
                await MainActor.run { self.preview = hits.map(\.0); self.previewError = nil }
            } catch {
                await MainActor.run { self.previewError = error.localizedDescription }
            }
        }
    }
}
```

Saving trims the pattern and refuses an empty one before the archive is touched, setting `compileError` to an `.emptyPattern` problem reading "Enter something to match."

**Import and export.** Rules export to `backglance-rules.json` with format id `backglance.rules`, version `1`, through a `RulesDocument` (`format`, `version`, `rules[]`) whose entries carry `kind`, `pattern`, `matchField`, `appBundleID`, `color`, `priority` and `isEnabled` — no ids, since those are archive-local. The same envelope is accepted inside a `backglance.searches` file so rules and saved searches can travel together ([SAVED_SEARCHES.md](./SAVED_SEARCHES.md)).

```json
{
  "format": "backglance.rules",
  "version": 1,
  "rules": [
    { "kind": "vip", "pattern": "\"Ayse Yilmaz\"", "matchField": "sender",
      "appBundleID": null, "color": null, "priority": 10, "isEnabled": true },
    { "kind": "mute", "pattern": "com.tinyspeck.slackmacgap", "matchField": "app",
      "appBundleID": null, "color": null, "priority": 0, "isEnabled": true }]
}
```

Import is all-or-nothing and runs in one transaction. `importRules(from:)` decodes the envelope, throws `RulesError.importFormatMismatch` when `format` is not `backglance.rules` and `RulesError.importVersionUnsupported` when `version` is newer than 1, then validates **every** entry before writing anything: patterns are trimmed and rejected when empty (`.invalidEntry(index:reason:)`) or over 256 characters, and `regex` entries are compiled through `RegexRuleEvaluator` even though v1.0 will not run them, so a bad pattern is caught at import rather than lying dormant. Only then does it open the writer, skip duplicates by `(kind, pattern, matchField)`, insert the rest, and return `(imported:skipped:)`.

Import reports "7 imported, 2 skipped" in a sheet; a failure mid-validation writes nothing and names the offending entry by position.

## Digest, Search and Defaults

**Digest.** The digest sorts by triage before capping ([MISSED_DIGEST.md](./MISSED_DIGEST.md)): VIP-pinned and highlighted notifications rank first, ordinary ones next, and notifications from muted apps collapse into one trailing line ("3 more from muted apps") that expands into the timeline filtered to that away session. Muted notifications are still *in* the digest — they are the answer to "what did I miss", and hiding them would make the digest lie.

**Search.** One rules-aware operator: `is:vip`. Because there is no stored VIP column, it is a **post-filter** — `HybridSearch` runs the query normally, then re-evaluates the enabled `vip` rules over the hit set and keeps the notifications with a non-empty `matchedRuleIDs`. Cost is bounded by the hit count, not by archive size. Everything else in search ignores rules: muted apps are fully searchable, which is the point of "never excluded from the archive" ([SEARCH.md](./SEARCH.md)).

**Defaults.** Backglance ships with **no rules at all**. An empty set takes the `compiled.isEmpty` fast path, so triage costs nothing until the user opts in. There is no starter pack and no rule created behind the user's back — an archive that quietly re-ranks itself on first launch would be the wrong first impression.

> ℹ️ **Status:** A suggested **"noisy apps" prompt after 7 days** — "Slack sent 812 notifications this week. Mute it in Backglance, or open System Settings?" — is **planned for v1.x**. It needs the per-app counters from [ANALYTICS.md](./ANALYTICS.md) and reuses that document's thresholds (≥ 50 notifications in 7 days, at most one suggestion per week, no repeat for the same bundle id within 4 weeks), with the same one-click System Settings link. It is not in v1.0 because a suggestion engine with no data behind it is just a nag.

## Edge Cases and Error Handling

| Case | Behavior |
|---|---|
| Empty or whitespace-only pattern | Rejected in the editor before saving (Save disabled, inline "Enter something to match."). A pattern that reaches `compile` empty anyway — from a hand-edited import — is skipped with `.emptyPattern`. |
| Pattern longer than 256 characters | Rejected at compile and at import (`.patternTooLong`), matching the bound in [SECURITY.md](../security/SECURITY.md). |
| Catastrophic regex backtracking, e.g. `(a+)+$` | Work is bounded, not time: pattern ≤ 256 chars, input truncated to 4,096 chars per field, `firstMatch(in:)` only, a 50 ms budget per evaluation. Three violations auto-disable the rule (`is_enabled = 0`) and the list shows "Disabled: pattern too slow" with a fix-it link. v1.x only, since `regex` is v1.x. |
| Rule matching the `[code redacted]` placeholder | The placeholder is ordinary body text, so a rule for `code` or `redacted` matches every redacted notification. Deliberate: special-casing it would make matching semantics depend on redaction state, which is harder to explain than the surprise. The live preview shows it on the first keystroke and the editor suggests scoping to `title`. The original digits are gone and can never be matched by anything ([PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md)). |
| 500 rules × 100k notifications | The timeline never evaluates more than the ~1,000 loaded rows, and the snapshot cache evaluates each row once per rules change: 1,000 × 500 folded probes ≈ 12 ms on an M-series Mac, under one frame. Full-archive passes (digest reconstruction, an unbounded `is:vip`) are budgeted at **< 2.5 s for 100k × 50 rules** off the main thread ([PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md)). Patterns fold once at compile, fields once per evaluation, so rule count multiplies comparisons, not foldings. |
| Rule referencing an uninstalled app | Kept and still evaluated. Scope compares against `apps.bundle_id` in the archive, not the file system, so a rule keeps working over the history of an app you deleted. The list shows the bundle id with a generic icon; there is no "broken rule" state. When the bundle id cannot be resolved at all, app-scoped and `match_field = 'app'` rules are skipped rather than assumed to match — fail-closed: a mute that cannot be proven hides nothing. |
| Two highlight rules match with equal priority | Lower `id` wins — the older rule. Deterministic and stable across restarts. |
| A `vip` and a `mute` rule both match | VIP wins; `muted` is forced back to `false` after the loop, regardless of priority. A muted app's unread notification is excluded from the badge but stays `is_read = 0` in the archive and is still counted in analytics. |
| Rules changed while the timeline is scrolled | The observation installs a new snapshot, the cache is dropped, `regroup()` re-runs. Scroll position is preserved; rows may re-order. If the observation's read fails instead, the last good snapshot stays installed and the failure is logged — stale rules beat no rules. |
| Import file from a newer Backglance, or with an unknown `kind` | `RulesError.importVersionUnsupported`, or a `JSONDecoder` failure on `Rule.Kind`. Nothing is written either way. |

Compile problems are surfaced twice: **inline** in the editor under the pattern field while the user types, and as an **orange warning badge** on the row in the rules list with the message in the tooltip. A rule with a problem is skipped by the engine but never deleted or silently rewritten — the user's data stays theirs to fix.

## Testing

`RulesEngineTests` lives in `Tests/BackglanceCoreTests/Unit/`; the settings model is covered in `BackglanceUITests`. Conventions follow [TESTING.md](../testing/TESTING.md).

| Suite | Target | Covers |
|---|---|---|
| `RuleMatcherTests` | `BackglanceCoreTests` | Table-driven folding and word-boundary cases, including Turkish `İ`/`ı` and German `ß`/`ä` |
| `RuleConflictTests` | `BackglanceCoreTests` | VIP beats mute, highlight priority, `id` tie-break, app scope, the worked example above |
| `RuleCompileTests` | `BackglanceCoreTests` | Empty pattern, over-length pattern, unknown colour token, `regex` reported unavailable, invalid regex skipped-not-thrown |
| `RulesImportExportTests` | `BackglanceCoreTests` | Round-trip, duplicate skipping, format/version mismatch, all-or-nothing rollback |
| `RulesPerformanceTests` | `BackglanceCoreTests/Performance` | 100k notifications × 50 rules over `archive-100k.sqlite`, nightly on `macos-26` |
| `RulesSettingsModelTests` | `BackglanceUITests` | Preview debounce, preview over 50 rows, inline error surfaced, save blocked on empty pattern |

```swift
// Tests/BackglanceCoreTests/Unit/RuleMatcherTests.swift
import XCTest
@testable import BackglanceCore

final class RuleMatcherTests: XCTestCase {
    private struct Case { let name: String, pattern: String, text: String, expected: Bool }

    /// One table, one loop. A new locale bug report is one added line.
    func test_whenPatternsFolded_thenMatchingIsLocaleNeutral() {
        let cases: [Case] = [
            .init(name: "shouted ascii",     pattern: "invoice",     text: "INVOICE ATTACHED",  expected: true),
            // Turkish: uppercase I must not fold to dotless ı.
            .init(name: "turkish dotted I",  pattern: "istanbul",    text: "İstanbul ofisi",    expected: true),
            .init(name: "turkish dotless i", pattern: "isik",        text: "IŞIK raporu",       expected: true),
            // German: ß folds to ss, umlauts drop their diacritics.
            .init(name: "german eszett",     pattern: "strasse",     text: "Hauptstraße 5",     expected: true),
            .init(name: "german umlaut",     pattern: "bestatigung", text: "Bestätigung nötig", expected: true),
            .init(name: "no false positive", pattern: "invoice",     text: "in voice memo",     expected: false)
        ]
        for c in cases { XCTAssertEqual(c.text.matchKey.contains(c.pattern.matchKey), c.expected, c.name) }
    }

    func test_whenQuotedPattern_thenWholeWordOnly() {
        XCTAssertTrue(RulesEngine.containsWord("invoice".matchKey, in: "an invoice arrived".matchKey))
        XCTAssertFalse(RulesEngine.containsWord("invoice".matchKey, in: "three invoices".matchKey))
        XCTAssertTrue(RulesEngine.containsWord("ayse".matchKey, in: "from Ayşe: hello".matchKey))
    }

    /// Error path: a v1.x kind is reported, not thrown, and does not disable the rest.
    func test_whenRegexRuleCompiledInV1_thenReportedNotThrown() {
        let rule = Rule(id: 1, kind: .regex, pattern: "(a+)+$", matchField: .any, appBundleId: nil,
                        color: "amber", priority: 0, isEnabled: true, createdAt: UnixDate(Date()))
        let (compiled, problems) = RulesEngine.compile([rule])
        XCTAssertTrue(compiled.isEmpty)
        XCTAssertEqual(problems.first?.kind, .notAvailableInThisVersion)
    }
}
```

`RuleConflictTests` builds rules and one Slack notification ("URGENT: deploy failed on main", sender "Ayşe") through two private factories and asserts the resolution rules directly:

```swift
// Tests/BackglanceCoreTests/Unit/RuleConflictTests.swift, excerpt
func test_whenVIPAndMuteBothMatch_thenVIPWins() {
    let (compiled, problems) = RulesEngine.compile([
        rule(1, .mute, "com.tinyspeck.slackmacgap", field: .app, priority: 100),
        rule(4, .vip, "ayse", field: .sender)
    ])
    XCTAssertTrue(problems.isEmpty)
    let t = RulesEngine.evaluate(slackNotification(), compiled: compiled,
                                 bundleID: "com.tinyspeck.slackmacgap")
    XCTAssertTrue(t.pinned)
    XCTAssertFalse(t.muted, "a VIP is never hidden by a mute, whatever its priority")
}
```

`test_whenTwoHighlightsMatch_thenHigherPriorityWinsAndOrderIsStable` compiles the `urgent`/`red`/priority 0 and `"deploy failed"`/`amber`/priority 5 rules from the worked example and asserts `t.highlight == .amber` and `t.matchedRuleIDs == [3, 2]`; `test_whenScopedToAnotherApp_thenNoMatch` asserts a Mail-scoped mute leaves a Slack notification untouched.

```swift
// Tests/BackglanceCoreTests/Performance/RulesPerformanceTests.swift
/// 100k notifications × 50 rules, off the main thread. The baseline is checked in;
/// the nightly macos-26 job fails the build on a regression.
func test_whenFiftyRulesOverHundredThousandRows_thenUnderBudget() throws {
    let archive = try Archive(fixture: "archive-100k")
    let rules: [Rule] = (0..<50).map { i in
        Rule(id: Int64(i + 1), kind: i % 5 == 0 ? .vip : .highlight, pattern: "term\(i)",
             matchField: .any, appBundleId: nil, color: "amber", priority: i,
             isEnabled: true, createdAt: UnixDate(Date()))
    }
    let (compiled, _) = RulesEngine.compile(rules)
    let rows = try archive.reader.read { db in try ArchivedNotification.fetchAll(db) }
    XCTAssertEqual(rows.count, 100_000)
    measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
        var pinned = 0
        for row in rows where RulesEngine.evaluate(row, compiled: compiled, bundleID: nil).pinned { pinned += 1 }
        XCTAssertGreaterThanOrEqual(pinned, 0)
    }
}
```

Import/export is covered by a round-trip: export the seeded rule set, empty the table, import the bytes, and assert the rules come back with identical `kind`, `pattern`, `matchField`, `appBundleId`, `color`, `priority` and `isEnabled` — ids may differ, since they are archive-local. A second import of the same file must report `(imported: 0, skipped: n)`.

## Next Steps

- Read [TIMELINE.md](./TIMELINE.md) for how `Triage` becomes pins, tints, and the collapsed "Muted (n)" group, then [ACTIONS.md](./ACTIONS.md#open-in-system-settings--notifications) for the System Settings deep link — the only thing in Backglance that leads to actually stopping a notification.
- Read [SECURITY.md](../security/SECURITY.md) for the regex work bounds before enabling `kind = 'regex'` in v1.x, and [INTERNATIONALIZATION.md](../reference/INTERNATIONALIZATION.md) before touching any comparison in the engine.

## Related Documentation

- [TIMELINE.md](./TIMELINE.md) — how triage renders: pinning, tinting, muted collapse, unread badge
- [ACTIONS.md](./ACTIONS.md) — "Mute this app" and the System Settings ▸ Notifications deep link
- [MISSED_DIGEST.md](./MISSED_DIGEST.md) — VIP first, muted collapsed at the bottom
- [SEARCH.md](./SEARCH.md) — the `is:vip` post-filter
- [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md) — exclusion vs muting, and the `[code redacted]` placeholder
- [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md) — the `rules` and `apps` DDL
- [INTERNATIONALIZATION.md](../reference/INTERNATIONALIZATION.md) — `matchKey` and the Turkish dotted/dotless I rule
- [ACCESSIBILITY.md](../reference/ACCESSIBILITY.md) — highlight tint contrast and Increase Contrast behaviour
- [SECURITY.md](../security/SECURITY.md) — regex work bounds and the auto-disable rule
- [API_DOCUMENTATION.md](../api/API_DOCUMENTATION.md) — `RulesEngine`, `Triage`, `CompiledRules` signatures
- [PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md) — triage budgets at 100k notifications
- [ROADMAP.md](../reference/ROADMAP.md) — `regex` rules and the noisy-app suggestion in v1.x
