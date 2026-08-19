# Setup Guide

Last Updated: 2026-08-18

This guide walks through setting up a development environment for Backglance from nothing: installing the toolchain, cloning and building the project, configuring local code signing, granting Full Disk Access to a debug build so it can actually read the system store, working with fixtures instead of the live store, running the app locally, verifying that capture works, and fixing the setup problems that come up most often. If you have done all of this before and only need the commands, [QUICK_START.md](./QUICK_START.md) is the condensed version. If you only want to *use* Backglance, download the signed build described in the [README](../../README.md); nothing on this page is needed.

## Table of Contents

- [Prerequisites](#prerequisites)
  - [Required](#required)
  - [Optional tools](#optional-tools)
- [Clone and build from source](#clone-and-build-from-source)
  - [Building in Xcode](#building-in-xcode)
  - [Building from the command line](#building-from-the-command-line)
- [What Scripts/bootstrap.sh does](#what-scriptsbootstrapsh-does)
- [Signing configuration for local development](#signing-configuration-for-local-development)
- [Granting Full Disk Access to a dev build](#granting-full-disk-access-to-a-dev-build)
  - [Why the DerivedData path matters](#why-the-deriveddata-path-matters)
  - [Step by step](#step-by-step)
  - [Scripts/grant_fda_hint.sh](#scriptsgrant_fda_hintsh)
  - [Revoking and re-granting](#revoking-and-re-granting)
- [Fixture setup](#fixture-setup)
  - [Fixture layout](#fixture-layout)
  - [Generating a fixture](#generating-a-fixture)
  - [Verifying a fixture](#verifying-a-fixture)
  - [Running against a fixture](#running-against-a-fixture)
- [Running locally](#running-locally)
  - [Scheme and configurations](#scheme-and-configurations)
  - [Environment variables](#environment-variables)
- [Verifying capture works](#verifying-capture-works)
- [Common setup issues](#common-setup-issues)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Prerequisites

### Required

| Requirement | Version | Notes |
|---|---|---|
| macOS on the development machine | 14.0 (Sonoma) or newer | Matches the deployment target. macOS 26 (Tahoe) is the primary development target and the version the docs assume. |
| Xcode | **16.2 minimum**, **26.x recommended** | The docs are written against Xcode 26.2 on macOS 26.5. Xcode 16.2 is the oldest version that ships a Swift 6 toolchain able to build the project in language mode 5 with the strict-concurrency settings we use. |
| Command Line Tools | Matching your Xcode | `xcode-select --install`, then `sudo xcode-select -s /Applications/Xcode.app`. Needed for `xcodebuild`, `git`, `sqlite3`, `codesign`, `notarytool`. |
| An Apple ID in Xcode | — | Only for automatic signing with your Personal Team. No paid developer program membership is needed to build and run locally. |
| Disk space | ~3 GB | Xcode DerivedData plus resolved packages. |

Check the versions before you start:

```bash
xcodebuild -version
# Xcode 26.2
# Build version 17C52

sw_vers -productVersion
# 26.5

xcode-select -p
# /Applications/Xcode.app/Contents/Developer
```

If `xcode-select -p` prints `/Library/Developer/CommandLineTools`, point it at the full Xcode installation with `sudo xcode-select -s /Applications/Xcode.app`; the standalone Command Line Tools cannot build an app target.

### Optional tools

None of these are required to build, run, or test. `bootstrap.sh` reports which ones are missing but does not install them.

| Tool | Used for | Install |
|---|---|---|
| `xcbeautify` | Readable `xcodebuild` output locally and in CI | `brew install xcbeautify` |
| `swiftlint` | Lint rules from `.swiftlint.yml`; run by the pre-commit hook if present | `brew install swiftlint` |
| `swiftformat` | Formatting per `.swiftformat`; run by the pre-commit hook if present | `brew install swiftformat` |
| `create-dmg` | Building the release disk image (`Scripts/build.sh --dmg`) | `brew install create-dmg` |
| `gh` | Creating releases, checking CI status, `Scripts/bump_cask.sh` | `brew install gh` |

```bash
brew install xcbeautify swiftlint swiftformat create-dmg gh
```

## Clone and build from source

```bash
git clone https://github.com/backglance/backglance.git
cd backglance
Scripts/bootstrap.sh
```

The repository is a single Xcode project (`Backglance.xcodeproj`) with one app target (`Backglance`) that depends on four local Swift packages under `Packages/`: `BackglanceCore`, `BackglanceCapture`, `BackglanceSearch`, and `BackglanceUI`. External dependencies (GRDB.swift 7.x and Sparkle 2.7.x) are resolved through Swift Package Manager. There is nothing to `pod install` or `carthage` and no submodules.

### Building in Xcode

1. `open Backglance.xcodeproj`
2. Wait for **Resolving Package Graph** in the activity bar to finish (first time only, a minute or two).
3. Select the **Backglance** scheme and **My Mac** as the destination.
4. Press ⌘B to build, ⌘R to build and run.

The first run shows the onboarding window because a fresh archive has no notifications and no FDA grant. You can dismiss it; the menu bar item is already there.

### Building from the command line

```bash
# Debug build into the default DerivedData location
xcodebuild -scheme Backglance -configuration Debug build

# Same, with readable output
xcodebuild -scheme Backglance -configuration Debug build 2>&1 | xcbeautify

# Release build into a local ./build directory (unsigned, not notarized)
xcodebuild -scheme Backglance -configuration Release \
  -derivedDataPath ./build build
```

`Scripts/build.sh` wraps the release invocation with the correct archive/export options and is what CI and `Scripts/sign_and_notarize.sh` call; see [DEPLOYMENT_GUIDE.md](../deployment/DEPLOYMENT_GUIDE.md) for the release path. For day-to-day work the plain `xcodebuild` above is enough.

To find the built app:

```bash
xcodebuild -scheme Backglance -configuration Debug -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2"/Backglance.app"}'
```

## What Scripts/bootstrap.sh does

`bootstrap.sh` is deliberately small and idempotent. Run it after cloning and again whenever `Package.resolved` changes. It does four things, in this order:

1. Verifies that the selected Xcode is at least 16.2.
2. Resolves Swift packages so the first Xcode open does not stall.
3. Installs the git hooks from `Scripts/hooks/` into `.git/hooks/`.
4. Creates `Config/Local.xcconfig` (git-ignored) with your `DEVELOPMENT_TEAM` if it does not exist yet — or, if this Mac has no development certificate, with an ad-hoc signing configuration that still builds. If the file already exists, it is left alone, but a `DEVELOPMENT_TEAM` that matches no certificate on this Mac is called out as a warning.

The full script:

```bash
#!/usr/bin/env bash
# Scripts/bootstrap.sh — one-time (idempotent) developer setup for Backglance.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIN_XCODE="16.2"
LOCAL_XCCONFIG="$REPO_ROOT/Config/Local.xcconfig"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Xcode version check ------------------------------------------------------
if ! command -v xcodebuild >/dev/null 2>&1; then
  fail "xcodebuild not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"
fi

XCODE_VERSION="$(xcodebuild -version | awk '/^Xcode/ {print $2}')"
# sort -V handles "16.2" vs "26.2" correctly; the lowest of (min, actual) must be min.
LOWEST="$(printf '%s\n%s\n' "$MIN_XCODE" "$XCODE_VERSION" | sort -V | head -n1)"
if [[ "$LOWEST" != "$MIN_XCODE" ]]; then
  fail "Xcode $XCODE_VERSION found; Backglance requires Xcode $MIN_XCODE or newer (26.x recommended)."
fi
info "Xcode $XCODE_VERSION"

# 2. Resolve Swift packages ---------------------------------------------------
info "Resolving Swift packages"
xcodebuild -resolvePackageDependencies \
  -project "$REPO_ROOT/Backglance.xcodeproj" \
  -scheme Backglance >/dev/null

# 3. Git hooks ------------------------------------------------------------------
if [[ -d "$REPO_ROOT/.git" ]]; then
  info "Installing git hooks"
  for hook in "$REPO_ROOT"/Scripts/hooks/*; do
    name="$(basename "$hook")"
    ln -sf "../../Scripts/hooks/$name" "$REPO_ROOT/.git/hooks/$name"
    chmod +x "$hook"
  done
else
  warn "Not a git checkout; skipping hooks."
fi

# 4. Local signing config -----------------------------------------------------
#
# The Team ID is the certificate's OU field, *not* the ten characters in the
# common name: "Apple Development: Jane Doe (AB12CD34EF)" names the developer,
# while the team the certificate belongs to is OU. Signing against the wrong one
# fails with `No signing certificate "Mac Development" found`, which reads like a
# missing certificate but is a mismatched team.
discover_team() {
  local valid_identities cert_name line pem subject common_name team
  valid_identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  [[ -z "$valid_identities" ]] && return 1

  for cert_name in "Apple Development" "Mac Development" "Developer ID Application"; do
    pem=""
    while IFS= read -r line; do
      pem+="$line"$'\n'
      [[ "$line" == "-----END CERTIFICATE-----" ]] || continue

      subject="$(printf '%s' "$pem" | openssl x509 -noout -subject 2>/dev/null || true)"
      pem=""
      common_name="$(sed -n 's/.*CN *= *\([^,\/]*\).*/\1/p' <<<"$subject")"
      team="$(sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' <<<"$subject")"

      # Only certificates the keychain reports as valid *and* usable for signing.
      [[ -n "$team" && -n "$common_name" && "$valid_identities" == *"$common_name"* ]] || continue
      printf '%s' "$team"
      return 0
    done < <(security find-certificate -a -c "$cert_name" -p 2>/dev/null)
  done
  return 1
}

write_local_xcconfig() {
  mkdir -p "$(dirname "$LOCAL_XCCONFIG")"
  if [[ -n "${1:-}" ]]; then
    cat > "$LOCAL_XCCONFIG" <<EOF
// Local, git-ignored overrides. Created by Scripts/bootstrap.sh.
//
// $1 is this Mac's Team ID, read from the OU field of a valid development
// certificate. If you have more than one team, edit it here.
DEVELOPMENT_TEAM = $1
CODE_SIGN_STYLE = Automatic
EOF
    info "Wrote $LOCAL_XCCONFIG (DEVELOPMENT_TEAM = $1)"
    return
  fi

  cat > "$LOCAL_XCCONFIG" <<'EOF'
// Local, git-ignored overrides. Created by Scripts/bootstrap.sh.
//
// No valid development certificate was found on this Mac, so local builds are
// ad-hoc signed. They run, and capture works once you grant Full Disk Access —
// but Xcode disables the hardened runtime for an ad-hoc signature, and the
// signature changes on every build, so macOS asks for Full Disk Access again
// each time (Scripts/grant_fda_hint.sh prints the tccutil reset commands).
//
// To sign properly: sign in under Xcode ▸ Settings ▸ Accounts, then delete this
// file and re-run Scripts/bootstrap.sh.
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = -
DEVELOPMENT_TEAM =
PROVISIONING_PROFILE_SPECIFIER =
EOF
  warn "No development certificate found; wrote an ad-hoc signing config to Config/Local.xcconfig."
}

if [[ ! -f "$LOCAL_XCCONFIG" ]]; then
  write_local_xcconfig "$(discover_team || true)"
else
  info "Config/Local.xcconfig already exists; leaving it alone"

  # It is worth one check: a Team ID that matches no certificate on this Mac is
  # the most common reason a clean clone fails to build here.
  CONFIGURED_TEAM="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]\{10\}\).*/\1/p' "$LOCAL_XCCONFIG" | head -n1)"
  if [[ -n "${CONFIGURED_TEAM:-}" ]]; then
    DISCOVERED_TEAM="$(discover_team || true)"
    if [[ -n "${DISCOVERED_TEAM:-}" && "$DISCOVERED_TEAM" != "$CONFIGURED_TEAM" ]]; then
      warn "Config/Local.xcconfig sets DEVELOPMENT_TEAM = $CONFIGURED_TEAM, but this Mac's development certificate belongs to team $DISCOVERED_TEAM. Builds will fail with 'No signing certificate \"Mac Development\" found' until one of them changes."
    fi
  fi
fi

# 5. Optional tooling report ----------------------------------------------------
for tool in xcbeautify swiftlint swiftformat create-dmg gh; do
  if command -v "$tool" >/dev/null 2>&1; then
    info "found $tool"
  else
    warn "$tool not installed (optional; brew install $tool)"
  fi
done

info "Done. Next: open Backglance.xcodeproj, or run xcodebuild -scheme Backglance -configuration Debug build"
```

`Config/Local.xcconfig` is included by `Config/Debug.xcconfig` with `#include? "Local.xcconfig"`, so its absence is not an error — CI never has one — but without it Xcode will ask you to pick a team the first time you build.

## Signing configuration for local development

Local development uses **automatic signing with your Personal Team**. That is enough to build, run, debug, and grant Full Disk Access; nothing about the capture path depends on a Developer ID certificate.

- `CODE_SIGN_STYLE = Automatic` and `DEVELOPMENT_TEAM` come from `Config/Local.xcconfig` (see above). Do not put your team ID in the project file; that is what the local xcconfig is for.
- **Your Team ID is the certificate's `OU`, not the name in brackets.** `security find-identity -v -p codesigning` prints something like `Apple Development: Jane Doe (AB12CD34EF)`, and those ten characters identify *you*, not your team. The team is the `OU` field:

  ```bash
  security find-certificate -c "Apple Development" -p \
    | openssl x509 -noout -subject
  # subject=UID=…, CN=Apple Development: Jane Doe (AB12CD34EF), OU=9Z8Y7X6W5V, O=Jane Doe, C=US
  #                                                              ^^^^^^^^^^ this is DEVELOPMENT_TEAM
  ```

  Putting the bracketed value in `DEVELOPMENT_TEAM` produces a build error that sounds like a missing certificate but is a mismatched team: `No signing certificate "Mac Development" found: No "Mac Development" signing certificate matching team ID "…" with a private key was found.` `bootstrap.sh` reads the `OU`, and warns when an existing `Config/Local.xcconfig` names a team no certificate on this Mac belongs to.
- **No certificate at all is fine.** With no Apple ID configured, `bootstrap.sh` writes an ad-hoc configuration (`CODE_SIGN_STYLE = Manual`, `CODE_SIGN_IDENTITY = -`) and the app builds and runs. Two consequences: Xcode disables the hardened runtime for an ad-hoc signature, and the signature changes on every build, so macOS asks for Full Disk Access again each time. For a one-off build you can also skip signing entirely:

  ```bash
  xcodebuild -scheme Backglance -destination 'platform=macOS' build \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=
  ```

  That is enough to check that the code compiles — it is what CI does — but an unsigned build cannot hold a Full Disk Access grant, so it cannot capture anything.
- **Hardened Runtime stays on** in every configuration, including Debug. Backglance ships with the hardened runtime because notarization requires it, and we do not want debug builds to behave differently from release builds with respect to library loading or entitlements. The entitlements file `Backglance/Backglance.entitlements` contains no sandbox entitlement — Backglance is not sandboxed, because Full Disk Access is incompatible with App Sandbox — and no hardened-runtime exceptions such as `com.apple.security.cs.disable-library-validation`; if a build ever seems to need one, something is wrong with a dependency, not with the project.
- Release signing (Developer ID Application, notarization, stapling) is handled by `Scripts/sign_and_notarize.sh` and CI; you do not need it locally. See [PACKAGING_NOTARIZATION.md](../deployment/PACKAGING_NOTARIZATION.md).

To confirm what a debug build was signed with:

```bash
codesign -dv --verbose=2 \
  ~/Library/Developer/Xcode/DerivedData/Backglance-*/Build/Products/Debug/Backglance.app 2>&1 \
  | grep -E 'Identifier|TeamIdentifier|flags'
# Identifier=app.backglance.Backglance
# TeamIdentifier=TEAMID1234
# flags=0x10000(runtime)     <- hardened runtime
```

> ℹ️ **Info:** A Personal Team signature is fine for FDA. macOS ties the FDA grant to the code-signing identity and path of the binary, not to whether the certificate is Developer ID. What *does* matter is that the identity stays the same between builds; switching teams (for example between a Personal Team and an org team) invalidates the grant.

## Granting Full Disk Access to a dev build

Backglance reads Apple's Notification Center database — the **system store** at `~/Library/Group Containers/group.com.apple.usernoted/db2/db` — and that directory is protected by TCC. Any process that wants to read it needs **Full Disk Access (FDA)**. There is no entitlement or API request for FDA; the user has to add the app in System Settings. This applies to your debug build exactly as it applies to the shipped app.

Without FDA the app runs normally but `CaptureEngine` reports `.degraded(.noFullDiskAccess)`, the popover shows an explanatory banner, and nothing is captured. Everything else — the archive, search, settings, rules — works, which is why the fixture path exists for development that does not need the live store.

### Why the DerivedData path matters

TCC records an FDA grant against a specific executable: its code-signing identity **and** its on-disk path. Xcode puts debug builds in a DerivedData directory whose name includes a hash of the project path, for example:

```
~/Library/Developer/Xcode/DerivedData/Backglance-fdhtqmxwbeqhkfclgqjbxjbmvfoq/Build/Products/Debug/Backglance.app
```

Consequences:

- Rebuilding into the same path (normal ⌘R iteration) keeps the grant.
- Cloning the repo somewhere else, deleting DerivedData, changing the DerivedData location in Xcode preferences, or building with `-derivedDataPath ./build` produces a *different* path, and macOS treats it as a different app. You have to grant FDA again, and the old entry becomes a stale row in the FDA list.
- Building with a different signing team also invalidates the grant even at the same path.
- The shipped `/Applications/Backglance.app` and your debug build are separate grants. Granting one does not grant the other.

> ⚠️ **Warning:** "I granted FDA and capture is still degraded" is almost always a path mismatch. Check `Scripts/grant_fda_hint.sh` output against the FDA list before debugging anything else.

### Step by step

1. Build the debug app once (⌘B or `xcodebuild -scheme Backglance -configuration Debug build`) so the bundle exists on disk.
2. Run `Scripts/grant_fda_hint.sh`. It prints the exact path of the built app and opens the Full Disk Access pane.

   `[screenshot: Terminal showing grant_fda_hint.sh output with the DerivedData path]`

3. In **System Settings ▸ Privacy & Security ▸ Full Disk Access**, click the **+** button. Authenticate with Touch ID or your password.

   `[screenshot: Full Disk Access pane with the + button highlighted]`

4. In the file chooser, press ⇧⌘G, paste the path printed in step 2, and choose `Backglance.app`.

   `[screenshot: Go to Folder sheet with the DerivedData path pasted]`

5. Make sure the toggle next to the new **Backglance** entry is on. If there is already a **Backglance** row for the installed release copy in `/Applications` or for an older DerivedData path, leave it; multiple rows are normal.

   `[screenshot: FDA list with two Backglance rows, one for /Applications and one for DerivedData]`

6. Quit and relaunch the debug build. TCC changes apply on next launch, not live. Within one poll cycle (15 s) the menu bar icon should lose its "degraded" state, and `log stream` (below) shows `capture status -> running`.

### Scripts/grant_fda_hint.sh

```bash
#!/usr/bin/env bash
# Scripts/grant_fda_hint.sh — print the path of the built debug app and open the
# Full Disk Access pane so it can be added. FDA is per binary path; run this
# again whenever DerivedData moves.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-Debug}"

APP_PATH="$(xcodebuild -project "$REPO_ROOT/Backglance.xcodeproj" \
  -scheme Backglance -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')/Backglance.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: $APP_PATH does not exist yet. Build first:" >&2
  echo "  xcodebuild -scheme Backglance -configuration $CONFIGURATION build" >&2
  exit 1
fi

echo "Built app: $APP_PATH"
echo
echo "Add this bundle under System Settings > Privacy & Security > Full Disk Access,"
echo "then quit and relaunch Backglance. Press Cmd-Shift-G in the file chooser and paste:"
echo
echo "  $(dirname "$APP_PATH")"
echo

# Copy the directory to the clipboard for the Go-to-Folder sheet.
printf '%s' "$(dirname "$APP_PATH")" | pbcopy && echo "(directory copied to clipboard)"

open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
```

### Revoking and re-granting

To reset FDA for every binary with Backglance's bundle identifier (useful when the list is full of stale DerivedData rows):

```bash
tccutil reset SystemPolicyAllFiles app.backglance.Backglance
```

Then re-add the current build. `tccutil` cannot *grant* access, only reset it; there is no supported way to grant FDA from a script, which is also why CI cannot have it.

> ℹ️ **Info:** GitHub Actions runners (and any headless macOS) cannot be granted FDA. Nothing that runs in CI reads a real store. All capture-layer verification in CI goes through fixtures; see [Fixture setup](#fixture-setup) and [CI_CD.md](../deployment/CI_CD.md).

## Fixture setup

A **fixture** is a synthetic copy of a system store: a SQLite file with the same tables and column layout as Apple's `usernoted` database for one macOS version, filled with generated data. Fixtures let the capture layer be tested without FDA, without a real store, and without any real notification content in the repository. They are also the mechanism by which each adapter is pinned to a schema fingerprint.

> ⚠️ **Warning:** The system store is undocumented. The layout the fixtures reproduce is what we have observed, not an API. Column names may change in any macOS release; the fingerprint + adapter + fixture strategy exists for that reason. When a new macOS breaks a fixture, the fixture is wrong, not the OS — regenerate it and, if the schema changed, add an adapter. The process is in [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md).

### Fixture layout

```
Tests/Fixtures/SystemStore/
├── macOS14/
│   ├── store.db          # synthetic usernoted-style database (WAL checkpointed, single file)
│   ├── manifest.json     # fingerprint this fixture must match + generator parameters
│   └── expected.json     # what a correct adapter must parse out of store.db
├── macOS15/
│   └── (same three files)
└── macOS26/
    └── (same three files)
```

`manifest.json` for one fixture looks like this:

```json
{
  "fixtureVersion": 3,
  "os": { "major": 26, "minor": 5, "patch": 0 },
  "adapterID": "StoreAdapterV26",
  "fingerprint": {
    "schemaHash": "6f1e2c1c0d8a4b7e9c3f5a2b1d4e6f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e",
    "dbinfoVersion": "17"
  },
  "generator": {
    "seed": 20260817,
    "recordCount": 250,
    "apps": ["com.apple.MobileSMS", "com.apple.mail", "com.tinyspeck.slackmacgap", "com.example.demo"],
    "otpRecords": 12,
    "presentedFalseRatio": 0.2
  },
  "generatedAt": "2026-08-17T09:00:00Z"
}
```

`expected.json` lists the `ParsedNotification` values (bundle ID, UUID, title, body, delivered date, presented flag, attachment metadata) that `RecordParser` must produce for every record, plus the final `StoreCursor`. Because generation is seeded, the same manifest always yields the same `store.db` and the same `expected.json`; if they diverge, `verify_fixture.sh` fails.

All text in fixtures is generated: sender names come from a word list, bodies are lorem-style sentences, and OTP-shaped bodies use `String(format: "%06d", rng.next() % 1_000_000)` from a seeded generator so that redaction has something to match without any realistic code appearing in the repository.

### Generating a fixture

`Scripts/make_fixture.sh` builds and runs the `FixtureGenerator` executable target in `BackglanceCapture` and writes the three files:

```bash
# Regenerate the macOS 26 fixture with the parameters already in its manifest
Scripts/make_fixture.sh --os 26

# Create a fixture for a new major version, starting from the V26 layout
Scripts/make_fixture.sh --os 27 --from 26 --seed 20260817 --records 250

# Print help
Scripts/make_fixture.sh --help
```

The script itself:

```bash
#!/usr/bin/env bash
# Scripts/make_fixture.sh — (re)generate a synthetic system-store fixture.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS_MAJOR=""; FROM=""; SEED=""; RECORDS=""

usage() {
  cat <<'EOF'
usage: make_fixture.sh --os <major> [--from <major>] [--seed <int>] [--records <n>]
  --os       target macOS major version (14, 15, 26, ...)
  --from     copy layout from an existing fixture's manifest (default: --os)
  --seed     RNG seed (default: value from manifest, else 20260817)
  --records  number of records to generate (default: from manifest, else 250)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --os) OS_MAJOR="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    --records) RECORDS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$OS_MAJOR" ]] || { usage; exit 2; }

OUT_DIR="$REPO_ROOT/Tests/Fixtures/SystemStore/macOS${OS_MAJOR}"
SRC_MANIFEST="$REPO_ROOT/Tests/Fixtures/SystemStore/macOS${FROM:-$OS_MAJOR}/manifest.json"
mkdir -p "$OUT_DIR"

# The generator lives in the BackglanceCapture package as an executable target.
swift run --package-path "$REPO_ROOT/Packages/BackglanceCapture" -c release FixtureGenerator \
  --os "$OS_MAJOR" \
  --manifest "$SRC_MANIFEST" \
  ${SEED:+--seed "$SEED"} \
  ${RECORDS:+--records "$RECORDS"} \
  --output "$OUT_DIR"

echo "Wrote $OUT_DIR/{store.db,manifest.json,expected.json}"
echo "Now run: Scripts/verify_fixture.sh --os $OS_MAJOR"
```

### Verifying a fixture

`Scripts/verify_fixture.sh --os 26` opens `store.db` read-only, computes the `StoreFingerprint`, checks it against `manifest.json`, resolves an adapter through `StoreAdapterRegistry`, parses every record, and diffs the result against `expected.json`. CI runs it for all three fixtures on every push (`.github/workflows/fixtures.yml`) and on the `macos-26` runner it additionally regenerates each fixture and fails if the output differs, which catches accidental non-determinism.

```bash
Scripts/verify_fixture.sh --os 26
# fingerprint  6f1e2c1c…  matches manifest        OK
# adapter      StoreAdapterV26                     OK
# probe        ok(recordCount: 250)                OK
# records      250 parsed, 250 expected, 0 diffs   OK
# cursor       recID 250 / 807 987 200.0           OK
```

### Running against a fixture

`BACKGLANCE_STORE_PATH` overrides `StoreLocation.current()` in **DEBUG builds only**. Point it at a fixture's `store.db` and the app behaves as if that were the live store, including the initial import, the cursor, and the adapter selection.

```bash
open --env BACKGLANCE_STORE_PATH="$PWD/Tests/Fixtures/SystemStore/macOS26/store.db" \
     --env BACKGLANCE_ARCHIVE_PATH="$PWD/.local/archive.sqlite" \
     "$(Scripts/grant_fda_hint.sh 2>/dev/null | awk '/^Built app:/{print $3}')"
```

Two things to know:

- Because the fixture never changes, `StoreWatcher` will do its initial import and then sit idle. That is fine for UI work; for watcher work, copy the fixture to a scratch location and append rows with `sqlite3` while the app is running.
- Use `BACKGLANCE_ARCHIVE_PATH` alongside it so fixture data does not land in your real archive. `.local/` is git-ignored for this purpose.

## Running locally

### Scheme and configurations

There is one scheme, **Backglance**, with two build configurations:

| Configuration | Purpose | Differences from Release |
|---|---|---|
| Debug | Local development, tests | `DEBUG` flag; `BACKGLANCE_STORE_PATH` honoured; `eraseDatabaseOnSchemaChange = true`; Sparkle updater not started (no `SUPublicEDKey`); log level defaults to `debug`; assertions on |
| Release | What ships | Store path is always the real one; migrations are additive and never erase; updater on unless disabled; log level `info` |

The test plan `Backglance.xctestplan` runs all four test bundles in Debug. Onboarding UI tests (`BackglanceUITests`) launch the app with `--uitest-reset` so they never touch a real archive.

### Environment variables

Set these in **Product ▸ Scheme ▸ Edit Scheme… ▸ Run ▸ Arguments ▸ Environment Variables** in Xcode, or pass them with `open --env` from the terminal (plain `VAR=value open …` does not work; LaunchServices does not inherit the shell environment).

| Variable | Values | Effect | Where honoured |
|---|---|---|---|
| `BACKGLANCE_STORE_PATH` | absolute path to a `store.db` | Overrides `StoreLocation.current()`. The app never opens this file for write; it snapshots it exactly like the live store. | DEBUG only |
| `BACKGLANCE_ARCHIVE_PATH` | absolute path | Overrides `~/Library/Application Support/Backglance/archive.sqlite`. Parent directory is created with `0700`, file with `0600`. Icons and tmp snapshots go next to it. | DEBUG and Release |
| `BACKGLANCE_LOG_LEVEL` | `debug` \| `info` \| `error` | Minimum level for both `os.Logger` and `~/Library/Logs/Backglance/backglance.log`. `debug` still never logs notification content. | DEBUG and Release |
| `BACKGLANCE_DISABLE_UPDATER` | `1` | Skips `SparkleUpdaterController` entirely. Useful when testing on a machine where you do not want an update prompt. Equivalent to the "Check for updates automatically" setting being off, but at process start. | DEBUG and Release |

Example Xcode scheme snippet (`Backglance.xcodeproj/xcshareddata/xcschemes/Backglance.xcscheme`, the relevant part):

```xml
<EnvironmentVariables>
   <EnvironmentVariable key="BACKGLANCE_LOG_LEVEL" value="debug" isEnabled="YES"/>
   <EnvironmentVariable key="BACKGLANCE_DISABLE_UPDATER" value="1" isEnabled="YES"/>
   <EnvironmentVariable key="BACKGLANCE_STORE_PATH"
      value="$(SRCROOT)/Tests/Fixtures/SystemStore/macOS26/store.db" isEnabled="NO"/>
   <EnvironmentVariable key="BACKGLANCE_ARCHIVE_PATH"
      value="$(SRCROOT)/.local/archive.sqlite" isEnabled="NO"/>
</EnvironmentVariables>
```

The two fixture-related variables are checked in **disabled** so that a fresh checkout runs against the live store by default; flip them on when you need them.

## Verifying capture works

With the debug build running and FDA granted, the whole check takes under a minute.

**1. Send yourself a notification.**

```bash
osascript -e 'display notification "hello" with title "Backglance test"'
```

**2. Watch the log.**

```bash
log stream --predicate 'subsystem == "app.backglance.Backglance"' --level debug
```

Expected sequence (timestamps and PIDs elided):

```
[capture]  StoreWatcher: change on db-wal, debouncing 500 ms
[capture]  StoreWatcher: snapshot copied (2 files, 1.2 MB) -> …/Backglance/tmp/snapshot-1755421200
[capture]  StoreAdapterV26: 1 new record after cursor recID=48211
[core]     Archive: inserted 1 notification (app=com.apple.ScriptEditor2, redaction=none)
[capture]  CaptureEngine: cursor advanced to recID=48212
```

Note what is *not* there: no title, no body. Logs carry bundle identifiers, counts, and IDs only. If you see content in a log line, that is a bug; see the privacy rules in [DEVELOPMENT_GUIDE.md](./DEVELOPMENT_GUIDE.md#swift-style-guide).

**3. Open the popover** with ⌃⌥N. The "Backglance test" notification should be at the top of the timeline with the Script Editor icon. Click it to open the detail view; the deep link is empty for this one, which is expected.

**4. (Optional) Confirm in the archive.**

```bash
sqlite3 -readonly ~/Library/Application\ Support/Backglance/archive.sqlite \
  "SELECT n.title, a.bundle_id, datetime(n.delivered_at, 'unixepoch', 'localtime')
     FROM notifications n JOIN apps a ON a.id = n.app_id
    ORDER BY n.delivered_at DESC LIMIT 3;"
```

If any of these steps fails, the next section lists the usual causes.

## Common setup issues

| Symptom | Likely cause | Fix |
|---|---|---|
| Popover banner says "Full Disk Access needed", `log stream` shows `degraded(noFullDiskAccess)`, but you granted FDA | The grant is for a different binary path (old DerivedData, `/Applications` copy) or a different signing team | Run `Scripts/grant_fda_hint.sh`, compare the printed path with the FDA list, add the current path, relaunch. Clear stale rows with `tccutil reset SystemPolicyAllFiles app.backglance.Backglance` if it helps. |
| `degraded(storeNotFound)` | `~/Library/Group Containers/group.com.apple.usernoted/db2/db` does not exist (fresh user account, or `BACKGLANCE_STORE_PATH` points at a missing file) | On a fresh account, trigger any notification once so `usernoted` creates its database. Otherwise check the path in the env var; the DEBUG log prints the resolved path at startup. |
| `degraded(unknownSchema)` on a beta macOS | The store's fingerprint matches no adapter, and the OS-major fallback probe failed | Expected on 27 beta until an adapter exists. Run `Scripts/verify_fixture.sh` to confirm current fixtures still pass, then follow the [OS Compatibility Playbook](../architecture/OS_COMPATIBILITY_PLAYBOOK.md) to capture a schema (schema only, never contents) and add `StoreAdapterV27`. |
| `degraded(readError)` right after login or wake | Snapshot copy raced with a WAL checkpoint | Transient; the watcher retries on the next poll. If it persists, check free space in `~/Library/Application Support/Backglance/tmp/`. |
| Xcode: "No account for team" / "Signing for Backglance requires a development team" | `Config/Local.xcconfig` missing or naming a team you have no account for | Add your Apple ID in Xcode ▸ Settings ▸ Accounts, then delete `Config/Local.xcconfig` and rerun `Scripts/bootstrap.sh`, or edit `DEVELOPMENT_TEAM` by hand. |
| `No signing certificate "Mac Development" found: No "Mac Development" signing certificate matching team ID "…" with a private key was found` | `DEVELOPMENT_TEAM` is not the team your certificate belongs to — most often the ten characters from the certificate's name in brackets, which identify the developer, not the team | Read the real Team ID from the certificate's `OU` field (see [Signing configuration](#signing-configuration-for-local-development)), or delete `Config/Local.xcconfig` and rerun `Scripts/bootstrap.sh`, which now reads `OU` and warns about a mismatch. |
| `xcodebuild -resolvePackageDependencies` fails, or Xcode shows "package resolution failed" | Network blocked, stale `Package.resolved`, or a corrupted SPM cache | `rm -rf ~/Library/Caches/org.swift.swiftpm ~/Library/Developer/Xcode/DerivedData/Backglance-*` then rerun `Scripts/bootstrap.sh`. Behind a proxy, set `HTTPS_PROXY` for `xcodebuild`. |
| Console warns "SUPublicEDKey missing" / updater not running in a debug build | Intentional: DEBUG builds do not embed the Sparkle public key and `SparkleUpdaterController` skips startup | Nothing to fix. To test the updater locally, build Release with a throwaway key pair generated by Sparkle's `generate_keys` and a local appcast; see [DEPLOYMENT_GUIDE.md](../deployment/DEPLOYMENT_GUIDE.md). |
| Hundreds of concurrency warnings under Xcode 26 | Strict concurrency checking is set to `complete` as a goal; a few third-party or AppKit call sites still warn | Warnings in *your* diff should be fixed (see [DEVELOPMENT_GUIDE.md](./DEVELOPMENT_GUIDE.md#swift-style-guide)). Warnings pre-existing on `main` are tracked in issues labelled `concurrency`. Do not add `@unchecked Sendable` to silence them without a comment explaining why it is safe. |
| Tests pass in Xcode but `xcodebuild test` fails with "unable to find test plan" | Running from a directory other than the repo root, or the scheme was not shared | Run from the repo root and use `-testPlan Backglance` (no extension). The scheme is under `xcshareddata`; if you created a per-user copy, delete it. |
| Debug build cannot see notifications captured by the installed release build | Different `BACKGLANCE_ARCHIVE_PATH`, or the release build is running concurrently and holding the WAL | Both builds share `~/Library/Application Support/Backglance/archive.sqlite` by default; quit one before running the other, or give the debug build its own `BACKGLANCE_ARCHIVE_PATH`. |
| Menu bar icon does not appear at all | Another instance is already running (LSUIElement apps are easy to lose track of) | `pgrep -fl Backglance`; quit the other instance with `osascript -e 'quit app id "app.backglance.Backglance"'`. |
| `osascript` test notification never shows in the popover, log shows nothing | Notifications for Script Editor are disabled in System Settings ▸ Notifications, so the store never received it | Enable notifications for Script Editor (or use any other app to trigger a notification). Backglance can only archive what the system store records. |

> 🔒 **Security:** While debugging, never copy your real system store into the repository, into a fixture directory, or into an issue. If you need to look at your own store, copy it to a temporary directory and open it read-only for schema inspection only. The safe procedure is in [DEVELOPMENT_GUIDE.md](./DEVELOPMENT_GUIDE.md#debugging-the-capture-layer-safely).

## Next Steps

- [DEVELOPMENT_GUIDE.md](./DEVELOPMENT_GUIDE.md) — layout, naming, style, git workflow, and the review checklist you will need before your first pull request.
- [CAPTURE.md](../features/CAPTURE.md) — how the store, adapters, fingerprints, and degraded modes fit together.
- [TESTING.md](../testing/TESTING.md) — the test plan, the fixture strategy, and what CI runs on each macOS runner.
- [CONTRIBUTING.md](../contributing/CONTRIBUTING.md) — how to send a change.

## Related Documentation

- [Quick Start](./QUICK_START.md) — the condensed version of this page
- [Development Guide](./DEVELOPMENT_GUIDE.md) — conventions, tests, review checklist
- [README](../../README.md) — installing the signed build instead of building from source
- [Architecture](../architecture/ARCHITECTURE.md) — the four packages and the app shell
- [Tech Stack](../architecture/TECH_STACK.md) — Swift, GRDB, Sparkle, NaturalLanguage, versions
- [OS Compatibility Playbook](../architecture/OS_COMPATIBILITY_PLAYBOOK.md) — what to do when a new macOS changes the store
- [Capture](../features/CAPTURE.md) — the capture layer in detail
- [Permissions & Privacy](../features/PERMISSIONS_PRIVACY.md) — why FDA, and what Backglance does and does not read
- [Deployment Guide](../deployment/DEPLOYMENT_GUIDE.md) — release builds, signing, notarization
- [Packaging & Notarization](../deployment/PACKAGING_NOTARIZATION.md) — Developer ID details
- [CI/CD](../deployment/CI_CD.md) — workflows and the runner matrix
- [Testing](../testing/TESTING.md) — test bundles and fixtures
- [Monitoring & Logging](../operations/MONITORING_LOGGING.md) — log categories and file log rotation
- [Troubleshooting](../operations/TROUBLESHOOTING.md) — user-facing problems
- [Security](../security/SECURITY.md) — reporting and threat model
