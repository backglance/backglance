# Changelog

Last Updated: 2026-08-20

All notable changes to Backglance are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html): breaking changes (including any archive migration that is not forward-transparent) bump MAJOR, features bump MINOR, fixes bump PATCH. Pre-1.0 releases (`0.x`) make no compatibility promises, and the archive may be reset between them.

Conventions used here:

- Entries are grouped under the Keep a Changelog categories: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.
- Every release that ships a binary links its GitHub Release (signed, notarized, with SHA-256 checksums); documentation-only tags say so explicitly.
- Archive migrations are always called out in the entry that introduces them, with the migration name (e.g. `v2_saved_searches`).
- Deprecations are announced one minor version before removal.

## [Unreleased]

Work in progress toward v1.0 — the nine MVP feature groups (see [docs/reference/ROADMAP.md](docs/reference/ROADMAP.md) for milestones and status).

Project scaffolding is complete: a fresh clone runs `Scripts/bootstrap.sh`, opens in Xcode, builds,
tests and lints clean.

Continuous integration is deliberately not running yet. The four workflow files are authored and
their gates reproduce green locally, but they stay untracked until M4 so that nothing is verified by
a pipeline that no one is watching; `docs/deployment/CI_CD.md` remains the canonical copy. Until
then, the build, test and lint gates are local commands.

### Added

- `Backglance.xcodeproj` with the `Backglance` app target — macOS 14.0 deployment target, Swift 5
  language mode on the Swift 6 toolchain, complete strict concurrency, hardened runtime, and a
  shared scheme. New sources need no project-file edit: the app and test targets use
  filesystem-synchronized groups
- `Config/Debug.xcconfig` and `Config/Release.xcconfig`, with the git-ignored `Local.xcconfig` pulled
  in by `#include?` for personal-team signing; `agvtool` keeps the two version numbers in the project
  file
- `Backglance/Info.plist` (`LSUIElement`, the `backglance://` URL type, the Sparkle keys) and the
  deliberately empty `Backglance/Backglance.entitlements` — no sandbox, no hardened-runtime
  exceptions. `SUPublicEDKey` is a Release-only substitution, so a Debug build never starts the updater
- Status item template imagesets (running, paused, degraded), an AppIcon placeholder, and an empty
  `Localizable.xcstrings`
- The four Swift packages — `BackglanceCore` (GRDB 7.x), `BackglanceCapture` (plus the
  `FixtureGenerator` executable), `BackglanceSearch` (NaturalLanguage, Accelerate) and
  `BackglanceUI` — wired into the app with the documented dependency direction
- Four test bundles, the shared `BackglanceTestSupport` target (`SplitMix64`, `TestClock`, `Stubs`)
  and `Backglance.xctestplan` with its `Fast` and `Full` configurations
- `Scripts/bootstrap.sh`, `build.sh`, `grant_fda_hint.sh`, `ExportOptions.plist`, and the
  `pre-commit` / `commit-msg` git hooks
- Continuous capture: store watcher, fingerprinting, `StoreAdapterV14`/`V15`/`V26`, first-launch import, degraded mode (in progress)
- Timeline: menu bar popover and full window, day/app grouping, compact and detailed rows, unread badge (in progress)
- Instant search: FTS5 full-text search with filters, fuzzy matching, optional on-device semantic search (in progress)
- "What did I miss" digest: away-session tracking (lock, sleep, Focus, presenting) and a once-per-return, dismissible digest (in progress)
- Privacy controls: per-app retention, exclusion list with defaults, OTP redaction on by default for Messages and Mail, pause capture, panic wipe (in progress)
- Actions: open source app or deep link, copy text, delete, select-and-export to CSV/JSON (in progress)
- Rules: keyword highlights, VIP pinning, per-app muting — visual triage only (in progress)
- Onboarding: Full Disk Access flow with plain explanations and a graceful degraded mode (in progress)
- Foundation: zero telemetry, local-only archive, global hotkey ⌃⌥N, launch at login, Sparkle updater (user-disableable), `backglance://` URL scheme (in progress)

Planned pre-release tags on the way to 1.0.0, one per milestone (targets, not promises):

- `v0.2.0` — M1: capture, archive, adapters, fixtures
- `v0.3.0` — M2: timeline and search
- `v0.4.0` — M3: digest, privacy controls, onboarding
- `v1.0.0` — M4: actions, rules, foundation, release pipeline

## [0.2.0] - unreleased

M1 — capture core and archive. Backglance reads the system's notification store, recognises
which macOS it is looking at, and keeps what it finds in its own database.

> The tag is not cut yet: the milestone's exit criteria include live capture verified on
> macOS 14, 15 and 26 from a fresh clone, against a real store with Full Disk Access, which
> needs machines running those releases. Everything else in the criteria is green —
> `Scripts/verify_fixture.sh` passes for all three fixtures, a 10 000-record import finishes
> well inside its ten-second budget, and on macOS 26 the built app has been run end to end
> against the macOS 26 fixture: adapter resolved, backlog correctly left alone, a record
> appended afterwards captured, indexed and persisted, with no notification content logged.

### Added

- **The archive.** `Archive` over a GRDB `DatabasePool` in WAL mode, the `v1_initial` and
  `v1_fts` migrations, `UnixDate`, `ArchiveHealth`, and the models for notifications, apps,
  away sessions, digests, redactions and rules
- **Store access.** `StoreLocation`, `StoreSnapshot` (copy first, open read-only, never
  Apple's live file), `SnapshotDirectory` with its stale sweep, `StoreWatcher` (file events,
  wake, unlock, poll, debounced into one stream) and `StoreCursor`, persisted in
  `capture_state`
- **Adapters.** `StoreAdapter` with `StoreAdapterV14`, `V15` and `V26` over a shared
  `RecordQuery`, `StoreFingerprint`, and a registry that resolves by exact fingerprint, then
  by OS major, then by newest adapter — with everything short of an exact match confirmed by
  a probe before it is used
- **Parsing.** `RecordParser` reading the store's abbreviated bplist keys with tolerant
  fallbacks, `ParsedNotification`, and `PlistGuard`, which treats every payload as hostile
  input: 64 KB per record, depth 8, 512 entries, 16 K characters, and never `NSKeyedUnarchiver`
- **The capture engine.** An actor driven by the watcher: bootstrap into running or degraded,
  a bounded batch per wake with the cursor persisted after it, the exclusion → redaction →
  enrichment → insert pipeline, first-launch import, pause with a cursor fast-forward, and
  in-place refresh for notifications the store rewrites
- **The app runs it.** `AppDelegate` opens and migrates the archive, builds the capture engine
  on top of it with the real enrichment service, and starts it at launch. Until now every one
  of the pieces above existed and was tested, but nothing in the shipping app ever constructed
  them, so no notification was ever captured outside the test suite
- **Transient failures are retried.** Copying a live SQLite database races the process writing
  to it, and a torn snapshot is ordinary rather than alarming. Capture now degrades only after
  five consecutive read failures, and permission and schema failures — the ones a person can
  act on — still surface at once
- **Enrichment.** An on-disk app-icon cache and deep-link resolvers for Messages, Mail, Slack
  and Discord, plus a generic scan that only accepts URLs this Mac can actually open
- **Fixtures.** `FixtureGenerator`, `Scripts/make_fixture.sh`, `Scripts/verify_fixture.sh`, a
  250-record synthetic fixture per supported macOS, and a harness that checks each one end to
  end — fingerprint, adapter, probe, every parsed field, and the final cursor
- **Observability.** The nine `Log` categories behind a `RedactingLogger` whose API cannot be
  handed a notification, and `CaptureMetrics`, which counts what each tick did and nothing else

### Fixed

- Live capture on a fresh archive starts at the store's **tail** rather than at its first
  record. Starting at the beginning meant the entire pre-install backlog was archived as if
  it had just arrived — unasked, recorded as `source = 'live'`, and leaving the explicit
  first-launch import with nothing left to do
- A watcher released without `stop()` closes its file descriptors. `deinit` finished the wake
  stream and nothing else, so it left descriptors on `db`, `db-wal` and `db2/` open and a poll
  timer running for the lifetime of the process
- `StoreWatcher.start()` is idempotent for system events too, as it always claimed to be:
  re-arming replaced the file, directory and timer sources but only ever appended the wake,
  unlock and power-state observers
- `CaptureMetrics.ticks` counts every tick rather than only those that archived something. It
  is the counter that distinguishes "nothing new to capture" from "the watcher stopped waking
  us", and it could not do that while an idle Mac left it frozen
- Resuming from a pause positions the cursor with a single-row tail query instead of walking
  every record delivered during the pause — which pulled all of their payloads into memory
  purely to discard them
- `Archive.repairCounts()` exists. Two documents promised it as the repair for a drifted
  `apps.notification_count`, and there was no such method
- The test plan's `Fast` and `Full` configurations differ again. Both set
  `BACKGLANCE_TEST_SCOPE` and nothing read it, so the two ran exactly the same tests; `Fast`
  now skips the ten-thousand-record import benchmark and `Full` still runs it
- `Scripts/bootstrap.sh` reads the Team ID from a signing certificate's `OU` field rather
  than the ten characters in its common name, which name the developer and not the team.
  With no certificate at all it now writes an ad-hoc signing configuration that still
  builds, and it warns when an existing `Config/Local.xcconfig` names a team this Mac has
  no certificate for
- The test bundles find `Tests/Fixtures/` through `BackglanceTestSupport.Fixtures`, which
  derives the path from its own source location. `Bundle.module` exists only in the
  SwiftPM build of these sources, so the Xcode test targets the test plan runs could not
  compile — `xcodebuild test -scheme Backglance -testPlan Backglance` now runs green, as
  does `swift test` for each package

### Security

- A failed archive write no longer carries the notification into the error. GRDB spells a
  failing statement's bound arguments into its error message when
  `publicStatementArguments` is on, which Backglance enables in DEBUG builds so SQL is
  readable while developing — and the notification insert binds the title, subtitle, body and
  sender. Rendering that error with `String(describing:)` put a user's own notification text
  into `ArchiveError.logDescription`, the property documented as safe to log publicly, which
  the capture engine then logs. Errors are now rendered by `ArchiveError.detail(from:)`, which
  keeps SQLite's result code and message and drops the statement and its arguments
- The SwiftLint rules that enforce "no notification content in a log" actually match this
  codebase. They keyed on a literal `logger.`, and every call site here uses
  `Log.capture` / `Log.parser`, so the rules had been matching nothing at all
- Excluded apps are checked against the store row before the payload is decoded, so their
  notifications never become objects in memory
- Nothing that touches notification content can reach a log: `NotificationLogRef` carries an
  id, a bundle id and a length, and the overloads that would take a notification are marked
  unavailable
- Every fixture is synthetic and machine-checked: `verify_fixture.sh` refuses an address
  outside `example.*`, a phone number outside the fictional range, a `/Users/<name>/` path,
  an iCloud address, or code-shaped text the generator did not produce

## [0.1.0] - 2026-08-17

Initial pre-release. No binary is published for this tag; it marks the project skeleton and the documentation set. Everything described in the docs at this tag is design intent unless a later entry says it shipped.

### Added

- Complete documentation set under `docs/` — getting started, architecture, features, deployment, operations, security, testing, contributing, and reference (including [docs/reference/ROADMAP.md](docs/reference/ROADMAP.md), [docs/reference/COST_ESTIMATION.md](docs/reference/COST_ESTIMATION.md), [docs/reference/INTERNATIONALIZATION.md](docs/reference/INTERNATIONALIZATION.md), [docs/reference/ACCESSIBILITY.md](docs/reference/ACCESSIBILITY.md), and [docs/reference/FAQ.md](docs/reference/FAQ.md))
- Project skeleton: `Backglance` app target plus the `BackglanceCore`, `BackglanceCapture`, `BackglanceSearch`, and `BackglanceUI` packages, test targets, and scripts layout
- Store adapter strategy: `StoreFingerprint` + `StoreAdapter` protocol design with per-macOS adapters and OS-major fallback, documented in [docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md](docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md)
- Fixture strategy: synthetic system-store fixtures for macOS 14/15/26 (`Tests/Fixtures/SystemStore/`) with `manifest.json` + `expected.json`, and the `fixtures.yml` CI matrix design, documented in [docs/testing/TESTING.md](docs/testing/TESTING.md)
- Archive schema v1 design (GRDB migrations `v1_initial`, `v1_fts`) in [docs/architecture/DATABASE_SCHEMA.md](docs/architecture/DATABASE_SCHEMA.md)
- GPL-3.0 license, contributing guide, and security policy
- CI workflow designs: `ci.yml`, `fixtures.yml`, `release.yml`, `cask-bump.yml` in [docs/deployment/CI_CD.md](docs/deployment/CI_CD.md)

### Security

- Privacy defaults locked in the design: zero telemetry, local-only archive with `0600` permissions, OTP redaction on by default, password managers excluded by default — see [docs/security/SECURITY.md](docs/security/SECURITY.md)

## Related Documentation

- [README.md](README.md)
- [docs/reference/ROADMAP.md](docs/reference/ROADMAP.md)
- [docs/deployment/CI_CD.md](docs/deployment/CI_CD.md)
- [docs/contributing/CONTRIBUTING.md](docs/contributing/CONTRIBUTING.md)

[Unreleased]: https://github.com/backglance/backglance/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/backglance/backglance/releases/tag/v0.1.0
