# CI/CD

Last Updated: 2026-08-18

This document is the complete GitHub Actions setup for Backglance: the four workflow files under `.github/workflows/`, every repository secret they read and how to create it, the branch-protection rules that turn those workflows into merge gates, what is cached and why, what each run costs in macOS minutes, and how to debug a red run without ever putting a signing key on a debug shell. The release *choreography* these workflows automate is in [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md); the signing, notarization and Sparkle mechanics the release job invokes are in [PACKAGING_NOTARIZATION.md](./PACKAGING_NOTARIZATION.md). Backglance is a free, GPL-3.0, single-repository project built by one person, so the guiding rule here is: automate the parts that are error-prone and irreversible (signing, notarization, appcast, cask), keep the parts that need judgement (release notes, announcing, post-release verification) human.

## Table of Contents

- [What each workflow gates](#what-each-workflow-gates)
- [Workflow map](#workflow-map)
- [ci.yml — build and test on every PR](#ciyml--build-and-test-on-every-pr)
  - [adapter-guard](#adapter-guard)
- [fixtures.yml — the three-OS fixture matrix](#fixturesyml--the-three-os-fixture-matrix)
- [release.yml — tag to published release](#releaseyml--tag-to-published-release)
- [cask-bump.yml — tap PR after a release](#cask-bumpyml--tap-pr-after-a-release)
- [Secrets](#secrets)
- [Permissions](#permissions)
- [Caching](#caching)
- [Required status checks and branch protection](#required-status-checks-and-branch-protection)
- [Artifact retention](#artifact-retention)
- [What CI costs](#what-ci-costs)
- [Testing CI changes (act cannot help here)](#testing-ci-changes-act-cannot-help-here)
- [Debugging a failed run](#debugging-a-failed-run)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## What each workflow gates

| Workflow | Trigger | Runner(s) | What it gates | Blocks a merge? | Blocks a release? |
|---|---|---|---|---|---|
| `ci.yml` → `build-test` | PR, push to `main` | `macos-26` | The app and all four test bundles compile and the `Backglance` test plan passes | Yes | Yes |
| `ci.yml` → `lint` | PR, push to `main` | `macos-26` | `swiftformat --lint` clean, `swiftlint --strict` clean (includes the no-content-in-logs rule) | Yes | Yes |
| `ci.yml` → `adapter-guard` | PR, push to `main` | `ubuntu-latest` | An adapter / `RecordParser` / `StoreFingerprint` change carries a fixture change | Yes | Yes |
| `ci.yml` → `ci-complete` | PR, push to `main` | `ubuntu-latest` | Aggregates the three above into one required check that always reports | Yes | No |
| `fixtures.yml` | PR touching capture code or fixtures, nightly `schedule`, `workflow_dispatch` | `macos-14`, `macos-15`, `macos-26` | `FixtureStoreTests` passes on every supported macOS, and the runner's own store still fingerprints to something we recognise | Yes, on capture PRs | Yes — a red nightly is a release blocker until triaged |
| `fixtures.yml` → `report-unknown-fingerprint` | after the matrix, non-PR runs | `ubuntu-latest` | Opens a `capture-degraded` issue when a runner reports a fingerprint we have never seen | No | It creates the issue that blocks |
| `perf.yml` → `budgets` | nightly `schedule`, PR touching the gate / test plan / workflow, `workflow_dispatch` | `macos-26` | The wall-clock budgets in [PERFORMANCE_GUIDE.md](./PERFORMANCE_GUIDE.md#regression-budgets-and-ci-policy), run under the test plan's `Performance` configuration — and that none of them were *skipped*, which is how a budget stops being measured without anyone noticing | No — a shared runner's variance is larger than the budgets | Yes — a red nightly blocks the next release until triaged |
| `release.yml` | push of tag `v*` | `macos-26` | The whole signed, notarized, stapled, published release | — | It *is* the release |
| `cask-bump.yml` | `repository_dispatch` type `release-published` | `ubuntu-latest` | Opens the version + sha256 PR against `backglance/homebrew-tap` | — | No (runs after publish) |

> ℹ️ **Info:** `ci.yml` builds on `macos-26` only. The three-OS matrix lives in `fixtures.yml`, where it is cheap because it runs one test bundle rather than a whole build. That split is deliberate — see [What CI costs](#what-ci-costs) and [COST_ESTIMATION.md](../reference/COST_ESTIMATION.md).

## Workflow map

```
  PR / push to main        nightly cron + dispatch        push tag vX.Y.Z
        │                   + capture-path PRs                   │
        ▼                           ▼                            ▼
 ┌──────────────┐         ┌──────────────────┐        ┌────────────────────┐
 │    ci.yml    │         │   fixtures.yml   │        │    release.yml     │
 │ changes      │ ubuntu  │ macos-14/15/26   │        │      macos-26      │
 │ build-test   │ macos-26│ FixtureStoreTests│        │ temp keychain →    │
 │ lint         │ macos-26│ + live probe     │        │ build.sh →         │
 │ adapter-guard│ ubuntu  └────────┬─────────┘        │ sign_and_notarize →│
 │ ci-complete  │◀ required        ▼                  │ make_appcast →     │
 └──────────────┘   check  ┌──────────────────┐       │ gh release create →│
                           │ report-unknown-  │       │ push gh-pages      │
                           │ fingerprint →    │       └─────────┬──────────┘
                           │ gh issue create  │   repository_dispatch
                           │ --label          │    release-published
                           │ capture-degraded │                 ▼
                           └──────────────────┘       ┌────────────────────┐
                                                      │   cask-bump.yml    │
                                                      │  PR to the tap     │
                                                      └────────────────────┘
```

## ci.yml — build and test on every PR

`.github/workflows/ci.yml` is the merge gate. It builds once on `macos-26`, runs the `Backglance` test plan, lints, and checks the adapter/fixture rule. Every job pins Xcode explicitly rather than trusting the image default, because GitHub rotates the default Xcode on macOS images without warning and a silent toolchain change is exactly the kind of thing that turns into an afternoon.

```yaml
name: ci

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

# One in-flight run per ref: a force-push cancels the previous build
# instead of stacking macOS minutes behind it.
concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

# Nothing in ci.yml writes anything. Jobs that need more say so themselves.
permissions:
  contents: read

env:
  XCODE_APP: /Applications/Xcode_26.2.app

jobs:
  # Cheap Linux job so a docs-only PR spends no macOS minutes. Deliberately not a
  # workflow-level paths-ignore: a skipped workflow never reports its required
  # checks, which leaves the PR permanently un-mergeable.
  changes:
    name: changed paths
    runs-on: ubuntu-latest
    timeout-minutes: 5
    outputs:
      code: ${{ steps.filter.outputs.code }}
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: filter
        with:
          # 'every' = a file counts only if it matches ALL patterns, i.e. it is
          # neither under docs/ nor a markdown file. With the default 'some', a
          # root-level README.md would satisfy '!docs/**' and defeat the filter.
          predicate-quantifier: 'every'
          filters: |
            code:
              - '!docs/**'
              - '!**/*.md'

  build-test:
    name: build-test
    needs: changes
    if: needs.changes.outputs.code == 'true'
    runs-on: macos-26
    timeout-minutes: 40
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode 26.2
        run: |
          sudo xcode-select -s "$XCODE_APP"
          xcodebuild -version && swift --version
      # Resolved SPM checkouts: GRDB 7.x, Sparkle 2.7.x and Sparkle's binary artifact.
      - name: Cache Swift packages
        uses: actions/cache@v4
        with:
          path: build/SourcePackages
          key: spm-macos26-${{ hashFiles('Backglance.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved', 'Packages/*/Package.resolved') }}
          restore-keys: spm-macos26-
      - name: Resolve packages and install xcbeautify
        run: |
          xcodebuild -resolvePackageDependencies -project Backglance.xcodeproj \
            -scheme Backglance -clonedSourcePackagesDirPath build/SourcePackages
          brew install --quiet xcbeautify
      # `xcodebuild test` builds every target in the scheme first, so this one step
      # is both the build gate and the unit-test gate.
      - name: Build and test
        run: |
          set -o pipefail
          xcodebuild test \
            -scheme Backglance \
            -testPlan Backglance \
            -configuration Debug \
            -destination 'platform=macOS,arch=arm64' \
            -clonedSourcePackagesDirPath build/SourcePackages \
            -resultBundlePath build/ci.xcresult \
            -enableCodeCoverage YES \
            CODE_SIGNING_ALLOWED=NO \
            | xcbeautify --renderer github-actions
      # The only thing worth keeping from a red run: failures, attachments, coverage.
      - name: Upload xcresult
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: ci-xcresult
          path: build/ci.xcresult
          retention-days: 7
          if-no-files-found: warn

  lint:
    name: lint
    needs: changes
    if: needs.changes.outputs.code == 'true'
    runs-on: macos-26
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
      - name: Install linters
        run: brew install --quiet swiftformat swiftlint
      # --lint never rewrites; it exits non-zero on any file it would have changed.
      - name: SwiftFormat
        run: swiftformat --lint --reporter github-actions-log .
      # --strict promotes every warning to an error, including no_content_in_logs.
      - name: SwiftLint
        run: swiftlint lint --strict --reporter github-actions-logging

  adapter-guard:
    name: Adapter changes carry fixtures
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: changes
        with:
          filters: |
            adapter:
              - 'Packages/BackglanceCapture/Sources/**/Adapters/**'
              - 'Packages/BackglanceCapture/Sources/**/RecordParser*'
              - 'Packages/BackglanceCapture/Sources/**/StoreFingerprint*'
            fixtures:
              - 'Tests/Fixtures/SystemStore/**'
      - name: Fail if adapter changed without fixture coverage
        if: steps.changes.outputs.adapter == 'true' && steps.changes.outputs.fixtures == 'false'
        run: |
          echo "::error title=Adapter change without fixtures::Adapters/, RecordParser* or StoreFingerprint* changed, but nothing under Tests/Fixtures/SystemStore/ did."
          cat <<'MSG'
          The adapters read Apple's undocumented system store; the synthetic fixtures
          are the only proof they still work. Fix:
            1. Scripts/make_fixture.sh                 (on a Mac running the target macOS)
            2. Scripts/verify_fixture.sh --os <major>
            3. Commit store.db + manifest.json + expected.json + KnownFingerprints.json
          Rule and reasoning:
            docs/contributing/CONTRIBUTING.md#adapter-and-parser-changes-require-fixtures
          MSG
          exit 1

  # The single required status check. It runs even when build-test and lint were
  # skipped, so branch protection never waits on a check that will not report.
  ci-complete:
    name: ci-complete
    if: always()
    needs: [changes, build-test, lint, adapter-guard]
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - name: Fail if any required job did not succeed
        run: |
          results='${{ join(needs.*.result, " ") }}'
          echo "job results: $results"
          for r in $results; do
            case "$r" in
              success|skipped) ;;
              *) echo "::error::a required job reported '$r'"; exit 1 ;;
            esac
          done
          echo "all required jobs green"
```

Notes on the choices in this file:

- **`sudo xcode-select -s /Applications/Xcode_26.2.app`** rather than `DEVELOPER_DIR`, because it also affects the `xcrun` calls that `brew`-installed tools make. `sudo` needs no password on hosted runners.
- **`CODE_SIGNING_ALLOWED=NO`** — `ci.yml` has no certificate and needs none. Only `release.yml` signs.
- **`-destination 'platform=macOS,arch=arm64'`** — the `macos-26` image is Apple silicon; universal builds only matter for the release.
- **`xcbeautify --renderer github-actions`** turns failures into `::error file=…,line=…` annotations, so they land on the PR diff instead of a 4,000-line log.
- The `ui-test` job also lives in `ci.yml`. The nightly `perf` job has its own workflow, `.github/workflows/perf.yml`, because it is the one run that uses the test plan's `Performance` configuration — `ci.yml` and `fixtures.yml` pass `-skip-test-configuration Performance` so a pull request never measures a wall-clock budget on a shared runner. Both are documented with their assertions in [TESTING.md](../testing/TESTING.md#ci-configuration).

### adapter-guard

`adapter-guard` is the mechanical half of the one hard rule in the project: a change to the code that reads Apple's undocumented store must come with a change to the synthetic fixtures that prove it still reads it correctly ([CONTRIBUTING.md](../contributing/CONTRIBUTING.md#adapter-and-parser-changes-require-fixtures)).

It runs on `ubuntu-latest` because it never compiles anything — it only asks `dorny/paths-filter@v3` two questions about the diff. That keeps it off the 10× macOS meter and makes it the fastest job in the workflow, usually under 20 seconds. `paths-filter` compares against the PR base by default, and against the previous commit on a push to `main`, which is the right comparison for a squash-merged PR.

> ⚠️ **Warning:** `adapter-guard` proves a fixture *changed*, not that the fixture is *right*. The real verification is `fixtures.yml` running `FixtureStoreTests` on all three macOS versions. A PR that edits `expected.json` to make a failing test pass sails past `adapter-guard` and is caught in review — which is why an `expected.json` diff has to be explained in the PR description.

## fixtures.yml — the three-OS fixture matrix

`.github/workflows/fixtures.yml` is the early-warning system for macOS schema changes. It does two things on each of `macos-14`, `macos-15` and `macos-26`: run the fixture suite (which proves the adapters still parse our synthetic stores), and run a **live probe smoke test** that fingerprints the runner's *own* Notification Center store.

The live probe is the interesting half. Hosted runners grant Full Disk Access to nothing, and a fresh runner may not have a store on disk at all, so the probe is expected to come back `permissionDenied` or `storeNotFound` most of the time. That is fine. What is *not* fine is the probe crashing, hanging, or reporting a schema we have never seen — the first two are bugs in `StoreLocation` / `StoreFingerprint`, the third means a runner image changed the store, which is the signal this workflow exists to catch.

> 🔒 **Security:** The live probe reads `sqlite_master` DDL and the `dbinfo` table. It never reads the `record` table, never reads a row of notification content, and uploads nothing but a hash and a status string. There is nothing personal on a GitHub runner, but the probe is written exactly as it would be on a user's machine, because that is the only way the code path stays honest.

```yaml
name: fixtures

on:
  # Nightly, offset off the hour so it does not queue behind everyone else's cron.
  schedule:
    - cron: '17 4 * * *'

  workflow_dispatch:
    inputs:
      reason:
        description: Why this run (shows up in the run title)
        required: false
        default: manual check

  pull_request:
    paths:
      - 'Packages/BackglanceCapture/**'
      - 'Tests/Fixtures/**'
      - 'Tests/BackglanceCaptureTests/**'
      - 'Scripts/make_fixture.sh'
      - 'Scripts/verify_fixture.sh'
      - '.github/workflows/fixtures.yml'

concurrency:
  group: fixtures-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  fixtures:
    name: fixtures (${{ matrix.os }})
    runs-on: ${{ matrix.os }}
    timeout-minutes: 30
    strategy:
      # One red OS must not hide the state of the other two.
      fail-fast: false
      matrix:
        include:
          - os: macos-14
            xcode: /Applications/Xcode_16.2.app
            os_major: '14'
          - os: macos-15
            xcode: /Applications/Xcode_16.2.app
            os_major: '15'
          - os: macos-26
            xcode: /Applications/Xcode_26.2.app
            os_major: '26'
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode and install tools
        run: |
          sudo xcode-select -s "${{ matrix.xcode }}"
          xcodebuild -version && sw_vers
          brew install --quiet xcbeautify jq
      - name: Cache Swift packages
        uses: actions/cache@v4
        with:
          path: build/SourcePackages
          key: spm-${{ matrix.os }}-${{ hashFiles('Backglance.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved', 'Packages/*/Package.resolved') }}
          restore-keys: spm-${{ matrix.os }}-
      - name: Resolve packages
        run: |
          xcodebuild -resolvePackageDependencies -project Backglance.xcodeproj \
            -scheme Backglance -clonedSourcePackagesDirPath build/SourcePackages
      # Hygiene + manifest checks for this OS's fixture, then the Swift suite.
      - name: Fixture suite
        run: |
          set -o pipefail
          Scripts/verify_fixture.sh --os ${{ matrix.os_major }} --hygiene-only
          xcodebuild test -scheme Backglance -testPlan Backglance -configuration Debug \
            -destination 'platform=macOS' \
            -clonedSourcePackagesDirPath build/SourcePackages \
            -only-testing:BackglanceCaptureTests/FixtureStoreTests \
            CODE_SIGNING_ALLOWED=NO \
            | xcbeautify --renderer github-actions
      # ------------------------------------------------------------------
      # Live probe smoke test.
      #
      # Scripts/verify_fixture.sh --live writes ONE json object to stdout:
      #   {"status":"ok|permissionDenied|storeNotFound|unknownSchema|missingTables|readError",
      #    "schemaHash":"<64 hex or null>","dbinfoVersion":"<string or null>",
      #    "osVersion":"26.5.0","runner":"macos-26"}
      # and always exits 0. A non-zero exit means the probe itself broke, which is
      # a real failure — degrading is the contract, crashing is not.
      # ------------------------------------------------------------------
      - name: Live probe smoke test
        id: probe
        run: |
          set -uo pipefail
          mkdir -p build/probe
          out="build/probe/live-probe-${{ matrix.os }}.json"
          if ! Scripts/verify_fixture.sh --live > "$out"; then
            echo "::error title=Live probe crashed::verify_fixture.sh --live exited non-zero on ${{ matrix.os }}. The probe must degrade, never fail."
            cat "$out" || true
            exit 1
          fi
          jq -e . "$out" > /dev/null || { echo "::error::live probe did not emit valid JSON"; cat "$out"; exit 1; }
          jq -c . "$out"
          status="$(jq -r .status "$out")"
          case "$status" in
            # Readable: print the fingerprint hash so a drift is visible in the log.
            ok) echo "::notice title=Store readable on ${{ matrix.os }}::schemaHash $(jq -r .schemaHash "$out")" ;;
            # Expected on a hosted runner: no Full Disk Access, or no store at all.
            permissionDenied|storeNotFound) echo "::notice title=Probe degraded::$status — expected, not a failure" ;;
            # Not a leg failure; report-unknown-fingerprint turns this into an issue.
            unknownSchema|missingTables) echo "::warning title=Unknown store schema::$status — see the follow-up job" ;;
            *) echo "::error::'$status' is not a ProbeResult case this workflow knows about"; exit 1 ;;
          esac
      - name: Upload live probe result
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: live-probe-${{ matrix.os }}
          path: build/probe/live-probe-${{ matrix.os }}.json
          retention-days: 30
          if-no-files-found: warn

  # Collect every leg's probe result and open one issue per unknown fingerprint.
  # PR runs are excluded: a fork PR has no business opening issues, and a
  # contributor should not be paged for a runner-image change.
  report-unknown-fingerprint:
    name: Report unknown fingerprints
    needs: fixtures
    if: always() && github.event_name != 'pull_request'
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
      issues: write
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          pattern: live-probe-*
          path: build/probe
          merge-multiple: true
      - name: Open a capture-degraded issue for anything we do not recognise
        env:
          GH_TOKEN: ${{ github.token }}
          KNOWN: Packages/BackglanceCapture/Sources/BackglanceCapture/Resources/KnownFingerprints.json
        run: |
          set -euo pipefail
          shopt -s nullglob
          files=(build/probe/live-probe-*.json)
          [[ ${#files[@]} -gt 0 ]] || { echo "no probe results to inspect"; exit 0; }
          for f in "${files[@]}"; do
            status="$(jq -r .status "$f")"
            runner="$(jq -r .runner "$f")"
            hash="$(jq -r '.schemaHash // ""' "$f")"
            osver="$(jq -r '.osVersion // "unknown"' "$f")"
            # permissionDenied / storeNotFound are the normal hosted-runner outcome.
            case "$status" in
              permissionDenied|storeNotFound) echo "$runner: $status (expected)"; continue ;;
            esac
            # A readable store whose hash is already in KnownFingerprints.json is fine.
            if [[ "$status" == "ok" ]] && jq -e --arg h "$hash" 'any(.adapters[]?[]?; . == $h)' "$KNOWN" > /dev/null; then
              echo "$runner: ok, known fingerprint ${hash:0:12}"; continue
            fi
            title="Unknown store fingerprint on $runner (macOS $osver)"
            # Dedupe by exact title so a nightly cron does not file this 30 times a month.
            if gh issue list --repo "$GITHUB_REPOSITORY" --state open --label capture-degraded \
                 --search "in:title \"$title\"" --json title --jq '.[].title' | grep -Fxq "$title"; then
              echo "issue already open: $title"; continue
            fi
            gh issue create --repo "$GITHUB_REPOSITORY" \
              --title "$title" \
              --label capture-degraded \
              --body "The nightly \`fixtures.yml\` live probe on **$runner** (macOS $osver) reported \`$status\`. Either a runner image changed the system store, or \`StoreFingerprint\` changed how it normalises DDL. Next steps: docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md
          - \`schemaHash\`: \`${hash:-none}\`
          - Run: ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
            echo "opened: $title"
          done
```

> ⚠️ **Warning:** Everything the live probe touches is undocumented. A green probe is not a promise that the store is stable; it says only that *today, on this image*, the DDL hashed to something we have on file. The fixtures are the contract; the probe is a smoke alarm.

The nightly schedule is what makes this useful: GitHub refreshes macOS runner images within days of an Apple point release, so a schema change shows up as a noisy nightly before more than a handful of users have updated. [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md) treats "the last nightly `fixtures.yml` was green on all three" as a pre-flight item for every release.

## release.yml — tag to published release

`.github/workflows/release.yml` runs on a `v*` tag push and does Steps 2–8 of [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md): build universal, sign, notarize, staple, package, appcast, GitHub Release, cask dispatch. Steps 1 (version bump and tag), 9 (announce) and 10 (post-release verification) stay human.

It runs the same three scripts a laptop release runs — `Scripts/build.sh`, `Scripts/sign_and_notarize.sh`, `Scripts/make_appcast.sh` — so there is exactly one implementation of the signing order and the appcast generation, the one in [PACKAGING_NOTARIZATION.md](./PACKAGING_NOTARIZATION.md). The workflow's own job is to hand those scripts a keychain with the identity in it, and to clean up afterwards.

```yaml
name: release

on:
  push:
    tags: ['v*']

permissions:
  contents: read

jobs:
  release:
    name: Build, sign, notarize, publish
    runs-on: macos-26
    timeout-minutes: 120          # notarization is a queue; 25 min is typical, 2 h is the ceiling
    permissions:
      contents: write             # gh release create, and the push to gh-pages
    env:
      XCODE_APP: /Applications/Xcode_26.2.app
      DIST: build/dist
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0          # release notes read CHANGELOG.md; tags are needed for context
      - name: Derive the version from the tag
        id: v
        run: |
          set -euo pipefail
          version="${GITHUB_REF_NAME#v}"
          [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
            || { echo "::error::tag '$GITHUB_REF_NAME' is not vMAJOR.MINOR.PATCH"; exit 1; }
          echo "version=$version" >> "$GITHUB_OUTPUT"
          echo "Releasing $version"
      - name: Select Xcode 26.2 and install release tools
        run: |
          sudo xcode-select -s "$XCODE_APP"
          xcodebuild -version
          brew install --quiet xcbeautify create-dmg pandoc jq
      - name: Cache Swift packages
        uses: actions/cache@v4
        with:
          path: build/SourcePackages
          key: spm-release-${{ hashFiles('Backglance.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved', 'Packages/*/Package.resolved') }}
          restore-keys: |
            spm-release-
            spm-macos26-
      # Temporary keychain. Never the login keychain: this one has a known password, a 1-hour auto-lock,
      # and is deleted in a final if: always() step whatever the outcome.
      - name: Create a temporary keychain and import the Developer ID identity
        env:
          DEVELOPER_ID_CERT_P12_BASE64: ${{ secrets.DEVELOPER_ID_CERT_P12_BASE64 }}
          DEVELOPER_ID_CERT_PASSWORD: ${{ secrets.DEVELOPER_ID_CERT_PASSWORD }}
          KEYCHAIN_PASSWORD: ${{ secrets.KEYCHAIN_PASSWORD }}
        run: |
          set -euo pipefail
          # The `runner` context is not available in job-level env, so the path is
          # derived here and exported for the cleanup step at the end of the job.
          KEYCHAIN_PATH="$RUNNER_TEMP/backglance-signing.keychain-db"
          echo "KEYCHAIN_PATH=$KEYCHAIN_PATH" >> "$GITHUB_ENV"
          cert="$RUNNER_TEMP/DeveloperID.p12"
          security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
          security set-keychain-settings -lut 3600 "$KEYCHAIN_PATH"    # auto-lock after 1 h
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
          printf '%s' "$DEVELOPER_ID_CERT_P12_BASE64" | base64 --decode > "$cert"
          security import "$cert" -k "$KEYCHAIN_PATH" -P "$DEVELOPER_ID_CERT_PASSWORD" \
            -f pkcs12 -T /usr/bin/codesign -T /usr/bin/security
          rm -P "$cert"
          # Without this, codesign prompts for keychain access and hangs forever in CI.
          security set-key-partition-list -S apple-tool:,apple:,codesign: \
            -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" > /dev/null
          # Put it first in the search list, keeping the existing keychains after it.
          security list-keychains -d user -s "$KEYCHAIN_PATH" \
            $(security list-keychains -d user | tr -d '"')
          security find-identity -v -p codesigning "$KEYCHAIN_PATH"
      - name: Build universal and confirm both slices are present
        run: |
          set -euo pipefail
          Scripts/build.sh
          archs="$(lipo -archs build/export/Backglance.app/Contents/MacOS/Backglance)"
          grep -q x86_64 <<<"$archs" && grep -q arm64 <<<"$archs" \
            || { echo "::error::not a Universal 2 binary: $archs"; exit 1; }
      # Signs inside-out with --options runtime --timestamp, submits app and dmg to
      # notarytool --wait, staples both, writes zip + dmg + SHA256SUMS.txt to build/dist.
      - name: Sign, notarize, staple, package
        env:
          NOTARY_APPLE_ID: ${{ secrets.NOTARY_APPLE_ID }}
          NOTARY_TEAM_ID: ${{ secrets.NOTARY_TEAM_ID }}
          NOTARY_PASSWORD: ${{ secrets.NOTARY_PASSWORD }}
        run: Scripts/sign_and_notarize.sh build/export/Backglance.app "${{ steps.v.outputs.version }}"
      # The only thing that explains an Invalid result. Kept on green runs too.
      - name: Upload notarization logs
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: notarytool-logs
          path: build/notary-*/notary-*-log.json
          retention-days: 30
          if-no-files-found: ignore
      - name: Verify the staple survived packaging
        run: |
          set -euo pipefail
          v="${{ steps.v.outputs.version }}"
          xcrun stapler validate build/export/Backglance.app
          xcrun stapler validate "$DIST/Backglance-$v.dmg"
          spctl --assess --type execute --verbose=4 build/export/Backglance.app
          spctl --assess --type open --context context:primary-signature --verbose=4 "$DIST/Backglance-$v.dmg"
      - name: Build the Sparkle appcast
        env:
          SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}
        run: Scripts/make_appcast.sh "${{ steps.v.outputs.version }}" "$DIST"
      - name: Upload the release artifacts
        uses: actions/upload-artifact@v4
        with:
          name: release-${{ steps.v.outputs.version }}
          path: |
            build/dist/Backglance-*.zip
            build/dist/Backglance-*.dmg
            build/dist/*.delta
            build/dist/SHA256SUMS.txt
            build/dist/appcast.xml
          retention-days: 90
      - name: Create the GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          v="${{ steps.v.outputs.version }}"
          # Notes are this version's CHANGELOG section — the same text Sparkle shows.
          awk -v ver="$v" '
            $0 ~ "^## \\[" ver "\\]" { grab = 1; next }
            grab && /^## \[/         { exit }
            grab                     { print }
          ' CHANGELOG.md > "$DIST/RELEASE_NOTES.md"
          test -s "$DIST/RELEASE_NOTES.md" \
            || { echo "::error::no ## [$v] section in CHANGELOG.md"; exit 1; }
          gh release create "v$v" \
            --title "Backglance $v" \
            --notes-file "$DIST/RELEASE_NOTES.md" \
            --latest \
            "$DIST/Backglance-$v.zip" \
            "$DIST/Backglance-$v.dmg" \
            "$DIST/SHA256SUMS.txt" \
            "$DIST/appcast.xml"
          if compgen -G "$DIST/*.delta" > /dev/null; then
            gh release upload "v$v" "$DIST"/*.delta
          fi
          # Sparkle will 404 if the appcast goes out before the assets are live.
          curl -fsIL "https://github.com/${GITHUB_REPOSITORY}/releases/download/v$v/Backglance-$v.zip" \
            | grep -i '^content-length' || { echo "::error::release asset not reachable yet"; exit 1; }
      # Strictly after the release is published: the appcast points at the assets.
      - name: Publish the appcast to gh-pages
        uses: actions/checkout@v4
        with:
          ref: gh-pages
          path: build/gh-pages
      - name: Commit and push the appcast
        run: |
          set -euo pipefail
          v="${{ steps.v.outputs.version }}"
          cp "$DIST/appcast.xml" build/gh-pages/appcast.xml
          cd build/gh-pages
          git config user.name  "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add appcast.xml
          git diff --cached --quiet && { echo "appcast unchanged — nothing to push"; exit 0; }
          git commit -m "appcast: $v"
          git push origin gh-pages
      # Pages can take a minute to rebuild; a warning, not a failure — the release is done.
      - name: Verify GitHub Pages is serving the new appcast
        run: |
          set -uo pipefail
          v="${{ steps.v.outputs.version }}"
          for _ in 1 2 3 4 5 6; do
            curl -fsSL https://backglance.github.io/backglance/appcast.xml | grep -q "$v" \
              && { echo "appcast live with $v"; exit 0; }
            sleep 20
          done
          echo "::warning::Pages has not picked up the appcast yet — check it by hand"
      - name: Trigger the Homebrew cask bump
        env:
          # NOT github.token: events raised with GITHUB_TOKEN do not start new
          # workflow runs, so cask-bump.yml would never fire. See the Secrets table.
          GH_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}
        run: |
          set -euo pipefail
          gh api "repos/${GITHUB_REPOSITORY}/dispatches" \
            -f event_type=release-published \
            -F "client_payload[version]=${{ steps.v.outputs.version }}"
          echo "dispatched release-published"
      # Runs on success, failure and cancellation. The runner is torn down anyway,
      # but leaving the identity in a keychain a minute longer is not a habit worth having.
      - name: Delete the temporary keychain
        if: always()
        run: |
          security delete-keychain "${KEYCHAIN_PATH:-}" 2>/dev/null || true
          rm -f "${KEYCHAIN_PATH:-/nonexistent}"
          echo "temporary keychain removed"
```

> 🔒 **Security:** Every secret is scoped to the step that needs it via a step-level `env:`, never to the job. A `run:` step that does not name `NOTARY_PASSWORD` cannot read it, which limits what a compromised action in the chain could exfiltrate. GitHub masks secret values in logs too, but masking is a safety net, not a design.

> ⚠️ **Warning:** `release.yml` runs only on tag pushes to this repository — never on a pull request, and so never on a fork. That is GitHub's default and it must stay that way: do not add `pull_request_target` to this file for any reason.

## cask-bump.yml — tap PR after a release

`.github/workflows/cask-bump.yml` reacts to the `repository_dispatch` that `release.yml` sends, updates the two lines in `Casks/backglance.rb` that change per release, and opens a PR against `backglance/homebrew-tap`. It runs on `ubuntu-latest` — nothing here needs a Mac — so it costs effectively nothing.

The steps mirror `Scripts/bump_cask.sh` ([PACKAGING_NOTARIZATION.md](./PACKAGING_NOTARIZATION.md#bump-flow-scriptsbump_casksh)), the one-command path for a local bump. The workflow inlines them rather than calling the script so the checkout, the checksum verification and the PR are three separately visible, separately re-runnable steps in the log.

```yaml
name: cask-bump

on:
  repository_dispatch:
    types: [release-published]

permissions:
  contents: read      # nothing in THIS repository is written; the tap uses its own token

jobs:
  bump:
    name: Bump backglance cask
    runs-on: ubuntu-latest
    timeout-minutes: 15
    env:
      VERSION: ${{ github.event.client_payload.version }}
      SOURCE_REPO: ${{ github.repository }}
      TAP_REPO: backglance/homebrew-tap
      GH_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}
    steps:
      # client_payload is attacker-controllable in principle (anyone who can
      # dispatch), and it ends up in a shell string and a branch name. Validate first.
      - name: Validate the payload
        run: |
          set -euo pipefail
          [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
            || { echo "::error::client_payload.version '$VERSION' is not MAJOR.MINOR.PATCH"; exit 1; }
          echo "bumping to $VERSION"
      - name: Check out the tap
        uses: actions/checkout@v4
        with:
          repository: backglance/homebrew-tap
          token: ${{ secrets.HOMEBREW_TAP_TOKEN }}
          path: tap
      # Download the published asset and check it against the release's own
      # SHA256SUMS.txt. If those disagree, something is wrong with the release,
      # and a cask pinning the wrong hash breaks `brew install` for everyone.
      - name: Download the release zip and verify its checksum
        id: sha
        run: |
          set -euo pipefail
          zip="Backglance-$VERSION.zip"
          base="https://github.com/$SOURCE_REPO/releases/download/v$VERSION"
          mkdir -p work
          curl -fsSL -o "work/$zip" "$base/$zip"
          curl -fsSL -o work/SHA256SUMS.txt "$base/SHA256SUMS.txt"
          sum="$(sha256sum "work/$zip" | awk '{print $1}')"
          grep -Fq "$sum  $zip" work/SHA256SUMS.txt \
            || { echo "::error::sha256 $sum does not match SHA256SUMS.txt — refusing to bump"; exit 1; }
          echo "sha256=$sum" >> "$GITHUB_OUTPUT"
          echo "sha256 $sum verified against SHA256SUMS.txt"
      - name: Rewrite version and sha256 in Casks/backglance.rb
        working-directory: tap
        run: |
          set -euo pipefail
          cask=Casks/backglance.rb
          [[ -f "$cask" ]] || { echo "::error::$cask not found in $TAP_REPO"; exit 1; }
          sed -e "s/^  version \".*\"/  version \"$VERSION\"/" \
              -e "s/^  sha256 \".*\"/  sha256 \"${{ steps.sha.outputs.sha256 }}\"/" \
              "$cask" > "$cask.tmp"
          mv "$cask.tmp" "$cask"
          git diff --quiet -- "$cask" \
            && { echo "::error::cask already at $VERSION with this sha256"; exit 1; }
          git --no-pager diff -- "$cask"
      - name: Open the pull request
        working-directory: tap
        run: |
          set -euo pipefail
          branch="bump-backglance-$VERSION"
          git config user.name  "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git checkout -b "$branch"
          git commit -am "backglance $VERSION"
          git push -u origin "$branch"
          gh pr create --repo "$TAP_REPO" --base main --head "$branch" \
            --title "backglance $VERSION" \
            --body "Bump to \`$VERSION\`. Opened automatically by \`cask-bump.yml\`; two lines changed, read the diff and merge.
          - url: https://github.com/$SOURCE_REPO/releases/download/v$VERSION/Backglance-$VERSION.zip
          - sha256: \`${{ steps.sha.outputs.sha256 }}\` (matches SHA256SUMS.txt on the release)
          - Release notes: https://github.com/$SOURCE_REPO/releases/tag/v$VERSION"
```

> ✅ **Do:** merge the tap PR by hand. It is two lines and takes ten seconds to read, and it is the last human checkpoint before `brew upgrade --cask backglance` starts serving the new build to everyone with the tap.

## Secrets

All eight are **repository secrets** on `backglance/backglance` (Settings ▸ Secrets and variables ▸ Actions). None are environment secrets — a solo project does not need a deployment-environment approval flow, and the tag push is already the approval.

| Secret | What it is | How to create it |
|---|---|---|
| `DEVELOPER_ID_CERT_P12_BASE64` | The Developer ID Application identity (certificate **and** private key) as a base64 PKCS#12 blob | Keychain Access ▸ login ▸ My Certificates ▸ export "Developer ID Application: Backglance (TEAMID1234)" as `.p12`, then `base64 -i ~/Desktop/DeveloperID.p12 \| tr -d '\n' \| gh secret set DEVELOPER_ID_CERT_P12_BASE64 --repo backglance/backglance` |
| `DEVELOPER_ID_CERT_PASSWORD` | The password set on that `.p12` export | `gh secret set DEVELOPER_ID_CERT_PASSWORD --repo backglance/backglance` (prompts) |
| `KEYCHAIN_PASSWORD` | Password for the throwaway keychain `release.yml` creates. It protects nothing that outlives the job — but `security` refuses an empty one | `openssl rand -base64 32 \| gh secret set KEYCHAIN_PASSWORD --repo backglance/backglance` |
| `NOTARY_APPLE_ID` | The Apple ID on the Developer Program team | Plain email address; `gh secret set NOTARY_APPLE_ID` |
| `NOTARY_TEAM_ID` | The 10-character Team ID (`TEAMID1234`) | Visible at developer.apple.com ▸ Membership; `gh secret set NOTARY_TEAM_ID` |
| `NOTARY_PASSWORD` | An **app-specific password** for notarization, not the Apple ID password | appleid.apple.com ▸ Sign-In and Security ▸ App-Specific Passwords. Validate it locally first with `xcrun notarytool store-credentials backglance-notary --apple-id "$AC_APPLE_ID" --team-id "$AC_TEAM_ID" --password "$AC_PASSWORD"`, then store the same string as the secret |
| `SPARKLE_PRIVATE_KEY` | The EdDSA private key that signs update archives. Losing it means no user can ever be offered an update again | `"$SPARKLE_BIN/generate_keys" -x ~/Desktop/sparkle_private_key.txt`, then `gh secret set SPARKLE_PRIVATE_KEY --repo backglance/backglance < ~/Desktop/sparkle_private_key.txt`, then `rm -P` the file. The matching public key is `SUPublicEDKey` in `Info.plist` |
| `HOMEBREW_TAP_TOKEN` | A fine-grained personal access token used for two things: raising the `repository_dispatch` on this repository, and pushing the branch + opening the PR on the tap | github.com ▸ Settings ▸ Developer settings ▸ Personal access tokens ▸ Fine-grained. Resource owner `backglance`; repository access limited to `backglance/homebrew-tap` **and** `backglance/backglance`; permissions: tap → Contents `Read and write`, Pull requests `Read and write`; main repo → Contents `Read and write` (this is what `repository_dispatch` requires). 90-day expiry, calendar reminder to rotate |

> ⚠️ **Warning:** `HOMEBREW_TAP_TOKEN` needs the main repository too, and that is not an oversight. GitHub deliberately does not start new workflow runs from events raised with the built-in `GITHUB_TOKEN` — it is the loop guard. A `repository_dispatch` sent with `github.token` would be recorded and then quietly ignored by `cask-bump.yml`. A PAT is the only way to cross that boundary.

> 🔒 **Security:** Only three of these are catastrophic to leak: the `.p12` plus its password (someone can sign malware as you — revoke the certificate in the portal; builds already notarized keep working because their timestamps predate the revocation) and `SPARKLE_PRIVATE_KEY` (someone can serve a signed "update"). Incident handling for both is in [SECURITY.md](../security/SECURITY.md). The other five are annoying, not dangerous.

Verifying the set after wiring it up:

```bash
# Names only — GitHub never shows values back, not even to the owner. Expect all eight.
gh secret list --repo backglance/backglance

# The cheapest end-to-end proof that the notary secrets work, without cutting a release:
xcrun notarytool history --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" \
  --password "$NOTARY_PASSWORD" | head -5
```

## Permissions

Every workflow starts from `permissions: contents: read` at the top level and raises it per job only where something is genuinely written. That is narrower than GitHub's default token, and it means reading a workflow file tells you exactly what it can touch.

| Workflow | Top-level | Job overrides | Why |
|---|---|---|---|
| `ci.yml` | `contents: read` | none | Builds, tests, lints. Writes nothing |
| `fixtures.yml` | `contents: read` | `report-unknown-fingerprint`: `issues: write` | Only that job files issues; the matrix legs cannot |
| `release.yml` | `contents: read` | `release`: `contents: write` | `gh release create` and the push to `gh-pages` |
| `cask-bump.yml` | `contents: read` | none | Everything it writes is in the tap, using `HOMEBREW_TAP_TOKEN`, not `GITHUB_TOKEN` |

Also set repository-wide, under Settings ▸ Actions ▸ General: **workflow permissions** = "Read repository contents and packages permissions" (so a workflow that forgets its `permissions:` block gets read-only); **allow Actions to create and approve pull requests** = off (`cask-bump.yml` uses a PAT on the tap, and leaving this off closes a self-approval path); **fork pull request workflows** = require approval for first-time contributors (fork PRs never see secrets regardless, but this also stops drive-by minute consumption).

## Caching

One cache, used by three workflows: the resolved SPM checkouts under `build/SourcePackages`. `Scripts/build.sh` already resolves into that directory (so the Sparkle command-line tools land at a predictable `build/SourcePackages/artifacts/sparkle/Sparkle/bin`), which makes it the natural cache target.

| Item | Cached? | Reasoning |
|---|---|---|
| `build/SourcePackages` (GRDB 7.x, Sparkle 2.7.x + binary artifact) | Yes, `actions/cache@v4` | Saves 60–90 s per macOS job. Keyed on `Package.resolved` so a dependency bump invalidates it automatically |
| DerivedData / build products | No | Xcode's incremental state across machines is unreliable and the cache would be gigabytes for a marginal win. A clean build is ~4 minutes |
| Homebrew formulae (`xcbeautify`, `swiftlint`, `create-dmg`, `pandoc`) | No | `brew install` from the runner's warm cache is faster than restoring a cache entry, and these change rarely enough not to matter |
| The `.xcresult` bundle | No — uploaded as an artifact instead | It is diagnostic output, not an input to another run |

The runner label is in the key (`spm-macos-15-<hash>`) because a package resolved by Xcode 16.2 on `macos-14` is not necessarily reusable by Xcode 26.2 on `macos-26`. The `restore-keys` prefix means a dependency bump still gets a warm partial cache — SPM re-resolves only what changed — rather than starting from an empty directory.

> 💡 **Tip:** GitHub evicts caches not read for 7 days, and the repository-wide limit is 10 GB. Three SPM caches are well under 1 GB together, so nothing here needs pruning. If a cache ever goes stale in a way `Package.resolved` does not capture, `gh cache delete --all --repo backglance/backglance` is the reset button.

## Required status checks and branch protection

Branch protection on `main` (Settings ▸ Branches ▸ Add rule, or a ruleset):

| Setting | Value | Why |
|---|---|---|
| Require a pull request before merging | On, 0 required approvals | Solo project — the maintainer cannot approve their own PR, and requiring 1 would make `main` unwritable. The PR still exists so CI runs and the diff is reviewable later |
| Require status checks to pass | On, strict ("branches must be up to date") | Prevents the semantic-merge case where two green PRs are red together |
| Required checks | `ci-complete`, `fixtures (macos-14)`, `fixtures (macos-15)`, `fixtures (macos-26)` | See below |
| Require conversation resolution | On | Review comments do not get merged past |
| Require signed commits | On | The DCO sign-off (`git commit -s`) is separate; this is GPG/SSH signing |
| Require linear history | On | Squash-merge only, which keeps `git bisect` over the capture code meaningful |
| Do not allow bypassing | On, including administrators | The point of the rule is that it applies on a Friday too |
| Allow force pushes / deletions | Off | — |

> ⚠️ **Warning:** Do **not** list `build-test`, `lint` and `adapter-guard` individually as required checks while they are gated on the `changes` job. A skipped job reports `skipped`, GitHub treats a required check that never reports as pending, and a docs-only PR would be stuck forever. That is exactly why `ci-complete` exists: it runs with `if: always()`, inspects `needs.*.result`, and treats `skipped` as acceptable and anything other than `success` or `skipped` as a failure. Require `ci-complete`; let it require the rest.

The `fixtures` legs are listed individually because `fixtures.yml` only runs on capture-path PRs. GitHub does not block a PR on a required check belonging to a workflow that was not triggered at all for that PR, so listing them is safe and gives capture changes the three-OS gate the project's one hard rule depends on.

Job names as they appear in the checks list: `ci / ci-complete`, `ci / build-test`, `ci / lint`, `ci / Adapter changes carry fixtures`, `fixtures / fixtures (macos-26)`.

## Artifact retention

| Artifact | Workflow | Retention | Why that long |
|---|---|---|---|
| `ci-xcresult` | `ci.yml`, on failure only | 7 days | Long enough to debug a red PR, short enough that nobody hoards `.xcresult` bundles |
| `live-probe-<os>.json` | `fixtures.yml`, always | 30 days | The follow-up job reads it in the same run; the 30 days are so a "when did this fingerprint change?" question has an answer covering a month of nightlies |
| `notarytool-logs` | `release.yml`, always | 30 days | Apple's own submission logs expire; this is the local copy that explains an `Invalid` result weeks later |
| `release-<version>` (zip, dmg, deltas, checksums, appcast) | `release.yml` | 90 days | A belt-and-braces copy of exactly what was published, independent of the Release page. Useful if a release is deleted or re-cut |

The repository default is 90 days (Settings ▸ Actions ▸ General ▸ Artifact and log retention); every upload above sets `retention-days` explicitly so the default drifting does not silently change behaviour.

> ℹ️ **Info:** Artifacts never contain notification content. The `.xcresult` from `ci.yml` contains fixture data, which is synthetic by construction and checked by the hygiene pass in `Scripts/verify_fixture.sh` before any fixture can be committed ([TESTING.md](../testing/TESTING.md)).

## What CI costs

Nothing, because the repository is public — but the number matters anyway, because macOS runners bill at a **10× multiplier** and that multiplier is the reason `ci.yml` is single-OS while `fixtures.yml` is a matrix.

| Workflow | Wall-clock per run | Multiplier | Billed minutes per run |
|---|---|---|---|
| `ci.yml` (`build-test` + `lint`, macOS) | ~12 min | 10× | ~120 |
| `ci.yml` (`changes`, `adapter-guard`, `ci-complete`, Linux) | ~1 min total | 1× | ~1 |
| `fixtures.yml` (3 legs × ~8 min) | ~24 runner-min | 10× | ~240 |
| `fixtures.yml` (`report-unknown-fingerprint`, Linux) | ~1 min | 1× | ~1 |
| `release.yml` | ~25 min (most of it waiting on notarization) | 10× | ~250 |
| `cask-bump.yml` | ~2 min | 1× | ~2 |

Full monthly arithmetic, the free-tier thresholds, and the ordered list of mitigations if minutes ever became a constraint are in [COST_ESTIMATION.md](../reference/COST_ESTIMATION.md). Three of those mitigations are already applied in the YAML above: path filtering via the `changes` job, `concurrency` with `cancel-in-progress`, and keeping the expensive three-OS matrix nightly instead of per-PR.

> 💡 **Tip:** The cheapest optimisation available is not a cache — it is putting a job on Linux. `adapter-guard`, `ci-complete`, `report-unknown-fingerprint` and the whole of `cask-bump.yml` run on `ubuntu-latest` for exactly that reason.

## Testing CI changes (act cannot help here)

`act` runs workflows locally in Docker containers. Docker containers are Linux. There is no macOS container, Apple's licence does not permit one, and no amount of configuration changes that.

So for Backglance, `act` can validate exactly two things: `adapter-guard` and `cask-bump.yml`, both Linux jobs. It cannot run `xcodebuild`, select an Xcode, exercise `security create-keychain`, run `notarytool`, or tell you whether `macos-26` still ships Xcode 26.2. Almost everything that matters here is untestable locally. What is done instead:

```bash
# 1. Syntax and Actions semantics, before pushing anything. Catches the 80 % case:
#    a typo, a bad indent, an unknown key. No runner, no network.
brew install actionlint && actionlint .github/workflows/*.yml

# 2. The Linux-only jobs, locally.
act pull_request -j adapter-guard

# 3. Everything else: on a branch, watching the real thing.
git switch -c ci/tighten-fixture-matrix && git push -u origin ci/tighten-fixture-matrix
gh workflow run fixtures.yml --ref ci/tighten-fixture-matrix -f reason="testing matrix change"
gh run watch
```

This is why `fixtures.yml` has `workflow_dispatch` with an input: a branch push plus a manual dispatch is the only real test loop for a macOS workflow. `release.yml` is the awkward one — it cannot be dry-run without a tag, and a tag means a real release. For a release-workflow change the practical approach is a pre-release tag (`v1.0.1-rc1`) on a branch with the `gh release create` and appcast steps temporarily guarded, and the manual path in [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md) as the fallback if the workflow turns out broken on the real tag.

> ❌ **Don't:** merge a CI change straight to `main` because "it's just YAML". A broken `release.yml` is discovered at the worst possible moment — mid-release, with a tag already pushed and a half-notarized build.

## Debugging a failed run

### Start with the annotations

`xcbeautify --renderer github-actions` puts compiler and test failures on the diff as annotations, and the Summary page of a failed run lists them before you open a single log. Most red `ci.yml` runs are answered there.

### Re-run with debug logging

The Actions UI's "Re-run jobs" menu has an **Enable debug logging** checkbox; it sets `ACTIONS_RUNNER_DEBUG` and `ACTIONS_STEP_DEBUG` for that run only, which is the right scope. From the terminal:

```bash
gh run list --workflow ci.yml --limit 5
RUN_ID=1234567890                          # from the list above

gh run view "$RUN_ID" --log-failed         # only the failing steps' logs
gh run rerun "$RUN_ID" --failed --debug    # re-run just the failed jobs, with debug logging
gh run watch "$RUN_ID"
```

Debug logging tells you which cache key was looked up and missed, why `paths-filter` decided a filter did not match, and what the runner's environment actually looked like.

### tmate is deliberately not used

The usual next step in a stuck CI investigation is `mxschmitt/action-tmate`, which drops an SSH session into the runner. Backglance does not use it on any workflow. The reason is `release.yml`: that job holds the Developer ID private key in a keychain and has `NOTARY_PASSWORD` and `SPARKLE_PRIVATE_KEY` in its step environments, so an interactive shell there is an interactive shell with the signing identity — and on a public repository a tmate session URL printed to a log is world-readable for as long as the session lives. Even with `limit-access-to-actor: true`, that trades a debugging convenience against the project's entire code-signing trust.

> ❌ **Don't:** add tmate "just temporarily" to debug a signing failure. If a shell on the runner is genuinely the only way forward, reproduce it locally instead: the release scripts are the same scripts, and [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md) is a working manual path.

### Reading the notarytool log from the artifact

An `Invalid` result never says why in the workflow output — the reason is in Apple's JSON log, which `Scripts/sign_and_notarize.sh` fetches with `xcrun notarytool log <submission-id>` and writes into its work directory. `release.yml` uploads that as `notarytool-logs` with `if: always()`, so it survives the failed run:

```bash
gh run download <run-id> --name notarytool-logs --dir /tmp/notary
jq '.issues[] | {severity, path, message}' /tmp/notary/notary-app-log.json
# {
#   "severity": "error",
#   "path": "Backglance-notary.zip/Backglance.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate",
#   "message": "The executable does not have the hardened runtime enabled."
# }
```

Each message maps to a fix in [PACKAGING_NOTARIZATION.md](./PACKAGING_NOTARIZATION.md#reading-notarytool-log-common-errors). If the artifact is missing entirely, the run failed before submission — check the keychain step first.

### The failures that actually happen

| Symptom | Likely cause | Fix |
|---|---|---|
| `xcodebuild: error: Unable to find a destination` | Runner image changed its default Xcode | The `xcode-select` step already pins it; check that `/Applications/Xcode_26.2.app` still exists on the image (`ls /Applications \| grep Xcode`) |
| `codesign` hangs, job hits the timeout | `security set-key-partition-list` was skipped or ran before the import | It must run *after* `security import` and before any `codesign` call |
| `error: No signing certificate "Developer ID Application" found` | The temp keychain is not in the search list, or the `.p12` round-trip is broken | Re-run the base64 round-trip check in [PACKAGING_NOTARIZATION.md](./PACKAGING_NOTARIZATION.md#exporting-a-p12-for-ci) |
| Notarization `401` / `Invalid credentials` | App-specific password rotated or revoked | Regenerate at appleid.apple.com, re-set `NOTARY_PASSWORD` |
| `cask-bump.yml` never runs after a release | `repository_dispatch` was sent with `github.token` | It must use `HOMEBREW_TAP_TOKEN`; see the [Secrets](#secrets) warning |
| Sparkle offers an update that 404s | The appcast reached `gh-pages` before the Release was published | The step order in `release.yml` prevents this; if it happened, publish the assets or revert the appcast commit immediately |
| A `fixtures.yml` leg is red but the fixture is unchanged | Runner image took a macOS point release | Read the `capture-degraded` issue the follow-up job opened, then [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md) |
| Cache restores but the build re-resolves everything | `Package.resolved` changed, or the runner label in the key changed | Expected; the next run on the same label is warm |

## Next Steps

- Setting up a fresh clone for the first time: [SETUP_GUIDE.md](../getting-started/SETUP_GUIDE.md).
- About to cut a release: read [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md) end to end once, before trusting `release.yml`.
- Adding a job that touches the capture path: the one hard rule in [CONTRIBUTING.md](../contributing/CONTRIBUTING.md) first, then [TESTING.md](../testing/TESTING.md) for what it should assert.

## Related Documentation

- [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md) — the release choreography `release.yml` automates, and the manual fallback
- [PACKAGING_NOTARIZATION.md](./PACKAGING_NOTARIZATION.md) — certificates, hardened runtime, `notarytool`, Sparkle keys, the DMG, the cask
- [PERFORMANCE_GUIDE.md](./PERFORMANCE_GUIDE.md) — the budgets the nightly performance job measures against
- [TESTING.md](../testing/TESTING.md) — test plan configurations, fixture harness, coverage gates, flaky-test policy
- [CONTRIBUTING.md](../contributing/CONTRIBUTING.md) — the adapter-and-fixtures rule `adapter-guard` enforces
- [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md) — what to do when a fingerprint changes
- [DEVELOPMENT_GUIDE.md](../getting-started/DEVELOPMENT_GUIDE.md) — `.swiftformat` and `.swiftlint.yml`, the rules the `lint` job enforces
- [SETUP_GUIDE.md](../getting-started/SETUP_GUIDE.md) — local toolchain, Xcode versions, optional tools
- [SECURITY.md](../security/SECURITY.md) — signing key and Sparkle key custody, what to do if a secret leaks
- [MAINTENANCE.md](../operations/MAINTENANCE.md) — the macOS beta calendar the nightly fixture run feeds
- [COST_ESTIMATION.md](../reference/COST_ESTIMATION.md) — macOS minutes, the 10× multiplier, mitigations in order
- [CHANGELOG.md](../../CHANGELOG.md) · [README.md](../../README.md)
