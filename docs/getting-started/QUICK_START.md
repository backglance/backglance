# Quick Start

Last Updated: 2026-08-18

This is the short path from a clean checkout to a running debug build of Backglance, written for developers who already know Xcode and the command line. It skips explanations wherever it can; every step here has a longer version in [SETUP_GUIDE.md](./SETUP_GUIDE.md), and the conventions you will need once you start editing code are in [DEVELOPMENT_GUIDE.md](./DEVELOPMENT_GUIDE.md).

## Table of Contents

- [Just want the app?](#just-want-the-app)
- [Prerequisites](#prerequisites)
- [Clone, bootstrap, build](#clone-bootstrap-build)
- [Grant Full Disk Access to the debug build](#grant-full-disk-access-to-the-debug-build)
- [Verify capture works](#verify-capture-works)
- [Run the tests](#run-the-tests)
- [Where the archive lives, and how to reset it](#where-the-archive-lives-and-how-to-reset-it)
- [Run against a fixture instead of the live store](#run-against-a-fixture-instead-of-the-live-store)
- [Useful environment variables](#useful-environment-variables)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Just want the app?

You do not need Xcode to use Backglance. Download the signed and notarized build from [GitHub Releases](https://github.com/backglance/backglance/releases) or run `brew install --cask backglance/tap/backglance`, then grant Full Disk Access when the onboarding asks for it. Installation and first-run details are in the [README](../../README.md); the rest of this page is about building from source.

## Prerequisites

macOS 14+ dev machine, Xcode 16.2 or newer (Xcode 26.x recommended; the docs are written against Xcode 26.2 on macOS 26.5), Command Line Tools installed (`xcode-select --install`), and an Apple ID added to Xcode so automatic signing can use your Personal Team. That is all. `xcbeautify`, `swiftlint`, `swiftformat`, `create-dmg`, and `gh` are optional and are covered in the [Setup Guide](./SETUP_GUIDE.md#prerequisites).

```bash
xcodebuild -version        # Xcode 26.2 (or at least 16.2)
sw_vers -productVersion    # 14.0 or newer
```

## Clone, bootstrap, build

```bash
git clone https://github.com/backglance/backglance.git
cd backglance
Scripts/bootstrap.sh
```

`bootstrap.sh` checks the Xcode version, resolves the Swift packages (GRDB.swift 7.x, Sparkle 2.7.x), installs the git hooks, and writes `Config/Local.xcconfig` with your `DEVELOPMENT_TEAM`. It is idempotent; run it again after pulling if the package graph changed. Then either open the project in Xcode and press ⌘R, or build from the terminal:

```bash
open Backglance.xcodeproj
# or
xcodebuild -scheme Backglance -configuration Debug build
```

The debug build is written under Xcode's DerivedData directory. Find it with:

```bash
Scripts/grant_fda_hint.sh
# prints e.g.
# Built app: /Users/you/Library/Developer/Xcode/DerivedData/Backglance-abcdef/Build/Products/Debug/Backglance.app
```

Launch it with `open <that path>` or from Xcode. Backglance is an `LSUIElement` app: no Dock icon, just a menu bar item. The default hotkey ⌃⌥N toggles the popover.

## Grant Full Disk Access to the debug build

Backglance reads Apple's Notification Center database (the system store, under `~/Library/Group Containers/group.com.apple.usernoted/`), which requires Full Disk Access (FDA). Without it, capture starts in `.degraded(.noFullDiskAccess)` and the popover shows a banner telling you so.

1. Open **System Settings ▸ Privacy & Security ▸ Full Disk Access** (or run `Scripts/grant_fda_hint.sh`, which opens that pane and prints the binary path).
2. Click **+**, navigate to the DerivedData path printed above, and add `Backglance.app`.
3. Quit and relaunch the debug build. The status should change to `.running` within one poll interval (15 s).

> ⚠️ **Warning:** FDA is granted **per binary path**, not per bundle identifier. If DerivedData moves (new checkout, `rm -rf DerivedData`, a different scheme or configuration folder), macOS treats the rebuilt app as a different program and you have to add it again. In practice: if capture is degraded after a clean build, check the FDA list first, and remove stale entries pointing at paths that no longer exist. Rebuilds into the *same* path usually keep the grant, but a code-signature change (different team) can also invalidate it.

> ℹ️ **Info:** CI runners cannot be granted FDA, so nothing on GitHub Actions ever reads a real store. The CI path is fixture tests: synthetic stores under `Tests/Fixtures/SystemStore/` opened via `BACKGLANCE_STORE_PATH`. That is also why fixture coverage is required for any adapter change (see the [Development Guide](./DEVELOPMENT_GUIDE.md#code-review-checklist)).

## Verify capture works

One screen, one command. With the debug build running and FDA granted, send yourself a notification:

```bash
osascript -e 'display notification "hello" with title "Backglance test"'
```

Open the popover (⌃⌥N or click the menu bar icon). Within one poll interval you should see a notification titled "Backglance test" from Script Editor (bundle `com.apple.ScriptEditor2`, or `osascript` on some systems). If it does not appear:

```bash
log stream --predicate 'subsystem == "app.backglance.Backglance"' --level debug
```

Look for `CaptureEngine` status lines. `degraded(noFullDiskAccess)` means the FDA grant did not take (see the warning above); `degraded(storeNotFound)` means `StoreLocation.current()` could not find the store; `degraded(unknownSchema)` means the fingerprint matched no adapter, which is expected on a beta macOS. All three are covered in [SETUP_GUIDE.md](./SETUP_GUIDE.md#common-setup-issues).

## Run the tests

```bash
xcodebuild test -scheme Backglance -testPlan Backglance
```

This runs the four test bundles (`BackglanceCoreTests`, `BackglanceCaptureTests`, `BackglanceSearchTests`, `BackglanceUITests`) through `Backglance.xctestplan`. Capture tests never touch your live store; they open the fixtures under `Tests/Fixtures/SystemStore/macOS14/`, `macOS15/`, and `macOS26/`. Nothing in the test plan needs FDA. Pipe through `xcbeautify` if you have it installed:

```bash
xcodebuild test -scheme Backglance -testPlan Backglance 2>&1 | xcbeautify
```

To run just one package's tests, use `-only-testing:BackglanceCaptureTests` and friends.

## Where the archive lives, and how to reset it

Backglance's own database — the **archive** — is a single SQLite file:

```
~/Library/Application Support/Backglance/archive.sqlite   (+ -wal, -shm)
~/Library/Application Support/Backglance/icons/            # cached app icons
~/Library/Application Support/Backglance/tmp/              # read-only store snapshots
~/Library/Logs/Backglance/backglance.log                    # rotating file log
```

Debug and release builds share this path unless you override it (see below), so a debug build will happily read the archive your installed copy created. To start from scratch, quit Backglance and delete the directory:

```bash
osascript -e 'quit app id "app.backglance.Backglance"'
rm -rf ~/Library/Application\ Support/Backglance
```

Relaunching recreates an empty archive and re-runs the initial import from whatever the system store still holds. In-app, **Settings ▸ Privacy ▸ Wipe archive…** does the same thing with secure delete and a typed confirmation.

> 💡 **Tip:** DEBUG builds set `eraseDatabaseOnSchemaChange = true` on the GRDB migrator, so if you edit a migration while iterating, the archive is silently rebuilt on next launch. Do not be surprised when your test data disappears — that is the flag doing its job. Release builds never do this.

## Run against a fixture instead of the live store

If you are working on the capture layer, or you simply do not want to grant FDA to a debug build, point Backglance at a fixture. `BACKGLANCE_STORE_PATH` overrides `StoreLocation.current()` — **DEBUG builds only**; release builds ignore it.

```bash
# `open` launches through LaunchServices, so shell-exported variables are NOT
# inherited; pass them with --env instead.
open --env BACKGLANCE_STORE_PATH="$PWD/Tests/Fixtures/SystemStore/macOS26/store.db" \
     --env BACKGLANCE_ARCHIVE_PATH="$PWD/.local/archive.sqlite" \
     ~/Library/Developer/Xcode/DerivedData/Backglance-*/Build/Products/Debug/Backglance.app
```

In Xcode, set the same variables under **Product ▸ Scheme ▸ Edit Scheme… ▸ Run ▸ Arguments ▸ Environment Variables**. Each fixture directory contains `store.db`, `manifest.json` (the fingerprint the fixture is meant to match) and `expected.json` (what a correct adapter must parse out of it). Fixtures are synthetic; there is no real notification content anywhere in the repository. Making a new one is `Scripts/make_fixture.sh`, checking one is `Scripts/verify_fixture.sh`; both are documented in [SETUP_GUIDE.md](./SETUP_GUIDE.md#fixture-setup).

## Useful environment variables

| Variable | Effect | Builds |
|---|---|---|
| `BACKGLANCE_STORE_PATH` | Read the system store from this file instead of `~/Library/Group Containers/group.com.apple.usernoted/db2/db` | DEBUG only |
| `BACKGLANCE_ARCHIVE_PATH` | Put the archive at this path instead of `~/Library/Application Support/Backglance/archive.sqlite` | DEBUG and Release |
| `BACKGLANCE_LOG_LEVEL` | `debug`, `info` (default), `error` — controls both `os.Logger` verbosity and the file log | DEBUG and Release |
| `BACKGLANCE_DISABLE_UPDATER=1` | Do not start the Sparkle updater at launch (it is already off in DEBUG when no `SUPublicEDKey` is present) | DEBUG and Release |

## Next Steps

- Read [DEVELOPMENT_GUIDE.md](./DEVELOPMENT_GUIDE.md) before opening a pull request: it covers naming, the SwiftLint/SwiftFormat setup, the branch and commit conventions, and the review checklist.
- If anything in this page did not work, the longer walkthrough with troubleshooting is [SETUP_GUIDE.md](./SETUP_GUIDE.md).
- To understand what the capture layer actually does with the system store, and why it is marked ⚠️ throughout the docs, read [CAPTURE.md](../features/CAPTURE.md) and the [OS Compatibility Playbook](../architecture/OS_COMPATIBILITY_PLAYBOOK.md).

## Related Documentation

- [README](../../README.md) — what Backglance is, downloads, first run
- [Setup Guide](./SETUP_GUIDE.md) — full prerequisites, signing, FDA, fixtures, troubleshooting
- [Development Guide](./DEVELOPMENT_GUIDE.md) — project layout, style, git workflow, tests, review checklist
- [Architecture](../architecture/ARCHITECTURE.md) — how the four packages fit together
- [Capture](../features/CAPTURE.md) — the store, adapters, fingerprints, and degraded modes
- [Testing](../testing/TESTING.md) — test plan, fixture strategy, CI matrix
- [Troubleshooting](../operations/TROUBLESHOOTING.md) — user-facing problems and fixes
- [Contributing](../contributing/CONTRIBUTING.md) — how to send a change
