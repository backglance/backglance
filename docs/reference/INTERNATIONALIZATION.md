# Internationalization

Last Updated: 2026-08-18

Backglance v1.0 ships with an English UI, but every string, date, and comparison is written so that localization is a translation task, not a refactor. Localized UI (English, Turkish, German first) is planned for v2.0 — see [ROADMAP.md](./ROADMAP.md). This document sets the rules that keep the codebase i18n-ready from day one, and it spends most of its length on the one rule that silently corrupts behavior when broken: **locale-sensitive string operations in internal logic**, best known through the Turkish dotted/dotless I problem.

## Table of Contents

- [Status and scope](#status-and-scope)
- [String Catalogs](#string-catalogs)
  - [Authoring strings](#authoring-strings)
  - [Plural rules](#plural-rules)
  - [Export and import](#export-and-import)
- [Dates and numbers](#dates-and-numbers)
- [Right-to-left](#right-to-left)
- [The Turkish locale rule](#the-turkish-locale-rule)
  - [The dotted/dotless I bug](#the-dotteddotless-i-bug)
  - [The rule](#the-rule)
  - [Correct code](#correct-code)
  - [Where this matters in Backglance](#where-this-matters-in-backglance)
  - [Unit tests](#unit-tests)
- [FTS5 tokenizer and case folding](#fts5-tokenizer-and-case-folding)
- [OTP keyword lists live in code](#otp-keyword-lists-live-in-code)
- [Pseudo-localization testing](#pseudo-localization-testing)
- [Contributing translations](#contributing-translations)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Status and scope

> ℹ️ **Status:** Localized UI is planned for v2.0 — not in v1.0. v1.0 ships English UI but must be i18n-ready: every user-facing string goes through the String Catalog from the first commit, and every internal string operation follows the locale-neutrality rule below.

| Aspect | v1.0 | v2.0 plan |
|---|---|---|
| UI language | English | English, Turkish, German (`en`, `tr`, `de`); more via community PRs |
| String storage | `Localizable.xcstrings` (single catalog, `en` only) | Same catalog, added languages |
| Dates/numbers | Localized already (formatters follow the user's locale) | Unchanged |
| Notification content | Never localized — it is the user's own data, in whatever language it arrived | Unchanged |
| OTP keywords | EN + TR + DE lists active regardless of UI language | Extended per new language, in code |

Note the asymmetry: even with an English UI, Backglance runs on Macs set to Turkish, German, or anything else, and archives notifications in every language. Locale correctness is a v1.0 requirement; only *translation* is v2.0.

## String Catalogs

### Authoring strings

All user-facing strings live in `Backglance/Resources/Localizable.xcstrings` (Xcode String Catalog). Xcode extracts entries from `String(localized:)` and SwiftUI string literals at build time — but only for the target that *owns* the catalog, which in a repository with four local packages is not enough on its own; see [The one catalog and four packages](#the-one-catalog-and-four-packages) below.

```swift
// SwiftUI: string literals in Text/Button are auto-extracted as localization keys.
Text("What you missed")
Button("Mark all as read") { model.markAllRead() }

// Non-SwiftUI call sites: String(localized:) with a comment for translators.
let pauseTitle = String(
    localized: "Pause capture",
    comment: "Menu item: temporarily stop archiving notifications"
)

// Strings passed around before display: LocalizedStringResource defers
// resolution to render time, so the value localizes in the viewer's language.
enum DigestStrings {
    static let emptyTitle: LocalizedStringResource = "Nothing arrived while you were away"
}
```

Rules:

- No user-visible string is assembled by concatenation; use format specifiers so word order can change per language: `String(localized: "\(count) notifications from \(appName)")`.
- Every non-obvious key gets a `comment:` — translators see the comment, not the UI.
- Log messages, `os.Logger` output, SQL, bundle IDs, URL scheme parts, and rule patterns are **not** localized and never go through the catalog.

### The one catalog and four packages

The design above — one catalog, every string in it — is right at *runtime*: `String(localized:)` and SwiftUI's `Text("literal")` resolve against `Bundle.main`, which is `Backglance.app`, and no call site in this repository passes a `bundle:` argument. It does not happen on its own at *build* time, and the gap is quiet enough to have gone unnoticed for four milestones:

| Target | Extracted by an app build? | Why |
|---|---|---|
| `Backglance` (app) | Yes, ~27 keys | It owns the catalog |
| `BackglanceUI` | Into its own bundle, which nothing reads | A package is a separate target; its `defaultLocalization` sends strings to a generated `en.lproj` |
| `BackglanceCore`, `BackglanceCapture`, `BackglanceSearch` | No | They had no `defaultLocalization`, so nothing extracted them anywhere |

Because a missing key falls back to the key itself, all of it rendered correct English regardless, which is exactly why the catalog sat empty while 400+ call sites were written against it. The same fallback is why `^[…](inflect: true)` silently produced the singular noun for every count: automatic grammar agreement needs the key to be *in* the catalog, and the fallback path strips the markup and keeps the literal.

The fix is two parts, and both are in the repository:

1. Every package declares `defaultLocalization: "en"`. This gives the package no catalog of its own and changes no lookup — it only makes `xcodebuild -exportLocalizations` walk the target at all.
2. `Scripts/sync_string_catalog.sh` runs that export, which is the one tool that walks every target, and merges the union of what it finds into the single catalog. Translations already in the catalog are never overwritten; a key that leaves the source but carries translations is marked `stale` rather than deleted.

```bash
Scripts/sync_string_catalog.sh            # after adding or changing any user-facing string
Scripts/sync_string_catalog.sh --check    # what CI runs; fails when the catalog has drifted
```

> ⚠️ **Warning:** No test bundle in this project has a `TEST_HOST` (BACKGLANCE-238), so in a unit test `Bundle.main` is the xctest runner rather than `Backglance.app` and the catalog is never consulted. A test that asserts the exact English of a `String(localized:)` result is therefore asserting the fallback, not the catalog — and a plural written with `inflect: true` will come back singular. Assert on the model's counts, not on the rendered sentence.

### Plural rules

String Catalogs handle plural variation per language (Turkish has no plural distinction in this position; German and English do). Author with an interpolated count and define variants in the catalog editor:

```swift
// One key, per-language plural variants defined in Localizable.xcstrings.
Text("^[\(digest.itemCount) notification](inflect: true) while you were away")
```

For counts in `String(localized:)` contexts, use the same catalog plural support rather than `count == 1 ? ... : ...` — the ternary hardcodes English grammar.

### Export and import

Translation round-trips use Xcode's localization catalogs:

```bash
# Export a translation package for each target language
xcodebuild -exportLocalizations \
  -project Backglance.xcodeproj \
  -localizationPath ./localizations \
  -exportLanguage tr -exportLanguage de

# Import a returned package (translators edit the .xcloc bundle,
# or edit Localizable.xcstrings directly in Xcode)
xcodebuild -importLocalizations \
  -project Backglance.xcodeproj \
  -localizationPath ./localizations/tr.xcloc
```

In practice most contributions will edit the `.xcstrings` JSON directly in a pull request (see [Contributing translations](#contributing-translations)); `xcloc` export exists for translators who prefer a dedicated editor.

## Dates and numbers

Never hand-format dates or numbers. Use `Date.FormatStyle` / `FormatStyle`, which follow the user's locale, calendar, and 12/24-hour preference automatically:

```swift
// Timeline row time: "14:32" (tr/de, 24h) or "2:32 PM" (en-US)
Text(notification.deliveredAt, format: .dateTime.hour().minute())

// Day header: "17 Ağustos 2026" / "17. August 2026" / "August 17, 2026"
Text(day, format: .dateTime.day().month(.wide).year())

// Relative "away for 2 hours" in the digest header
let away = Duration.seconds(session.endedAt.timeIntervalSince(session.startedAt))
Text(away, format: .units(allowed: [.hours, .minutes], width: .wide))

// Counts: grouping separators differ (1.234 in tr/de, 1,234 in en)
Text(archiveCount, format: .number)
```

The archive itself stores raw Unix seconds (`UnixDate`, see [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md)); formatting is a display concern only. `QueryParser` accepts dates as `YYYY-MM-DD` (locale-independent ISO) in `before:`/`after:` filters, and that stays true in every locale.

## Right-to-left

Arabic/Hebrew localization is **not targeted** — but the layout must not break if the system locale is RTL or if a notification's *content* is RTL (an Arabic WhatsApp message on an English Mac is an everyday case).

- Use SwiftUI's leading/trailing alignment, never left/right, so rows mirror correctly for free.
- Notification body text renders with the text's own directionality (SwiftUI/TextKit handle bidi); do not force `.leading` alignment on body text of unknown direction — use the default natural alignment.
- Icons that imply direction (chevrons) use SF Symbols, which flip automatically in RTL contexts.

## The Turkish locale rule

This section is normative. It exists because the developer's own locale is Turkish, which is the canonical way to discover this class of bug the hard way.

### The dotted/dotless I bug

Turkish has four distinct letters where English has two: `I`/`ı` (dotless) and `İ`/`i` (dotted). Under Turkish casing rules, uppercase `I` lowercases to **`ı`**, not `i`:

```swift
// The bug, demonstrated:
let tr = Locale(identifier: "tr")

"TITLE".lowercased(with: tr)   // "tıtle"  — dotless ı!
"TITLE".lowercased()           // "title"  — locale-independent, as expected

"tıtle" == "title"             // false
```

So any equality, prefix, or containment check that uses locale-sensitive lowercasing breaks on a Turkish-locale Mac whenever the text contains `I` or `i` — which in practice means constantly (`INVOICE`, `PIN`, `LinkedIn`, `com.microsoft.teams2` vs a user typing `TEAMS`…). The same class of problem exists in other locales (Lithuanian dot handling, Azerbaijani has the same I rules), so the fix is locale-*neutrality*, not special-casing Turkish.

### The rule

> ✅ **Do:** Use **locale-neutral** case operations for ALL internal string logic: `lowercased()` (which is locale-independent in Swift) or `folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)` for comparisons.
>
> ❌ **Don't:** Use `lowercased(with:)`, `uppercased(with:)`, `localizedCaseInsensitiveCompare`, or `localizedStandardContains` in rule matching, bundle ID handling, query parsing, keyword redaction, deduplication, or any other logic path.
>
> ✅ **Do:** Use locale-aware comparison — `compare(_:options:range:locale:)` with the user's locale, or `localizedStandardCompare` — **only** for user-facing sort order (e.g. the app list in Settings), where Finder-like ordering is exactly what the user expects.

### Correct code

```swift
import Foundation

/// Locale-neutral, case- and diacritic-insensitive key for internal matching.
/// "İstanbul", "ISTANBUL", and "istanbul" all produce "istanbul".
extension String {
    var matchKey: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased() // lowercased() without a locale is locale-independent
    }
}

// RulesEngine: keyword rules match on locale-neutral keys.
func ruleMatches(pattern: String, in text: String) -> Bool {
    text.matchKey.contains(pattern.matchKey)
}

// Bundle IDs: compared byte-for-byte after locale-neutral lowercasing.
// (Bundle IDs are ASCII in practice, but a Turkish-locale lowercased(with:)
// on "com.microsoft.OneDrive-mac" would still be a latent bug.)
func sameApp(_ a: String, _ b: String) -> Bool {
    a.lowercased() == b.lowercased()
}

// QueryParser: the "from:" filter must find Slack when the user types "SLACK".
func appFilterMatches(userInput: String, displayName: String, bundleID: String) -> Bool {
    let key = userInput.matchKey
    return displayName.matchKey.contains(key) || bundleID.lowercased().contains(key)
}

// User-facing sort ONLY: the Settings app list sorts like Finder,
// respecting the user's locale (Turkish users expect İ to sort next to I).
func sortedForDisplay(_ apps: [AppRecord]) -> [AppRecord] {
    apps.sorted {
        ($0.displayName ?? $0.bundleID)
            .localizedStandardCompare($1.displayName ?? $1.bundleID) == .orderedAscending
    }
}
```

### Where this matters in Backglance

| Path | Operation | Required behavior |
|---|---|---|
| `RulesEngine` keyword/sender/app matching | containment/equality | `matchKey` (locale-neutral) |
| `OTPRedactor` keyword proximity matching | containment | `matchKey`; TR keywords like "doğrulama" must match with or without diacritics typed |
| Bundle ID lookups (`apps.bundle_id`, exclusion list) | equality | `lowercased()`, no locale |
| `QueryParser` (`from:`, field names, operators) | equality/prefix | `lowercased()`, no locale |
| Dedup (`uuid`, `store_rec_id`) | equality | exact bytes, no case ops at all |
| Settings app list, saved-search list | sort | `localizedStandardCompare` (user's locale) |
| Timeline day grouping | calendar | user's `Calendar.current` (locale-aware by design) |

### Unit tests

`BackglanceCoreTests/LocaleNeutralityTests.swift` pins the behavior; these tests run in CI on every PR.

> ℹ️ **Note:** the sketch below predates the code. `ruleMatches` and `sameApp` were never free functions — the shipped primitive is `String.matchKey` (`BackglanceCore/Redaction/MatchKey.swift`), and the tests assert against the real call sites that use it: `OTPRedactor`'s keyword matching and `PresentationPolicy`'s window-title prefix. The query grammar's half lives in `BackglanceSearchTests/QueryParserLocaleTests.swift`, because `QueryParser` is in another module. The rules engine row in the table above is still aspirational: only the `Rule` model and `Triage` exist so far, so there is no matching path to audit yet.

```swift
import XCTest
@testable import BackglanceCore

final class LocaleNeutralityTests: XCTestCase {

    func testDottedDotlessIBugIsReal() {
        // Documents the failure mode we are defending against.
        let tr = Locale(identifier: "tr")
        XCTAssertEqual("TITLE".lowercased(with: tr), "tıtle")
        XCTAssertNotEqual("TITLE".lowercased(with: tr), "title")
    }

    func testLowercasedIsLocaleIndependent() {
        XCTAssertEqual("TITLE".lowercased(), "title")
        XCTAssertEqual("PIN".lowercased(), "pin")
    }

    func testRuleMatchingSurvivesTurkishText() {
        // A rule for "invoice" must match shouted Turkish-adjacent text.
        XCTAssertTrue(ruleMatches(pattern: "invoice", in: "INVOICE #42 due Friday"))
        // Diacritic-insensitive: "doğrulama" matches "dogrulama" and vice versa.
        XCTAssertTrue(ruleMatches(pattern: "dogrulama", in: "Doğrulama kodu: [code redacted]"))
    }

    func testBundleIDComparisonIsExactAfterNeutralLowercasing() {
        XCTAssertTrue(sameApp("com.tinyspeck.slackmacgap", "COM.TINYSPECK.SLACKMACGAP"))
        XCTAssertFalse(sameApp("com.apple.MobileSMS", "com.apple.mail"))
    }

    func testDisplaySortUsesLocale() {
        // Sort order may legitimately differ per locale; assert stability only.
        let names = ["iTerm", "İşbank", "Ivory", "index"]
        let sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        XCTAssertEqual(Set(sorted), Set(names))
    }
}
```

### The SwiftLint rule

`no_locale_sensitive_case_folding` in `.swiftlint.yml` is `severity: error` and rejects `lowercased(with:)`, `uppercased(with:)`, `localizedLowercase`, `localizedUppercase`, `localizedCaseInsensitiveCompare` and `localizedStandardContains` anywhere outside the test targets.

`localizedStandardCompare` and `compare(_:options:range:locale:)` are deliberately **not** in the list. Locale-aware sorting is correct and wanted, so a rule that banned it would only teach people to silence the rule.

The rule is verified to fire rather than assumed to: a rule whose regex matches nothing lints clean and enforces nothing, which is how the first version of the logging rule in the same file went unenforced. If you change the pattern, check it against a file that actually contains each forbidden spelling before trusting a green run.

There is one thing the linter cannot see. `String.lowercased()` is locale-neutral, but SQLite's `lower()` folds only `A`–`Z` unless ICU is compiled in, so a Swift-side fold compared against a SQL-side `lower()` disagrees for any non-ASCII text — a separate bug from this rule, and one the linter will never catch.

## FTS5 tokenizer and case folding

The archive's FTS table uses `tokenize = "unicode61 remove_diacritics 2 tokenchars '@.-'"` (see [SEARCH.md](../features/SEARCH.md)).

> ⚠️ **Warning:** `unicode61` performs *simple* Unicode case folding. Turkish dotted capital **İ (U+0130) does not fold to `i`** under simple folding — it becomes `i̇` (i + combining dot above, U+0307), which is a different token than plain `i`. Practical effect: a notification containing "İstanbul" is found by searching `İstanbul` or `istanbul` typed with a dotted i on a Turkish keyboard, but a match against a plain-ASCII `Istanbul` query token depends on the diacritic-removal pass and is not guaranteed for the İ→i case specifically.

Position for v1.0:

- This is a **documented limitation**, not a bug to engineer around yet. The affected case (uppercase İ in content vs. ASCII query) is narrow, and `FuzzyMatcher` (Levenshtein) usually rescues it in hybrid search.
- **No shadow column in v1.0.** The clean fix — an extra indexed column containing a `matchKey`-folded copy of the text — doubles FTS storage and adds trigger complexity, so it is deferred until real queries show it matters.
- `QueryParser` does not pre-fold query text destructively; it passes the user's token to FTS and, separately, a `matchKey` form to the fuzzy layer.

## OTP keyword lists live in code

The `OTPRedactor` keyword lists (EN: code, verification, passcode, OTP, one-time, PIN, login · TR: kod, doğrulama, şifre · DE: Code, Bestätigungscode, Einmalpasswort) are **compiled into `BackglanceCore`, not entries in the String Catalog**, for three reasons:

1. **They are matching data, not UI text.** Translating "verification" in the catalog would change redaction behavior with UI language — a Turkish user with an English UI still receives Turkish OTP messages, so all lists must be active at once, regardless of locale.
2. **Security review.** Changes to redaction behavior must go through code review and the redaction unit tests, not through a translation PR.
3. **Versioned pattern IDs.** Each list maps to a `pattern_id` (`otp.keyword.en`, `otp.keyword.tr`, `otp.keyword.de`) recorded in `redactions`; catalog entries have no such identity.

New-language keyword contributions are welcome — as code PRs against `OTPRedactor`, with tests, per [PRIVACY_CONTROLS.md](../features/PRIVACY_CONTROLS.md).

## Pseudo-localization testing

Before v2.0 translation begins, and periodically in v1.x, the UI is smoke-tested with pseudo-localization to catch clipped labels, truncation, and hard-coded strings:

- Run with `-NSDoubleLocalizedStrings YES` (doubles every localized string — catches truncation) and `-NSShowNonLocalizedStrings YES` (SHOUTS non-localized strings — catches strings that bypassed the catalog). Both are already in the shared scheme, unticked: Edit Scheme ▸ Run ▸ Arguments, tick the two, run, untick. They are shipped off because doubling every string on an ordinary debug run is noise, and shipped at all so the pass is two clicks rather than a thing to look up.
- Run `Scripts/sync_string_catalog.sh` first. `-NSShowNonLocalizedStrings` reports anything missing from the catalog, and until the sync has run that is *every* string in the four packages — which drowns the real finding.
- Xcode's scheme App Language settings also offer "Double-Length Pseudolanguage" and "Right-to-Left Pseudolanguage"; the latter verifies the [RTL](#right-to-left) non-breakage promise.
- German is a natural double-length test on its own ("Bestätigungscode" vs "code"); popover layouts are checked at German lengths even in v1.0.

## Contributing translations

When v2.0 opens localization (tracked in [ROADMAP.md](./ROADMAP.md)):

1. Open a GitHub Discussion claiming a language so two people don't translate the same one.
2. Fork, edit `Backglance/Resources/Localizable.xcstrings` in Xcode's catalog editor (or edit the JSON directly; it diffs cleanly), translating entries for your language. Alternatively request an `.xcloc` export in the Discussion.
3. Build and run with the scheme's App Language set to your language; screenshot the popover, digest, and Settings.
4. Open a PR with the screenshots. Review requires one native or fluent reviewer; for `tr` and `de` the maintainer can review directly.
5. OTP keywords for the new language are a **separate** code PR (see above).

Translations are licensed GPL-3.0 like everything else; see [CONTRIBUTING.md](../contributing/CONTRIBUTING.md).

## Next Steps

- v1.0 development: keep every new string in the catalog and every new comparison locale-neutral; the tests above are the gate.
- Before v2.0: run the pseudo-localization pass, freeze strings for a release, then invite translators.

## Related Documentation

- [ROADMAP.md](./ROADMAP.md)
- [ACCESSIBILITY.md](./ACCESSIBILITY.md)
- [FAQ.md](./FAQ.md)
- [SEARCH.md](../features/SEARCH.md)
- [PRIVACY_CONTROLS.md](../features/PRIVACY_CONTROLS.md)
- [RULES.md](../features/RULES.md)
- [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md)
- [TESTING.md](../testing/TESTING.md)
- [CONTRIBUTING.md](../contributing/CONTRIBUTING.md)
