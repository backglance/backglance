# Roadmap

Last Updated: 2026-08-18

This document is the public plan for Backglance: what ships in v1.0, what is queued for v1.x, what is sketched for v2.0, and the reasoning behind that order. It is written for contributors deciding where to help and for users deciding whether the thing they need is coming. Dates are targets, not promises; the project is developed by one person in the gaps of other work, and the roadmap is adjusted in the open (see [How the roadmap changes](#how-the-roadmap-changes)).

## Table of Contents

- [Reading this roadmap](#reading-this-roadmap)
- [Guiding principles](#guiding-principles)
- [v1.0 — the MVP](#v10--the-mvp)
  - [The nine feature groups](#the-nine-feature-groups)
  - [Milestones](#milestones)
  - [Definition of done for v1.0](#definition-of-done-for-v10)
- [v1.x — depth](#v1x--depth)
  - [Ordering and rationale](#ordering-and-rationale)
- [v2.0 — sketches](#v20--sketches)
- [Feature prioritization rationale](#feature-prioritization-rationale)
- [Category risk: Apple ships native history](#category-risk-apple-ships-native-history)
- [Technical debt register](#technical-debt-register)
- [Non-goals](#non-goals)
- [How the roadmap changes](#how-the-roadmap-changes)
- [Version and support policy](#version-and-support-policy)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Reading this roadmap

- **v1.0** is committed scope with target dates; slipping a date is allowed, slipping the privacy defaults is not.
- **v1.x** is committed direction with flexible order.
- **v2.0** is sketches — real enough to discuss, not real enough to depend on.
- Anything not listed is either a [non-goal](#non-goals) or simply hasn't been asked for yet; ask in [GitHub Discussions](https://github.com/backglance/backglance/discussions).

## Guiding principles

Three rules decide what gets built and in which order:

1. **Painkiller first.** The reason Backglance exists is a single unanswered question — "how do I see past notifications?" — that has been asked in Apple Support Communities for years and answered with "you can't". Anything that does not directly serve capture, timeline, and search waits.
2. **Ship what nobody else has.** A raw history is table stakes; the "What did I miss" digest, rules, and (later) analytics are the depth that a tiny utility or a shell script does not offer. The digest is in v1.0 for that reason, even though it is the hardest v1.0 feature.
3. **Privacy defaults are not negotiable.** OTP redaction on by default, password managers excluded by default, 30-day retention by default, zero telemetry, local-only. No roadmap item may weaken a default; items that strengthen them (at-rest encryption, Touch ID lock) are prioritized above convenience features.

> ℹ️ **Info:** Backglance is deliberately the developer's smallest, fastest project. Scope discipline is a feature. When in doubt, an item moves *out* of v1.0, not in.

## v1.0 — the MVP

Target: **v1.0.0 within roughly 6–8 weeks of 2026-08-17**, i.e. late September to mid October 2026. The first tagged pre-release is `0.1.0` (documentation set, project skeleton, adapter/fixture strategy) on 2026-08-17; see [CHANGELOG.md](../../CHANGELOG.md).

### The nine feature groups

| # | Group | Scope in v1.0 | Doc |
|---|---|---|---|
| 1 | **Continuous capture** | `StoreWatcher` (DispatchSource + 15 s fallback poll), snapshot-copy read of the system store, `StoreFingerprint` + `StoreAdapterRegistry` with `StoreAdapterV14` / `V15` / `V26`, first-launch import of what the store still holds, degraded mode when FDA is missing or the schema is unknown | [CAPTURE.md](../features/CAPTURE.md) |
| 2 | **Timeline** | Menu bar popover + full window, grouped by day and by app, compact/detailed rows, "new since you were away" marker, unread badge | [TIMELINE.md](../features/TIMELINE.md) |
| 3 | **Instant search** | FTS5 (`unicode61 remove_diacritics 2`), `QueryParser` filters (`from:`, `before:`, `after:`), `FuzzyMatcher`, optional on-device semantic search via `NLEmbedding` | [SEARCH.md](../features/SEARCH.md) |
| 4 | **"What did I miss" digest** | `AwaySessionTracker` (lock/unlock, sleep/wake, Focus, presenting), `DigestEngine`, one dismissible banner per away session, thresholds | [MISSED_DIGEST.md](../features/MISSED_DIGEST.md) |
| 5 | **Privacy controls** | Per-app retention, exclusion list with defaults, `OTPRedactor` on by default for Messages/Mail, pause capture, panic wipe | [PRIVACY_CONTROLS.md](../features/PRIVACY_CONTROLS.md) |
| 6 | **Actions** | Open source app / deep link, copy text, delete, select-and-export (CSV/JSON) | [ACTIONS.md](../features/ACTIONS.md) |
| 7 | **Rules** | Highlight keywords, pin VIP senders, mute noisy apps — visual triage only | [RULES.md](../features/RULES.md) |
| 8 | **Onboarding** | FDA flow that explains what is read and what is never read; graceful degraded mode until granted | [PERMISSIONS_PRIVACY.md](../features/PERMISSIONS_PRIVACY.md) |
| 9 | **Foundation** | Zero telemetry, no account, `NSStatusItem` + `NSPopover`, ⌃⌥N hotkey, launch at login, Sparkle 2.7.x updater (disable-able), `backglance://` URL scheme (search/open/pause/resume/digest), logging | [ARCHITECTURE.md](../architecture/ARCHITECTURE.md) |

### Milestones

Each milestone ends with a tagged pre-release (`0.2.0`, `0.3.0`, `0.4.0`) built by the release workflow, so the pipeline itself is exercised long before v1.0.

| Milestone | Target week | Contents | Exit criteria |
|---|---|---|---|
| **M1 — Capture core** | Weeks 1–2 (2026-08-17 → 2026-08-30) | `BackglanceCapture` (`StoreLocation`, `StoreFingerprint`, `StoreAdapter` protocol, `StoreAdapterV14/V15/V26`, `RecordParser`, `StoreWatcher`, `CaptureEngine`), `BackglanceCore` archive + `v1_initial` / `v1_fts` migrations, synthetic fixtures for macOS 14/15/26, `fixtures.yml` running on `macos-14`, `macos-15`, `macos-26` | Live capture on all three OS versions from a fresh clone; `verify_fixture.sh` green in CI; import of 10k fixture records < 10 s |
| **M2 — Timeline + search** | Weeks 3–4 (2026-08-31 → 2026-09-13) | `BackglanceUI` timeline (popover + window), pagination of 200 rows, `FTSIndex`, `QueryParser`, `FuzzyMatcher`, `HybridSearch`, semantic index behind an opt-in switch, unread badge, hotkey | Popover open-to-first-paint < 100 ms; FTS p95 < 50 ms at 100k synthetic notifications; keyboard-only navigation works ([ACCESSIBILITY.md](./ACCESSIBILITY.md)) |
| **M3 — Digest, privacy, onboarding** | Weeks 5–6 (2026-09-14 → 2026-09-27) | `AwaySessionTracker`, `DigestEngine`, digest banner, `OTPRedactor` (EN/TR/DE keyword lists), exclusion list, retention job, pause capture, `PanicWipe`, onboarding with FDA flow + degraded mode, XCUITest for onboarding | Digest fires once after a ≥ 5 min away session with ≥ 1 notification and never twice; redaction unit tests prove the original digits never reach the archive; onboarding passes with FDA denied and granted |
| **M4 — Actions, rules, foundation, release** | Weeks 7–8 (2026-09-28 → 2026-10-11) | Actions (open/copy/delete/export), `RulesEngine` + rules UI, Sparkle updater with EdDSA appcast on GitHub Pages, `sign_and_notarize.sh`, `release.yml`, Homebrew cask in `backglance/homebrew-tap`, `backglance://` scheme, VoiceOver pass | Notarized universal DMG produced by CI from a tag; `brew install --cask backglance/tap/backglance` works; Sparkle update from `0.4.0` → `1.0.0` succeeds; all v1.0 docs reflect shipped behavior |

```
2026-08-17                                                         ~2026-10-11
 |------- M1 -------|------- M2 -------|------- M3 -------|------- M4 -------|
   capture/archive     timeline/search    digest/privacy      actions/rules
   adapters/fixtures   badge/hotkey       onboarding          release pipeline
       0.2.0               0.3.0              0.4.0               1.0.0
```

#### Milestone task breakdown

The checklists below are the working list; each line maps to one or more GitHub issues with the milestone label. Ticked items are done as of the Last Updated date.

**M1 — Capture core**

- [x] Documentation set and project skeleton (`0.1.0`)
- [ ] `BackglanceCore`: `Archive`, `ArchiveMigrations` (`v1_initial`, `v1_fts`), `UnixDate`, models `ArchivedNotification`, `AppRecord`, `CaptureState`
- [ ] `BackglanceCapture`: `StoreLocation.current()`, `StoreFingerprint`, `StoreAdapter` protocol, `ProbeResult`, `StoreCursor`, `RawStoreRecord`
- [ ] Adapters `StoreAdapterV14`, `StoreAdapterV15`, `StoreAdapterV26` + `StoreAdapterRegistry.resolve(fingerprint:)`
- [ ] `RecordParser` (bplist → `ParsedNotification`, Cocoa epoch dates) ⚠️
- [ ] `StoreWatcher` (DispatchSource on `-wal`/db, 15 s / 60 s poll, wake + unlock triggers, snapshot copy with `?immutable=1`)
- [ ] `CaptureEngine` (`start`, `pause(until:)`, `resume`, `importExisting`, `CaptureStatus`)
- [ ] `EnrichmentService` (icons, deep links)
- [ ] `Scripts/make_fixture.sh`, `Scripts/verify_fixture.sh`; fixtures for macOS 14/15/26 with `manifest.json` + `expected.json`
- [ ] `.github/workflows/fixtures.yml` on `macos-14`, `macos-15`, `macos-26`
- [ ] Tag `0.2.0`

**M2 — Timeline + search**

- [ ] `StatusItemController`, `NSPopover` + `NSHostingController`, `HotKeyCenter` (⌃⌥N)
- [ ] `TimelineView`, `NotificationRow`, day/app grouping, compact/detailed toggle, 200-row pagination
- [ ] Unread badge (`is_read = 0` since last popover open, capped at 99+)
- [ ] `FTSIndex`, `QueryParser`, `FuzzyMatcher`, `HybridSearch`, `SearchBar`
- [ ] `SemanticIndex` behind "Semantic search" setting; background batches of 50
- [ ] Keyboard navigation and VoiceOver labels per [ACCESSIBILITY.md](./ACCESSIBILITY.md)
- [ ] Performance harness for FTS p95 / popover paint
- [ ] Tag `0.3.0`

**M3 — Digest, privacy, onboarding**

- [ ] `AwaySessionTracker` (lock/unlock, sleep/wake, Focus ⚠️, presenting heuristic)
- [ ] `DigestEngine`, `Digest` / `DigestItem` models, `DigestView`, banner with reduced-motion path
- [ ] `OTPRedactor` (EN/TR/DE keyword lists), `RedactionEvent`, tests proving originals never persist
- [ ] Exclusion list defaults, per-app retention, retention job (soft delete → hard prune)
- [ ] Pause capture (15 min / 1 h / until tomorrow / indefinitely) with menu bar paused state
- [ ] `PanicWipe.execute()` with typed confirmation and optional Touch ID
- [ ] Onboarding scenes with FDA explanation, degraded mode, `grant_fda_hint.sh`
- [ ] XCUITest for onboarding
- [ ] Tag `0.4.0`

**M4 — Actions, rules, foundation, release**

- [ ] Actions: open source app / deep link, copy, delete, select-and-export via `ExportService`
- [ ] `RulesEngine.evaluate`, `Rule` model, rules Settings pane, highlight colors with contrast check
- [ ] `URLSchemeHandler` for `backglance://search|open|digest|pause|resume`
- [ ] `SparkleUpdaterController`, `SUFeedURL`, `SUPublicEDKey`, "Check for updates automatically" toggle
- [ ] `Scripts/sign_and_notarize.sh`, `Scripts/make_appcast.sh`, `Scripts/bump_cask.sh`
- [ ] `.github/workflows/release.yml`, `cask-bump.yml`; `gh-pages` appcast
- [ ] `LaunchAtLogin` via `SMAppService.mainApp`
- [ ] Final docs pass; `CHANGELOG.md` `1.0.0` entry
- [ ] Tag `1.0.0`

#### Dependencies between groups

```
  Capture ──┬──> Timeline ──┬──> Actions
            │               ├──> Rules (needs rows to triage)
            ├──> Search     │
            ├──> Digest ────┘  (needs away sessions + notifications)
            └──> Privacy controls (retention/redaction sit on the insert path)

  Onboarding ──> Capture (FDA gate)        Foundation ──> everything (status item, hotkey, updater)
```

Search and Digest do not depend on each other; M2 and M3 could swap if the away-session work turns out to be easier than expected. Actions and Rules both need a stable timeline row model, which is why they are last.

> ⚠️ **Warning:** M1 is the milestone with real schedule risk, because it rides an undocumented system store. If macOS 26.x point releases change the `record` table between now and M4, adapter work moves ahead of everything else. The fixture matrix exists so that this is discovered by CI, not by users.

### Definition of done for v1.0

- All nine groups shipped and documented; feature docs match behavior.
- Public OS compatibility table (macOS 14, 15, 26 supported; 27 best-effort) verified by fixtures **and** by a manual run on real hardware for each version.
- Performance budgets in [PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md) met on an M1 MacBook Air and on one Intel Mac (best-effort).
- Privacy guarantees in [SECURITY.md](../security/SECURITY.md) verified: the only outbound connection is Sparkle, and it can be turned off.
- Notarized universal build, Homebrew cask, appcast, `CHANGELOG.md` entry, GitHub Release with SHA-256 checksums.
- English UI only, but i18n-ready (all strings in `Localizable.xcstrings`; see [INTERNATIONALIZATION.md](./INTERNATIONALIZATION.md)).

## v1.x — depth

Each v1.x item ships as a minor release (`1.1.0`, `1.2.0`, …) with its own archive migration where needed. Order below is the intended order, but items are independent enough to be reshuffled by demand.

| Order | Feature | Release | Migration | Doc |
|---|---|---|---|---|
| 1 | **Analytics** — per-app volume, hourly/weekly heatmaps, "noisiest apps", all computed locally from the archive | 1.1 | none | [ANALYTICS.md](../features/ANALYTICS.md) |
| 2 | **Snooze / resurface** — local reminders via `UNUserNotificationCenter`, optional EventKit Reminders export | 1.1 | `v3_snoozes` | [SNOOZE_RESURFACE.md](../features/SNOOZE_RESURFACE.md) |
| 3 | **Export & automation** — `backglance://export`, App Intents (`SearchNotificationsIntent`, `GetMissedDigestIntent`, `ExportNotificationsIntent`, `PauseCaptureIntent`, `SnoozeNotificationIntent`) | 1.2 | none | [EXPORT_AUTOMATION.md](../features/EXPORT_AUTOMATION.md) |
| 4 | **Saved searches / smart folders / regex rules** — persisted queries in the sidebar; `kind = 'regex'` rules | 1.2 | `v2_saved_searches` | [SAVED_SEARCHES.md](../features/SAVED_SEARCHES.md), [RULES.md](../features/RULES.md) |
| 5 | **At-rest encryption** — GRDB SQLCipher build, key in Keychain, migration tool from plain archive | 1.3 | in-place re-encryption | [SECURITY.md](../security/SECURITY.md) |
| 6 | **Touch ID lock** — `LAContext` gate on popover/window open, optional, timeout configurable | 1.3 | none | [PRIVACY_CONTROLS.md](../features/PRIVACY_CONTROLS.md) |
| 7 | **Widgets** — WidgetKit extension (`BackglanceWidgets`): unread count, last digest, pinned | 1.4 | none | [WIDGETS.md](../features/WIDGETS.md) |
| 8 | **CloudKit sync** — opt-in, off by default, end-to-end encrypted content, `v6_sync_metadata` | 1.5 | `v6_sync_metadata` | [CLOUDKIT_SYNC.md](../features/CLOUDKIT_SYNC.md) |

### Ordering and rationale

- **Analytics first** because it is the cheapest depth feature: pure SQL over the archive, no new permissions, no new tables, and it is the second thing people ask for after search ("which app is spamming me?").
- **Snooze** second because it is small, uses an existing model (`Snooze` table), and turns the archive from passive into something that helps you act. It also introduces `UNUserNotificationCenter` usage carefully — Backglance posting notifications about notifications must stay rare and opt-in.
- **Export & automation** third because power users start asking on day one, but the URL scheme already covers search/open/pause in v1.0, so the remaining pieces (export, Shortcuts) can wait.
- **Saved searches and regex rules** are grouped: both are "keep this query" features, and regex rules need the same validation UI (a live-tested pattern field with a timeout guard).
- **At-rest encryption and Touch ID** come before sync on purpose: sync multiplies the number of places data lives, so local protection ships first. v1.0 relies on FileVault + `0600` file permissions + an own directory; SQLCipher was left out of v1.0 to keep the binary and build simple (see [Technical debt register](#technical-debt-register)).
- **Widgets** need `BackglanceUI` to be stable and an App Group for the archive path; not hard, but a packaging change that is better done once the core has settled.
- **CloudKit sync last** because it is the largest, the only feature that touches Apple infrastructure, and the one most likely to be cut if it cannot be made trustworthy. It stays off by default forever.

## v2.0 — sketches

> ℹ️ **Status:** Roadmap only. Nothing here is designed in detail or scheduled.

- **OCR of image attachments into search.** Notifications with image attachments (screenshots, photos in Messages) would get their text extracted on-device using Vision (`VNRecognizeTextRequest`) and indexed into `notifications_fts`, reusing PasteShelf's OCR approach at the code level (request configuration, language hints, background queue). Only metadata is stored today (`attachments_json`); OCR would need an opt-in copy of the attachment or a read-at-index-time path, which is the open design question. Deferred to v2.0 because it needs a privacy design of its own.
- **"Inbox zero" review mode.** A keyboard-driven pass over unread notifications: ↩ open, `E` archive-as-read, `P` pin, `S` snooze, `⌫` delete. Rows leave the queue as you decide. Cheap to build once snooze exists; deferred because v1.0's timeline should first prove which actions people actually use.
- **Per-app statistics API for power users.** Local only: a `backglance://stats?app=<bundle_id>&range=30d` URL returning JSON via the URL scheme's callback, and a `GetAppStatisticsIntent` for Shortcuts. Not a network API — there is no server and there never will be.
- **Localized UI, EN/TR/DE first.** v1.0 ships English but is i18n-ready. Turkish and German are first because the developer can review them; further languages via community pull requests on `Localizable.xcstrings`. See [INTERNATIONALIZATION.md](./INTERNATIONALIZATION.md).

### What v2.0 is *not*

To keep the sketches honest: v2.0 is not a rewrite, not a platform expansion, and not a monetization event. It is the same app with three or four additions that each earned their place by being requested repeatedly in Discussions during v1.x. If none of the sketches above survive contact with real users, v2.0 will be something else — or there will simply be a long, boring, well-maintained v1.x line, which is a perfectly good outcome for a utility.

## Feature prioritization rationale

The order in this document was chosen by three filters, applied in sequence:

1. **Does it relieve the original pain?** Capture, timeline, search, onboarding, foundation are non-negotiable v1.0.
2. **Is it something a shell script or a five-line utility cannot offer?** The digest, rules, later analytics — this is why the digest is in v1.0 despite its complexity. A history without a "what did I miss" is a log; the digest is what makes it a tool.
3. **Does it protect the user by default?** Redaction, exclusion, retention, pause, panic wipe are v1.0 not because they are exciting but because shipping a notification archive without them would be irresponsible. Encryption at rest and Touch ID are queued directly after v1.0 for the same reason.

What deliberately lost: analytics (nice, not painkilling), sync (risky, optional), widgets (cosmetic until the core is right), OCR (privacy design needed), localization (English UI is acceptable for a v1.0 whose data is the user's own notifications, which are already in the user's language).

## Category risk: Apple ships native history

The obvious risk is that Apple adds a real notification history to macOS. It has been requested for a decade and ignored; that is no guarantee it stays that way. The plan is honest about it:

| Risk | Mitigation |
|---|---|
| Apple ships a basic "recent notifications" view | **Speed:** v1.0 in weeks, not quarters, so Backglance is already installed and useful before any WWDC. **Depth:** digest, rules, per-app retention, search with filters, analytics — things a first-party "recent" list is unlikely to have on day one. |
| Apple's version is good enough for most people | Backglance keeps serving the tail: people who need 30-day retention, search across months, redaction policy, export, and rules. Free-forever means the project has no revenue to lose; a smaller audience is fine. |
| Apple changes the store format to make third-party reads impossible | The fingerprint + adapter + fixture strategy detects it within hours via `fixtures.yml`; degraded mode tells the user plainly. If reads become impossible, the archive remains readable and exportable forever — nothing is lost, only new capture stops. |

**Why free-forever matters here.** A paid product in a category Apple might absorb has an incentive problem: it must grow before the platform moves. Backglance has no such incentive — no revenue, no acquisition target, nothing to sunset. If Apple ships native history tomorrow, the honest response is "good, that is what we wanted", and the project continues for the depth features as long as someone finds them useful. That is a healthier position than any business model in this category.

## Technical debt register

Known shortcuts taken to reach v1.0 in weeks. Each is tracked as a GitHub issue with the `tech-debt` label.

| Item | Where | Why it exists | Plan |
|---|---|---|---|
| **Adapter registry heuristics** ⚠️ | `StoreAdapterRegistry.resolve(fingerprint:)` — OS-major fallback after fingerprint miss, gated by `probe()` | Apple's store has no versioned schema; matching by SHA-256 of `sqlite_master` is exact but brittle, so a fallback exists | Keep fallback; add per-adapter `requiredColumns` to make `probe()` stricter; expand fixtures at every macOS point release |
| **Focus detection fragility** ⚠️ | `AwaySessionTracker` watching `~/Library/DoNotDisturb/DB/Assertions.json` + `ModeConfigurations.json` | No public API to observe Focus state from a third-party app | Keep the `presented == false` heuristic as the primary signal; treat the JSON files as a hint. Re-verify per macOS release; degrade to "lock/sleep only" if the files vanish |
| **Presenting detection heuristic** | Frontmost-app allowlist (Keynote, PowerPoint, Zoom, Google Meet via Chrome window title) | No `CGDisplayStream` use (would need Screen Recording permission, which is out of proportion) | Make the presenter list user-editable in Settings; consider `NSWorkspace.shared.frontmostApplication` + full-screen space detection |
| **Semantic search English-only** | `NLEmbedding.sentenceEmbedding(for: .english)` | Apple ships sentence embeddings for a limited set of languages; English is the only one verified | Detect dominant language per notification with `NLLanguageRecognizer`; use per-language embeddings where available; document limitation in [SEARCH.md](../features/SEARCH.md) |
| **No SQLCipher in v1.0** | Archive is plain SQLite (`0600`, own directory, FileVault assumed) | Simpler build, smaller binary, faster to ship | v1.3: GRDB SQLCipher build with Keychain key and one-way migration |
| **Universal binary size** | Universal 2 slices double the executable size | Intel best-effort support on macOS 14/15/26 | Acceptable for now; revisit when Intel is dropped |
| **Intel end-of-life** | Universal build, Intel best-effort | macOS 27 is Apple silicon only | When macOS 27 reaches GM: last Intel-capable release is the final v1.x on macOS 26; from the first release requiring macOS 27 features, ship Apple silicon only. Intel users keep receiving security fixes on the last Intel line for 6 months |
| **`lowercased(with:)` audit** | All string comparison paths | Turkish locale bug (dotted/dotless I) | Enforced by unit tests + a `swiftlint` custom rule; see [INTERNATIONALIZATION.md](./INTERNATIONALIZATION.md) |
| **Fixtures are synthetic only** | `Tests/Fixtures/SystemStore/` | Real stores contain private data and cannot be committed | Keep synthetic; add a `make_fixture.sh --from-live` that produces a scrubbed copy for local use only (never committed) |

## Non-goals

These are not "later" — they are things Backglance will not do, so nobody has to ask twice:

- **No server.** No hosted component, no relay, no web app. CloudKit sync (v1.x) uses the user's own iCloud account, opt-in, and is the only exception to "no cloud".
- **No accounts.** No sign-in, no license keys, no trial.
- **No iOS app in v1.** iOS has no equivalent readable store; the closest thing (iPhone Mirroring notifications) is captured on the Mac side already.
- **No changing system delivery.** Rules are visual triage in Backglance's timeline. Backglance does not and cannot suppress, reroute, or alter what macOS shows. That would need private APIs and would be wrong for a passive archive.
- **No Mac App Store.** Full Disk Access is incompatible with App Sandbox. Distribution is a Developer ID signed and notarized build on GitHub Releases and Homebrew.
- **No telemetry, no crash-reporting service, no analytics SDK.** Ever. Crash logs stay on the user's Mac and are attached to bug reports by hand.
- **No paid tier.** GPL-3.0, free forever.

## How the roadmap changes

- Feature requests and ordering discussions happen in **GitHub Discussions** (`Ideas` category) on `backglance/backglance`. Issues are for bugs and accepted work items.
- Roughly once per milestone the developer reviews Discussions, updates this file, and links the change in the release notes.
- Anything that would weaken a privacy default is closed with an explanation, not debated at length.
- A contributor who wants to build a v1.x/v2.0 item early is welcome: open a Discussion first so the design is agreed before the pull request; see [CONTRIBUTING.md](../contributing/CONTRIBUTING.md).

### What "no" sounds like

For calibration, requests that have already been declined in spirit and will be declined again:

- "Add an option to send digests to Slack/email" — needs a network path and credentials; conflicts with local-only. Export to JSON and pipe it yourself.
- "Block notifications from app X system-wide" — changing system delivery is a non-goal; macOS Settings ▸ Notifications does this.
- "Add opt-in anonymous analytics so you know what to build" — zero telemetry is a guarantee, not a default. Discussions are the analytics.
- "Charge for it so it survives" — free-forever is load-bearing for trust in this category; see above.

## Version and support policy

- **Semantic versioning.** `MAJOR.MINOR.PATCH`. Archive migrations only in minor or major releases; patches never migrate.
- **Supported macOS.** The three most recent major versions at any time (currently 14, 15, 26); the current beta is best-effort. When a new macOS ships, the oldest supported version becomes "security fixes only" for six months, then unsupported. See [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md).
- **Adapter response time.** When a macOS point release changes the store schema, the goal is a fixed adapter and a patch release within one week, with degraded mode protecting users meanwhile.
- **Updates.** Sparkle 2.7.x, EdDSA-signed appcast; users may disable the updater and instead watch GitHub Releases or use `brew upgrade`.
- **Deprecations.** Announced in `CHANGELOG.md` one minor version ahead. Intel is the only planned deprecation.
- **Security fixes.** Backported to the last release on every supported macOS line. Report privately per [SECURITY.md](../security/SECURITY.md).

### Release cadence at a glance

| Line | Cadence | Contains | Archive migration allowed |
|---|---|---|---|
| `0.x` pre-releases | Per milestone (M1–M3) | Whatever the milestone shipped; archive may be reset between them | yes (destructive OK, pre-release only) |
| `1.0.x` patches | As needed, goal ≤ 1 week for adapter breakage | Bug fixes, new/updated adapters, no features | no |
| `1.x.0` minors | Roughly every 6–10 weeks after 1.0 | One v1.x feature group each, plus fixes | yes (forward-only) |
| `2.0.0` | Unscheduled | See [v2.0 sketches](#v20--sketches) | yes |

## Next Steps

- Contributors: pick an M1 or M2 issue labeled `good first issue` after reading [DEVELOPMENT_GUIDE.md](../getting-started/DEVELOPMENT_GUIDE.md).
- Users: subscribe to Releases on GitHub; the `0.x` pre-releases are usable but the archive may be reset between them.
- Everyone: if you think an ordering is wrong, say so in Discussions with the use case, not just the feature name.

## Related Documentation

- [README.md](../../README.md)
- [CHANGELOG.md](../../CHANGELOG.md)
- [FAQ.md](./FAQ.md)
- [COST_ESTIMATION.md](./COST_ESTIMATION.md)
- [INTERNATIONALIZATION.md](./INTERNATIONALIZATION.md)
- [ACCESSIBILITY.md](./ACCESSIBILITY.md)
- [ARCHITECTURE.md](../architecture/ARCHITECTURE.md)
- [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md)
- [CAPTURE.md](../features/CAPTURE.md)
- [MISSED_DIGEST.md](../features/MISSED_DIGEST.md)
- [PRIVACY_CONTROLS.md](../features/PRIVACY_CONTROLS.md)
- [SECURITY.md](../security/SECURITY.md)
- [CI_CD.md](../deployment/CI_CD.md)
- [CONTRIBUTING.md](../contributing/CONTRIBUTING.md)
