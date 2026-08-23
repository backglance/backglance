# Backglance

Last Updated: 2026-08-18

**The notification history macOS never had.**

[![Build](https://img.shields.io/github/actions/workflow/status/backglance/backglance/ci.yml?branch=main&label=build)](https://github.com/backglance/backglance/actions/workflows/ci.yml)
[![Fixtures](https://img.shields.io/github/actions/workflow/status/backglance/backglance/fixtures.yml?branch=main&label=store%20fixtures)](https://github.com/backglance/backglance/actions/workflows/fixtures.yml)
[![Latest release](https://img.shields.io/github/v/release/backglance/backglance?include_prereleases&label=release)](https://github.com/backglance/backglance/releases/latest)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%20%7C%2015%20%7C%2026-lightgrey.svg)](docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md)

macOS throws notifications away the moment they're dismissed. Backglance keeps a private, searchable, **local** archive of every notification, shows you what you missed while you were away, presenting, or in a Focus, and gives you per-app retention, rules, and analytics to tame notification noise.

It is a small, sharp utility that answers a question people have been asking in Apple's forums for years — *"how do I see past notifications?"* — and have always been told "you can't."

## Table of Contents

- [Why Backglance exists](#why-backglance-exists)
- [Key features](#key-features)
- [Free, open source, no catch](#free-open-source-no-catch)
- [Privacy guarantees](#privacy-guarantees)
- [Tech stack](#tech-stack)
- [Quick start](#quick-start)
  - [Option A — Download the notarized app](#option-a--download-the-notarized-app)
  - [Option B — Build from source](#option-b--build-from-source)
- [macOS compatibility](#macos-compatibility)
- [How it works (in one diagram)](#how-it-works-in-one-diagram)
- [Project structure](#project-structure)
- [Screenshots](#screenshots)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [License](#license)

## Why Backglance exists

Apple Support Communities threads from 2022, 2024, and 2025 all ask the same thing and all end the same way: there is no notification history on macOS. Once a banner is dismissed or Notification Center is cleared, it's gone. A handful of tiny utilities and GitHub scripts exist; there is no polished, trusted tool for it.

Backglance is deliberately the smallest, fastest project its developer has shipped. It does one thing — remember your notifications — and does the few things around it that make that useful: a "what did I miss" digest, search, per-app retention and rules, and quiet analytics.

The obvious risk is that Apple ships native history someday. It has ignored the request for a decade. Our answer is speed-to-ship and depth: the digest, rules, and analytics are things a system feature would be unlikely to do, and because Backglance is free and GPL-3.0 there is no business to protect, nothing to acquire, and nothing to sunset if that day comes.

> ⚠️ **Warning:** Backglance reads Apple's *undocumented* Notification Center database (the "store"). That format can change in any macOS release. Backglance is built around that fact — versioned adapters, schema fingerprinting, per-macOS fixture tests, and a graceful "capture paused, archive intact" mode — but you should know it going in. See [OS_COMPATIBILITY_PLAYBOOK.md](docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md).

## Key features

### v1.0

| Feature | What it does | Docs |
|---|---|---|
| **Continuous capture** | Every notification is archived locally the moment it arrives; survives dismissal, restarts, and clearing Notification Center. On first launch it imports whatever the system store still holds. | [CAPTURE.md](docs/features/CAPTURE.md) |
| **Timeline** | Menu bar dropdown and a full window; grouped by day and by app; compact and detailed views; an "new since you were away" marker. | [TIMELINE.md](docs/features/TIMELINE.md) |
| **Instant search** | Full-text search (SQLite FTS5) with fuzzy matching; filters by app, date range, and sender; optional on-device semantic search ("that message about the invoice"). | [SEARCH.md](docs/features/SEARCH.md) |
| **"What did I miss" digest** | The signature feature. A digest of what arrived while your screen was locked, a Focus was on, or you were presenting — shown once when you're back, dismissible, never nagging. | [MISSED_DIGEST.md](docs/features/MISSED_DIGEST.md) |
| **Privacy controls** | Per-app retention (24h / 7d / 30d / forever / never), an exclusion list with sensible defaults, **automatic 2FA/OTP code redaction — on by default**, pause capture, panic wipe. | [PRIVACY_CONTROLS.md](docs/features/PRIVACY_CONTROLS.md) |
| **Actions** | Click to open the source app or deep link when resolvable; copy text; delete items; select-and-export. | [ACTIONS.md](docs/features/ACTIONS.md) |
| **Rules** | Highlight keywords, pin VIP senders to the top, mute noisy apps in the timeline. **Visual triage only** — rules do not change what macOS delivers. | [RULES.md](docs/features/RULES.md) |
| **Onboarding** | A careful Full Disk Access flow that explains exactly why the permission is needed, what is read, and what is never read; a graceful degraded mode until it's granted. | [PERMISSIONS_PRIVACY.md](docs/features/PERMISSIONS_PRIVACY.md) |
| **Foundation** | Zero telemetry, no account, local-only by default; menu bar unread badge; global hotkey (⌃⌥N); launch at login. | [ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md) |

### v1.x (planned)

Notification analytics · Snooze/resurface · CSV/JSON export, Shortcuts actions and URL scheme · Encrypted multi-Mac sync via CloudKit (opt-in) · Saved searches and smart folders · Widgets. See [ROADMAP.md](docs/reference/ROADMAP.md).

## Free, open source, no catch

Backglance is **fully free** and licensed under the **GPL-3.0**. There is no paid version, no Pro tier, no license key, no trial, no account, and no donation prompts in the app.

- The **official binary** on [GitHub Releases](https://github.com/backglance/backglance/releases) is Developer ID signed and notarized by Apple, and free to download.
- **Building from source** is equally supported and documented; you get the same app.
- It is **not on the Mac App Store** because it needs Full Disk Access, which the App Sandbox does not allow. See [FAQ.md](docs/reference/FAQ.md#why-isnt-it-on-the-mac-app-store).

Why free forever? Because it's the honest fit for a small painkiller utility, and because it removes the category risk's sting: nothing here needs to be protected, sold, or shut down.

## Privacy guarantees

> 🔒 **Security:** These are design guarantees, and the code is open so you can check them.

- **Local-only.** The archive is a SQLite file in `~/Library/Application Support/Backglance/`. Nothing is uploaded anywhere.
- **Zero telemetry, no crash reporting services, no account.**
- **The only network access is the Sparkle updater**, and you can turn it off. With updates disabled, Backglance makes no network connections at all.
- **What it reads:** the Notification Center store (and, for Focus detection, the DoNotDisturb assertion files). Nothing else. See [PERMISSIONS_PRIVACY.md](docs/features/PERMISSIONS_PRIVACY.md#what-backglance-reads-and-what-it-never-touches).
- **2FA/OTP codes are redacted by default** before they ever touch disk. See [PRIVACY_CONTROLS.md](docs/features/PRIVACY_CONTROLS.md).
- **CloudKit sync (v1.x) is opt-in and off by default**, and encrypts notification content end-to-end.

Full threat model: [SECURITY.md](docs/security/SECURITY.md).

## Tech stack

| Layer | Choice | Version |
|---|---|---|
| Language | Swift | 5.10+ (language mode 5, Swift 6 toolchain) |
| UI | SwiftUI (timeline, settings, onboarding) + AppKit (menu bar item, popover, hotkey, windows) | macOS 14 SDK+ |
| Storage | SQLite via [GRDB.swift](https://github.com/groue/GRDB.swift) with FTS5 | GRDB 7.x |
| Search | FTS5 + Levenshtein fuzzy matching; optional semantic search with Apple `NLEmbedding` (on-device) | — |
| Updates | [Sparkle 2](https://sparkle-project.org) (EdDSA-signed appcast on GitHub Pages) | 2.x |
| Distribution | GitHub Releases (signed + notarized) and Homebrew cask | — |
| Build | Xcode 16.2+ (26.x recommended) | — |
| Minimum macOS | 14.0 (Sonoma) | — |

Details and rationale: [TECH_STACK.md](docs/architecture/TECH_STACK.md).

## Quick start

### Option A — Download the notarized app

1. Download the latest `Backglance-x.y.z.dmg` (or `.zip`) from [Releases](https://github.com/backglance/backglance/releases/latest), or:
   ```bash
   brew install --cask backglance/tap/backglance
   ```
2. Move Backglance to `/Applications` and open it. It lives in the menu bar (there is no Dock icon).
3. Follow the onboarding to grant **Full Disk Access** (System Settings ▸ Privacy & Security ▸ Full Disk Access). Backglance explains why before it asks, and works in a read-only degraded mode until you do.
4. Press **⌃⌥N** or click the menu bar icon. Whatever the system store still held is imported; from now on everything is archived.

### Option B — Build from source

Prerequisites: macOS 14+, Xcode 16.2 or newer (26.x recommended).

```bash
git clone https://github.com/backglance/backglance.git
cd backglance
Scripts/bootstrap.sh                # checks Xcode, resolves packages, installs git hooks
open Backglance.xcodeproj           # or:
xcodebuild -scheme Backglance -configuration Debug build
```

Run the `Backglance` scheme, then grant Full Disk Access to *that* built binary (FDA is tied to the binary's path — a rebuilt or moved debug build may need re-granting). Details, fixtures, and troubleshooting: [SETUP_GUIDE.md](docs/getting-started/SETUP_GUIDE.md) and [QUICK_START.md](docs/getting-started/QUICK_START.md).

Verify capture in ten seconds:

```bash
osascript -e 'display notification "hello from the terminal" with title "Backglance test"'
```

It should appear in the popover within a few seconds.

## macOS compatibility

| macOS | Codename | Status | Store adapter | Notes |
|---|---|---|---|---|
| 14 (Sonoma) | Sonoma | ✅ Supported | `StoreAdapterV14` | Minimum deployment target. Intel + Apple silicon |
| 15 (Sequoia) | Sequoia | ✅ Supported | `StoreAdapterV15` | Intel + Apple silicon |
| 26 (Tahoe) | Tahoe | ✅ Supported (primary dev target) | `StoreAdapterV26` | Last macOS with Intel support (best-effort) |
| 27 (beta) | — | 🧪 Best-effort during beta | fingerprint check → V26 fallback or degraded mode | Apple silicon only. Adapter finalized at GM |
| ≤ 13 | Ventura and earlier | ❌ Not supported | — | Below deployment target |

Apple silicon is the primary platform. Intel is best-effort on macOS 14/15/26; macOS 27 drops Intel Macs entirely. When a macOS release changes the store format, Backglance detects it, pauses capture, keeps your archive intact, and a hotfix ships with only the adapter change — see the [OS compatibility playbook](docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md).

## How it works (in one diagram)

```
 Apple's Notification Center store (undocumented, needs Full Disk Access)
 ~/Library/Group Containers/group.com.apple.usernoted/db2/db
              │  read-only snapshot, poll 15 s + file-change watch
              ▼
 ┌────────────────────────┐   ⚠️ fragile boundary: schema fingerprint → versioned adapter
 │  BackglanceCapture     │   StoreAdapterV14 / V15 / V26 · RecordParser · Enrichment
 └───────────┬────────────┘
             │ ParsedNotification (OTP redacted in memory, exclusions applied)
             ▼
 ┌────────────────────────┐
 │  BackglanceCore        │   Archive (GRDB/SQLite, FTS5) · Retention · Rules · Digest
 └───────────┬────────────┘
             ▼
 ┌────────────────────────┐   ┌────────────────────────┐
 │  BackglanceSearch      │   │  BackglanceUI + app    │  menu bar popover · full window
 │  FTS5 · fuzzy · NL     │   │  SwiftUI + AppKit      │  digest · settings · onboarding
 └────────────────────────┘   └────────────────────────┘
```

Full picture: [ARCHITECTURE.md](docs/architecture/ARCHITECTURE.md).

## Project structure

```
backglance/
├── Backglance.xcodeproj
├── Backglance/               # app target: AppKit shell (status item, hotkey, windows) + SwiftUI scenes
├── Packages/
│   ├── BackglanceCore/       # models, archive (GRDB), migrations, retention, redaction, rules, digest
│   ├── BackglanceCapture/    # store locator/watcher, schema fingerprint, adapters, parser, enrichment
│   ├── BackglanceSearch/     # FTS5 index, query parser, fuzzy matcher, semantic index, hybrid search
│   └── BackglanceUI/         # SwiftUI views shared by popover, window, and (v1.x) widgets
├── Widgets/                  # v1.x WidgetKit extension
├── Tests/                    # unit, integration, UI tests
│   └── Fixtures/SystemStore/ # SYNTHETIC store fixtures per macOS version (never real data)
├── Scripts/                  # bootstrap, build, sign & notarize, appcast, cask bump, fixtures
├── .github/workflows/        # ci.yml, fixtures.yml, release.yml, cask-bump.yml
└── docs/                     # this documentation set
```

## Screenshots

> ℹ️ **Info:** Screenshots are not taken yet — the v1.0 UI is still moving. The table below is the planned set; each image lands at the listed path in `docs/assets/` and this section is replaced with the real images before the first release.

| Planned screenshot | File | Shows |
|---|---|---|
| Menu bar timeline | `docs/assets/screenshot-popover.png` | The popover, notifications grouped by day, unread divider |
| "What did I miss" digest | `docs/assets/screenshot-digest.png` | The digest shown after unlocking, grouped by app |
| Search | `docs/assets/screenshot-search.png` | A query with app and date filters and highlighted matches |
| Privacy settings | `docs/assets/screenshot-privacy.png` | Per-app retention, exclusion list, OTP redaction toggle |
| Full timeline window | `docs/assets/screenshot-window.png` | Detailed view, sidebar, keyboard selection |
| Onboarding | `docs/assets/screenshot-onboarding.png` | The Full Disk Access explanation screen |

A short screen recording of capture → dismiss → find it again in Backglance will accompany the v1.0 release notes.

## Documentation

**Getting started**
- [Quick start](docs/getting-started/QUICK_START.md) · [Setup guide](docs/getting-started/SETUP_GUIDE.md) · [Development guide](docs/getting-started/DEVELOPMENT_GUIDE.md)

**Architecture**
- [Architecture](docs/architecture/ARCHITECTURE.md) · [Tech stack](docs/architecture/TECH_STACK.md) · [Database schema](docs/architecture/DATABASE_SCHEMA.md) · [OS compatibility playbook](docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md)
- [API & automation surface](docs/api/API_DOCUMENTATION.md)

**Features**
- [Permissions & privacy (Full Disk Access)](docs/features/PERMISSIONS_PRIVACY.md) · [Capture](docs/features/CAPTURE.md) · [Timeline](docs/features/TIMELINE.md) · [Search](docs/features/SEARCH.md) · [Missed digest](docs/features/MISSED_DIGEST.md) · [Privacy controls](docs/features/PRIVACY_CONTROLS.md) · [Actions](docs/features/ACTIONS.md) · [Rules](docs/features/RULES.md)
- v1.x: [Analytics](docs/features/ANALYTICS.md) · [Snooze/resurface](docs/features/SNOOZE_RESURFACE.md) · [Export & automation](docs/features/EXPORT_AUTOMATION.md) · [CloudKit sync](docs/features/CLOUDKIT_SYNC.md) · [Saved searches](docs/features/SAVED_SEARCHES.md) · [Widgets](docs/features/WIDGETS.md)

**Deployment & operations**
- [Deployment guide](docs/deployment/DEPLOYMENT_GUIDE.md) · [Packaging & notarization](docs/deployment/PACKAGING_NOTARIZATION.md) · [CI/CD](docs/deployment/CI_CD.md) · [Performance guide](docs/deployment/PERFORMANCE_GUIDE.md)
- [Monitoring & logging](docs/operations/MONITORING_LOGGING.md) · [Maintenance](docs/operations/MAINTENANCE.md) · [Troubleshooting](docs/operations/TROUBLESHOOTING.md)

**Security, legal, testing**
- [Security & threat model](docs/security/SECURITY.md) · [Legal & compliance](docs/security/LEGAL_COMPLIANCE.md) · [Testing](docs/testing/TESTING.md)

**Project**
- [Contributing](docs/contributing/CONTRIBUTING.md) · [FAQ](docs/reference/FAQ.md) · [Roadmap](docs/reference/ROADMAP.md) · [Cost estimation](docs/reference/COST_ESTIMATION.md) · [Internationalization](docs/reference/INTERNATIONALIZATION.md) · [Accessibility](docs/reference/ACCESSIBILITY.md)
- [Changelog](CHANGELOG.md)

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](docs/contributing/CONTRIBUTING.md). One rule worth knowing up front: any change to the store adapter layer must come with fixture coverage, because that layer is the only part of Backglance that depends on something Apple doesn't document.

Backglance is a technical sibling of [PasteShelf](https://github.com/pasteshelf/pasteshelf) (it reuses the same search architecture) but a standalone project and brand.

## License

Backglance is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License v3.0**. See [LICENSE](LICENSE). Copyright (C) 2026 the Backglance authors.

The GPL covers the code, not the name: the "Backglance" name and icon identify the official builds — see the trademark note in [LEGAL_COMPLIANCE.md](docs/security/LEGAL_COMPLIANCE.md).

## Related Documentation

- [CHANGELOG.md](CHANGELOG.md)
- [docs/reference/FAQ.md](docs/reference/FAQ.md)
