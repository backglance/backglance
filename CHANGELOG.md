# Changelog

Last Updated: 2026-08-18

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
