# Testing

Last Updated: 2026-08-18

This document is the test strategy for Backglance: what kinds of tests exist, where they live, what each one is allowed to touch, and how they run locally and in CI. The capture layer reads an undocumented system store, so most of the weight sits on synthetic fixtures and on parser fuzzing rather than on tests against a live machine. Everything here is written so that a contributor can run the whole suite without Full Disk Access and without a single real notification in the repository. For day-to-day conventions (style, git, review checklist) see [DEVELOPMENT_GUIDE.md](../getting-started/DEVELOPMENT_GUIDE.md); this file goes deeper on the tests themselves.

## Table of Contents

- [Test pyramid](#test-pyramid)
- [Test bundles and directories](#test-bundles-and-directories)
- [Fixture databases](#fixture-databases)
  - [Layout and manifest](#layout-and-manifest)
  - [Why fixtures are synthetic](#why-fixtures-are-synthetic)
  - [make_fixture.sh](#make_fixturesh)
  - [verify_fixture.sh](#verify_fixturesh)
- [Fixture test harness](#fixture-test-harness)
- [Parser fuzz tests](#parser-fuzz-tests)
- [Redaction-rule tests](#redaction-rule-tests)
- [UI tests: FDA onboarding](#ui-tests-fda-onboarding)
- [Timeline tests](#timeline-tests)
- [Search tests](#search-tests)
- [Digest tests](#digest-tests)
- [Retention tests](#retention-tests)
- [Migration tests](#migration-tests)
- [Performance tests](#performance-tests)
- [Snapshot tests](#snapshot-tests)
- [Test naming](#test-naming)
- [Running locally](#running-locally)
- [CI configuration](#ci-configuration)
- [Coverage targets](#coverage-targets)
- [Flaky-test policy](#flaky-test-policy)
- [Test data hygiene checklist](#test-data-hygiene-checklist)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Test pyramid

```
                 ┌──────────────┐
                 │   UI (XCUI)  │  onboarding, popover, timeline — few, slow, macos-26 only
                 ├──────────────┤
                 │  Integration │  fixture store → adapter → parser → redaction → archive
                 │  + fixtures  │  one run per fixture on every CI runner
                 ├──────────────┤
                 │     Unit     │  Core, Capture, Search — many, sub-second, in-memory archive
                 └──────────────┘
```

| Layer | Bundles | What it covers | Runs on |
|---|---|---|---|
| Unit | `BackglanceCoreTests`, `BackglanceCaptureTests`, `BackglanceSearchTests` | one type at a time; `Archive(inMemory: true)` when a database is needed; parser fuzz; redaction rules; query parser; rules engine; digest engine with injected clock | every PR, all three runners |
| Integration | `Integration/` folders in the same bundles | fixture store → `StoreSnapshot` → adapter → `RecordParser` → `OTPRedactor` → `Archive` end-to-end; hybrid search over a populated archive; retention job over a populated archive; migrations from archived databases | every PR, all three runners |
| UI | `BackglanceAppUITests` | XCUITest for onboarding (FDA denied / granted / skip), the status item's right-click menu and pause submenu, and the settings window's tabs and panes | every PR, `macos-26` only |
| Performance | `*PerformanceTests`, `SearchLatencyTests` | `XCTMetric` measurements against checked-in baselines | nightly, `macos-26` |

The pyramid is deliberately bottom-heavy. A UI test that fails tells you something is wrong; a unit test that fails tells you what. Anything that would need FDA on the CI runner is not a test — it is a manual step in [SETUP_GUIDE.md](../getting-started/SETUP_GUIDE.md).

## Test bundles and directories

```
Tests/
├── BackglanceCoreTests/
│   ├── Unit/            RetentionJobTests, RulesEngineTests, DigestEngineTests, OTPRedactorTests, ...
│   ├── Integration/     DigestFlowTests, ArchiveMigrationTests, RetentionOverArchiveTests, ExportServiceTests
│   └── Support/         Stubs.swift, TestClock.swift, SplitMix64.swift
├── BackglanceCaptureTests/
│   ├── Unit/            StoreFingerprintTests, RecordParserTests, RecordParserFuzzTests, StoreCursorTests
│   ├── Fixtures/        FixtureStoreTests (all fixtures), FixtureMacOS14/15/26Tests (per-OS filters)
│   ├── Integration/     CapturePipelineTests (fixture → archive), StoreWatcherTests (temp copy + appended rows)
│   └── Support/         FixtureManifest.swift, FixtureExpectation.swift, PlistBuilder.swift
├── BackglanceSearchTests/
│   ├── Unit/            QueryParserTests, FuzzyMatcherTests, FTSIndexTests, HybridRankingTests
│   ├── Integration/     HybridSearchOverArchiveTests, SemanticIndexTests (skipped when NLEmbedding unavailable)
│   └── Performance/     SearchLatencyTests
├── BackglanceUITests/            unit tests for the BackglanceUI package (models, copy, formatting)
├── BackglanceAppUITests/        XCUITest, driving the built app
│   ├── OnboardingFDATests.swift, StatusItemMenuTests.swift, SettingsWindowTests.swift
│   └── Support/         XCUIApplication+Backglance.swift
└── Fixtures/
    ├── SystemStore/macOS14|macOS15|macOS26/   store.db, manifest.json, expected.json   (SYNTHETIC)
    └── Archive/                                v1.sqlite, v2.sqlite, ...; archive-100k.sqlite (perf)
```

`Tests/Fixtures/` is read from the working copy, not copied into a test bundle: `BackglanceTestSupport.Fixtures` derives the path from its own `#filePath`, and exposes `Fixtures.systemStore` and `Fixtures.archive`. The reason is that these sources are built twice — as SwiftPM test targets (`swift test`) and as the `Backglance.xcodeproj` test targets the test plan runs — and `Bundle.module` exists only in the first, so a bundle-based lookup does not compile in Xcode at all. The fixtures are read-only inputs; a test that needs to write copies one into a temporary directory first. `Support/` files are shared through a small internal `BackglanceTestSupport` target so the SplitMix64 generator, the test clock, and stubs are written once.

> ⚠️ The two names are close and mean different things. `BackglanceUITests` is a *unit* test
> bundle for the `BackglanceUI` package — view models, copy, formatting — and needs no running
> app. `BackglanceAppUITests` is the XCUITest bundle, and it launches Backglance.
>
> **Running the XCUITest bundle locally needs Accessibility permission** for whatever launches
> it (Xcode, or the terminal running `xcodebuild`), or the runner fails with "Timed out while
> enabling automation mode" before any test code runs — which is why an
> `XCTSkip` cannot stand in for it. On a machine without that grant, run the rest with
> `-skip-testing:BackglanceAppUITests`. CI runners have it.

`Backglance.xctestplan` runs all five bundles in Debug. The plan has two configurations: `Fast`
(unit + fixtures, what a PR runs first) and `Full` (everything including UI). An Xcode test-plan
configuration varies *options*, not target membership, so the two are told apart by the
`BACKGLANCE_TEST_SCOPE` environment variable (`fast` / `full`) that each configuration sets; a suite
that only belongs in `Full` — the UI tests, the performance tests — skips itself when the variable
reads `fast`.

Each bundle is declared **twice**, over one set of source files:

- as a native Xcode unit-test target in `Backglance.xcodeproj`, which is what the test plan and
  `ci.yml` run (`xcodebuild test -scheme Backglance -testPlan Backglance`), and
- as a `.testTarget` in the owning package's `Package.swift`, which is what `swift test` runs from a
  package directory, without Xcode.

The duplication is deliberate: Xcode does not surface a local package's test targets as testables of
the containing project, so a project-level test plan cannot reach them. Both declarations compile
`Tests/<Bundle>/`, so there is exactly one copy of every test. Adding a *file* needs no change to
either declaration — the Xcode targets use synchronized folders and SwiftPM globs the directory —
but adding a *bundle* means adding it in both places.

## Fixture databases

A **fixture** is a synthetic copy of a system store: a SQLite file with the same tables and column layout as Apple's `usernoted` database for one macOS version, filled with generated data. Fixtures are the only way the capture layer is tested; there is no test path that reads `~/Library/Group Containers/`.

> ⚠️ **Warning:** The system store is undocumented. The layout the fixtures reproduce is what we have observed, not an API. Column names may change in any macOS release; the fingerprint + adapter + fixture strategy exists for that reason. When a new macOS breaks a fixture, regenerate the fixture and, if the schema changed, add an adapter — the process is in [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md).

### Layout and manifest

```
Tests/Fixtures/SystemStore/
├── macOS14/
│   ├── store.db          # synthetic usernoted-style database, WAL checkpointed, single file
│   ├── manifest.json     # what this fixture claims to represent
│   └── expected.json     # ParsedNotification[] the adapter + parser must produce
├── macOS15/
│   └── (same three files)
└── macOS26/
    └── (same three files)
```

`manifest.json` fields:

| Field | Type | Meaning |
|---|---|---|
| `os_version` | string | macOS release whose store layout this fixture imitates, e.g. `"26.5"` |
| `build` | string | build number of the machine the `.schema` was captured on, e.g. `"25F00"` (schema only was captured, never rows) |
| `created_at` | string | ISO-8601 UTC timestamp of generation |
| `generator_version` | string | version of `FixtureGenerator`; bumped when the generated content changes shape |
| `schema_sha256` | string | expected `StoreFingerprint.schemaHash` (64 hex chars) — the test recomputes it from `store.db` and compares |
| `dbinfo_version` | string or null | expected `StoreFingerprint.dbinfoVersion` |
| `adapter_id` | string | adapter that must resolve for this fixture, e.g. `"StoreAdapterV26"` |
| `seed` | integer | seed for the deterministic content generator |
| `record_count` | integer | rows in `record`; must equal `expected.json` length |
| `notes` | string | free text; always starts with `"Synthetic."` |

```json
{
  "os_version": "26.5",
  "build": "25F00",
  "created_at": "2026-08-17T09:00:00Z",
  "generator_version": "1.0.0",
  "schema_sha256": "6f1e2c1c0d8a4b7e9c3f5a2b1d4e6f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e",
  "dbinfo_version": "17",
  "adapter_id": "StoreAdapterV26",
  "seed": 20260817,
  "record_count": 250,
  "notes": "Synthetic. Schema captured with sqlite3 .schema on macOS 26.5; all rows generated from the seed. Never a copy of a real store."
}
```

`expected.json` is one object with two keys: `notifications`, an array of the `ParsedNotification` fields (`bundleID`, `uuid`, `title`, `subtitle`, `body`, `sender`, `threadID`, `category`, `deliveredAt` as Unix seconds, `presented`, `attachments`, `userInfo`), and `cursor` (`lastRecID`, `lastDeliveredDate`) — where a full read of the fixture must leave the cursor. Because generation is seeded, the same manifest always yields the same `store.db` and the same `expected.json`.

### Why fixtures are synthetic

A real store contains other people's messages. Copying one into a public repository — even a "cleaned" one — is not something we are willing to risk, and a fixture that depends on the contents of a real store would also be impossible to regenerate. So:

- The **schema** is captured with `sqlite3 <store> .schema` on a machine running that macOS. That reads DDL only, never rows.
- The **rows** are generated by `FixtureGenerator` (an executable target in `BackglanceCapture`) from a seeded RNG: bundle IDs from a fixed list (`com.apple.MobileSMS`, `com.apple.mail`, `com.tinyspeck.slackmacgap`, `com.example.demo`, `com.example.chat`), sender names from a word list, `example.com` addresses, `+1 555 01xx` phone numbers, lorem-style bodies, and OTP-shaped bodies whose digits come from `String(format: "%06d", rng.next() % 1_000_000)`.
- `verify_fixture.sh` refuses any fixture whose text looks like a real email, phone number, or one-time code outside the generator's own patterns.

> ❌ **Don't:** copy `~/Library/Group Containers/group.com.apple.usernoted/db2/db` anywhere, not to a scratch directory, not to a branch, not to an issue. The pre-commit hook in [DEVELOPMENT_GUIDE.md](../getting-started/DEVELOPMENT_GUIDE.md#git-workflow) rejects files named `db`, `db-wal`, `db-shm`; that is a backstop, not the rule.

### make_fixture.sh

Run on a machine with the target macOS. Two phases: capture the schema (DDL only; requires the terminal to have FDA), then build an empty database from that schema and fill it with generated rows.

```bash
#!/usr/bin/env bash
# Scripts/make_fixture.sh — (re)generate a SYNTHETIC system-store fixture.
#
#   Scripts/make_fixture.sh --os 26                      # regenerate from checked-in schema + manifest
#   Scripts/make_fixture.sh --os 27 --capture-schema     # on a macOS 27 machine: dump .schema (DDL only), then generate
#   Scripts/make_fixture.sh --os 27 --from 26 --seed 20260817 --records 250
#
# The script never reads a row from the live store. --capture-schema runs `sqlite3 -readonly ... .schema`
# and nothing else against it, and only when you ask for it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS_MAJOR=""; FROM=""; SEED=""; RECORDS=""; CAPTURE_SCHEMA=0

usage() {
  cat <<'EOF'
usage: make_fixture.sh --os <major> [--from <major>] [--seed <int>] [--records <n>] [--capture-schema]
  --os              target macOS major version (14, 15, 26, ...)
  --from            copy generator parameters from an existing fixture's manifest (default: --os)
  --seed            RNG seed (default: value from source manifest, else 20260817)
  --records         number of records to generate (default: from source manifest, else 250)
  --capture-schema  refresh Scripts/fixtures/schema_v<major>.sql from the live store's .schema (DDL only)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --os) OS_MAJOR="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    --records) RECORDS="$2"; shift 2 ;;
    --capture-schema) CAPTURE_SCHEMA=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$OS_MAJOR" ]] || { usage; exit 2; }

OUT_DIR="$REPO_ROOT/Tests/Fixtures/SystemStore/macOS${OS_MAJOR}"
SRC_MANIFEST="$REPO_ROOT/Tests/Fixtures/SystemStore/macOS${FROM:-$OS_MAJOR}/manifest.json"
SCHEMA_SQL="$REPO_ROOT/Scripts/fixtures/schema_v${OS_MAJOR}.sql"
LIVE_STORE="$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"
mkdir -p "$OUT_DIR" "$(dirname "$SCHEMA_SQL")"

# Phase 1 — schema. DDL only. Refuse to run on the wrong OS so a schema is never mislabelled.
if [[ "$CAPTURE_SCHEMA" -eq 1 ]]; then
  HOST_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
  if [[ "$HOST_MAJOR" != "$OS_MAJOR" ]]; then
    echo "error: --capture-schema for macOS $OS_MAJOR must run on macOS $OS_MAJOR (this is $HOST_MAJOR)" >&2
    exit 1
  fi
  if ! sqlite3 -readonly "file:${LIVE_STORE}?immutable=1" ".schema" > "$SCHEMA_SQL.tmp" 2>/dev/null; then
    echo "error: could not read the store schema. Grant Full Disk Access to your terminal (Settings ▸ Privacy & Security ▸ Full Disk Access) and retry." >&2
    rm -f "$SCHEMA_SQL.tmp"
    exit 1
  fi
  # .schema output is DDL. Belt and braces: fail if anything that is not CREATE/INDEX/-- slipped in.
  if grep -Ev '^(CREATE|--|$|\s|\)|;)' "$SCHEMA_SQL.tmp" | grep -q .; then
    echo "error: captured schema contains non-DDL lines; refusing to write it" >&2
    rm -f "$SCHEMA_SQL.tmp"
    exit 1
  fi
  mv "$SCHEMA_SQL.tmp" "$SCHEMA_SQL"
  echo "captured DDL -> $SCHEMA_SQL ($(grep -c '^CREATE' "$SCHEMA_SQL") statements)"
fi
[[ -f "$SCHEMA_SQL" ]] || { echo "error: no schema template $SCHEMA_SQL (run with --capture-schema on macOS $OS_MAJOR)" >&2; exit 1; }

# Phase 2 — empty database with that DDL, then synthetic rows.
rm -f "$OUT_DIR/store.db" "$OUT_DIR/store.db-wal" "$OUT_DIR/store.db-shm"
sqlite3 "$OUT_DIR/store.db" < "$SCHEMA_SQL"

# FixtureGenerator inserts app + record rows (bplist `data` blobs) with a seeded RNG,
# writes expected.json, and prints the manifest fields it decided (seed, record_count).
# It never reads ~/Library.
swift run --package-path "$REPO_ROOT/Packages/BackglanceCapture" -c release FixtureGenerator \
  --os "$OS_MAJOR" \
  --db "$OUT_DIR/store.db" \
  --source-manifest "$SRC_MANIFEST" \
  ${SEED:+--seed "$SEED"} \
  ${RECORDS:+--records "$RECORDS"} \
  --expected "$OUT_DIR/expected.json" \
  --manifest "$OUT_DIR/manifest.json" \
  --build "$(sw_vers -buildVersion)"

# Checkpoint so the fixture is a single file; then make it read-only in the tree.
sqlite3 "$OUT_DIR/store.db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
rm -f "$OUT_DIR/store.db-wal" "$OUT_DIR/store.db-shm"
chmod 0444 "$OUT_DIR/store.db"

echo "Wrote $OUT_DIR/{store.db,manifest.json,expected.json}"
echo "Now run: Scripts/verify_fixture.sh --os $OS_MAJOR"
```

`FixtureGenerator` computes `schema_sha256` with the same `StoreFingerprint.compute` the app uses (so bash and Swift can never disagree on normalisation), and writes `manifest.json` with `created_at`, `generator_version`, `record_count`, `seed`, `adapter_id` and `notes` filled in.

### verify_fixture.sh

Two jobs: prove the fixture still parses the way the manifest and `expected.json` say, and prove there is nothing personal in it.

```bash
#!/usr/bin/env bash
# Scripts/verify_fixture.sh — verify one synthetic fixture: fingerprint, adapter, parse, and hygiene.
#
#   Scripts/verify_fixture.sh --os 26
#   Scripts/verify_fixture.sh --os 26 --hygiene-only
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS_MAJOR=""; HYGIENE_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --os) OS_MAJOR="$2"; shift 2 ;;
    --hygiene-only) HYGIENE_ONLY=1; shift ;;
    -h|--help) echo "usage: verify_fixture.sh --os <major> [--hygiene-only]"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$OS_MAJOR" ]] || { echo "usage: verify_fixture.sh --os <major> [--hygiene-only]" >&2; exit 2; }

DIR="$REPO_ROOT/Tests/Fixtures/SystemStore/macOS${OS_MAJOR}"
for f in store.db manifest.json expected.json; do
  [[ -f "$DIR/$f" ]] || { echo "error: missing $DIR/$f" >&2; exit 1; }
done
[[ ! -e "$DIR/store.db-wal" && ! -e "$DIR/store.db-shm" ]] || { echo "error: fixture must be checkpointed (no -wal/-shm)" >&2; exit 1; }

# ---- 1. Hygiene: nothing that looks like a real email, phone number, or one-time code. ----
# The generator only ever produces example.com/example.org addresses and +1 555 01xx numbers.
FAIL=0
TEXT_DUMP="$(mktemp)"
trap 'rm -f "$TEXT_DUMP"' EXIT
# expected.json is the human-readable projection of every record; store.db `data` blobs are bplists,
# so also dump printable strings from the database file itself.
{ cat "$DIR/expected.json"; strings -n 6 "$DIR/store.db"; } > "$TEXT_DUMP"

# Emails not at an example domain.
if grep -Eio '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}' "$TEXT_DUMP" | grep -Eiv '@(example\.(com|org|net)|[a-z0-9-]+\.example)$' | grep -q .; then
  echo "hygiene   FAIL: non-example email address found"; FAIL=1
fi
# Phone numbers outside the 555-01xx fictional range (7+ digits with separators, optional +country).
if grep -Eo '\+?[0-9][0-9 ().-]{6,}[0-9]' "$TEXT_DUMP" | grep -Ev '555[ .-]?01[0-9]{2}$' | grep -Ev '^[0-9]{10,}$' | grep -q .; then
  echo "hygiene   FAIL: phone-number-like sequence outside +1 555 01xx range found"; FAIL=1
fi
# OTP-shaped bodies: a 4–8 digit run within 40 chars of a code keyword must be inside a generator template.
# The generator marks such records with the literal token "[synthetic-otp]" in userInfo, so any keyword+digits
# text in a record WITHOUT that marker is a red flag.
if command -v jq >/dev/null 2>&1; then
  jq -r '.[] | select(type=="object" and has("body")) | select((.userInfo["bg.fixture"] // "") != "[synthetic-otp]") | [.title, .subtitle, .body] | map(select(. != null)) | join(" ")' "$DIR/expected.json" \
    | grep -Eiq '(code|verification|passcode|otp|one-time|pin|login|kod|doğrulama|şifre|bestätigungscode|einmalpasswort).{0,40}\b[0-9]{4,8}\b|\b[0-9]{4,8}\b.{0,40}(code|verification|passcode|otp|one-time|pin|login|kod|doğrulama|şifre|bestätigungscode|einmalpasswort)' \
    && { echo "hygiene   FAIL: OTP-shaped text outside a generator template"; FAIL=1; }
else
  echo "hygiene   WARN: jq not installed; OTP template check skipped (CI has jq)"
fi
# Absolute home paths and real-looking Apple IDs.
if grep -Eq '/Users/[^/ ]+/' "$TEXT_DUMP"; then echo "hygiene   FAIL: /Users/<name>/ path found"; FAIL=1; fi
if grep -Eq '@(icloud|me|mac)\.com' "$TEXT_DUMP"; then echo "hygiene   FAIL: iCloud address found"; FAIL=1; fi

if [[ "$FAIL" -eq 1 ]]; then
  echo "hygiene   FAILED — this fixture must not be committed." >&2
  exit 1
fi
echo "hygiene   OK"
[[ "$HYGIENE_ONLY" -eq 1 ]] && exit 0

# ---- 2. Manifest sanity (cheap checks before spinning up Swift). ----
if command -v jq >/dev/null 2>&1; then
  RC_MANIFEST="$(jq -r '.record_count' "$DIR/manifest.json")"
  RC_EXPECTED="$(jq '[.[] | select(type=="object" and has("bundleID"))] | length' "$DIR/expected.json")"
  [[ "$RC_MANIFEST" == "$RC_EXPECTED" ]] || { echo "manifest  FAIL: record_count $RC_MANIFEST != expected.json $RC_EXPECTED" >&2; exit 1; }
  jq -e '.notes | startswith("Synthetic.")' "$DIR/manifest.json" >/dev/null || { echo "manifest  FAIL: notes must start with \"Synthetic.\"" >&2; exit 1; }
  echo "manifest  OK (record_count $RC_MANIFEST)"
fi

# ---- 3. Fingerprint + adapter + parse, using the same Swift code the app uses. ----
# FixtureStoreTests iterates every fixture; the per-OS class filters to one.
xcodebuild test \
  -scheme Backglance -testPlan Backglance -configuration Debug \
  -only-testing:"BackglanceCaptureTests/FixtureMacOS${OS_MAJOR}Tests" \
  -quiet 2>&1 | tail -n 20
echo "fixture   macOS${OS_MAJOR} OK"
```

Output on a healthy fixture:

```
hygiene   OK
manifest  OK (record_count 250)
Test Suite 'FixtureMacOS26Tests' passed
fixture   macOS26 OK
```

`verify_fixture.sh` is what CI runs in `fixtures.yml` for each OS and what the `adapter-guard` job in `ci.yml` requires before an adapter change can merge (see [CONTRIBUTING.md](../contributing/CONTRIBUTING.md#adapter-and-parser-changes-require-fixtures)).

## Fixture test harness

`FixtureStoreTests` iterates every directory under `Tests/Fixtures/SystemStore/` and asserts the same five things for each: the fingerprint matches the manifest, the registry resolves the expected adapter, `probe()` returns `.ok` with the manifest's count, every record parses to what `expected.json` says (including dates and the `presented` flag), and the final cursor matches. `FixtureMacOS14Tests`, `FixtureMacOS15Tests`, `FixtureMacOS26Tests` are one-line subclasses that restrict the run to a single fixture so `-only-testing` and `verify_fixture.sh --os` can target it.

```swift
import XCTest
import GRDB
@testable import BackglanceCapture
@testable import BackglanceCore

/// Support types decoded from manifest.json / expected.json (Tests/BackglanceCaptureTests/Support/).
struct FixtureManifest: Decodable {
    var osVersion: String
    var build: String
    var createdAt: String
    var generatorVersion: String
    var schemaSHA256: String
    var dbinfoVersion: String?
    var adapterID: String
    var seed: UInt64
    var recordCount: Int
    var notes: String

    enum CodingKeys: String, CodingKey {
        case osVersion = "os_version", build, createdAt = "created_at", generatorVersion = "generator_version"
        case schemaSHA256 = "schema_sha256", dbinfoVersion = "dbinfo_version", adapterID = "adapter_id"
        case seed, recordCount = "record_count", notes
    }

    var osMajor: Int { Int(osVersion.split(separator: ".").first ?? "0") ?? 0 }
}

struct ExpectedNotification: Decodable {
    var bundleID: String
    var uuid: UUID
    var title: String?
    var subtitle: String?
    var body: String?
    var sender: String?
    var threadID: String?
    var category: String?
    var deliveredAt: Double        // Unix seconds
    var presented: Bool
    var attachments: [AttachmentMeta]
    var userInfo: [String: String]
}

struct ExpectedCursor: Decodable { var lastRecID: Int64; var lastDeliveredDate: Double }

struct FixtureExpectation {
    var notifications: [ExpectedNotification]
    var cursor: ExpectedCursor

    /// expected.json is an array of notification objects with a trailing {"cursor": {...}} object.
    static func load(from url: URL) throws -> FixtureExpectation {
        struct Row: Decodable { var cursor: ExpectedCursor? }
        let data = try Data(contentsOf: url)
        let rows = try JSONDecoder().decode([Row].self, from: data)
        let cursorRow = try XCTUnwrap(rows.last?.cursor, "expected.json must end with a cursor object")
        let notificationsJSON = try JSONSerialization.jsonObject(with: data) as! [Any]   // tests may force-cast
        let onlyNotifications = try JSONSerialization.data(withJSONObject: Array(notificationsJSON.dropLast()))
        let notifications = try JSONDecoder().decode([ExpectedNotification].self, from: onlyNotifications)
        return FixtureExpectation(notifications: notifications, cursor: cursorRow)
    }
}

/// Iterates every fixture. Subclasses override `only` to restrict to one directory.
class FixtureStoreTests: XCTestCase {
    class var only: String? { nil }

    private static let root = Fixtures.systemStore

    private func fixtureDirectories() throws -> [URL] {
        let all = try FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("macOS") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let only = Self.only { return all.filter { $0.lastPathComponent == only } }
        XCTAssertFalse(all.isEmpty, "no fixtures found under \(Self.root.path)")
        return all
    }

    private struct Opened {
        let name: String
        let manifest: FixtureManifest
        let expected: FixtureExpectation
        let snapshot: StoreSnapshot
        let fingerprint: StoreFingerprint
    }

    private func open(_ dir: URL) throws -> Opened {
        let manifest = try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        let expected = try FixtureExpectation.load(from: dir.appendingPathComponent("expected.json"))
        // Same read-only, copied-snapshot path the app uses. Never opens the fixture writable.
        let snapshot = try StoreSnapshot.open(readOnlyCopyOf: dir.appendingPathComponent("store.db"))
        // Force the OS major to the fixture's so resolution is deterministic on any CI runner.
        let os = OperatingSystemVersion(majorVersion: manifest.osMajor, minorVersion: 0, patchVersion: 0)
        let fingerprint = try snapshot.read { db in try StoreFingerprint.compute(db, osVersion: os) }
        return Opened(name: dir.lastPathComponent, manifest: manifest, expected: expected, snapshot: snapshot, fingerprint: fingerprint)
    }

    func test_whenFixtureOpened_thenFingerprintMatchesManifest() throws {
        for dir in try fixtureDirectories() {
            let f = try open(dir)
            XCTAssertEqual(f.fingerprint.schemaHash, f.manifest.schemaSHA256, "\(f.name): schema hash drifted — regenerate with make_fixture.sh and explain the diff")
            XCTAssertEqual(f.fingerprint.dbinfoVersion, f.manifest.dbinfoVersion, "\(f.name): dbinfo version")
        }
    }

    func test_whenFingerprintResolved_thenExpectedAdapterAndProbeOK() throws {
        for dir in try fixtureDirectories() {
            let f = try open(dir)
            let adapter = try XCTUnwrap(StoreAdapterRegistry.resolve(fingerprint: f.fingerprint), "\(f.name): no adapter resolved")
            XCTAssertEqual(type(of: adapter).id, f.manifest.adapterID, "\(f.name): wrong adapter")
            XCTAssertTrue(type(of: adapter).supportedOS.contains(f.manifest.osMajor), "\(f.name): adapter does not claim this OS")

            let probe = try f.snapshot.read { db in try adapter.probe(db) }
            guard case .ok(let count) = probe else {
                return XCTFail("\(f.name): probe returned \(probe), expected .ok")
            }
            XCTAssertEqual(count, f.manifest.recordCount, "\(f.name): probe count")
        }
    }

    func test_whenAllRecordsParsed_thenTheyMatchExpectedJSON() throws {
        for dir in try fixtureDirectories() {
            let f = try open(dir)
            let adapter = try XCTUnwrap(StoreAdapterRegistry.resolve(fingerprint: f.fingerprint))
            let parser = RecordParser()

            let (parsed, lastCursor): ([ParsedNotification], StoreCursor?) = try f.snapshot.read { db in
                var cursor = StoreCursor.start
                var out: [ParsedNotification] = []
                // Page like the engine does; the adapter limits each page.
                while true {
                    let page = try adapter.records(after: cursor, in: db)
                    if page.isEmpty { break }
                    out += try page.map { try parser.parse($0) }
                    cursor = adapter.cursor(for: page[page.count - 1])
                }
                return (out, cursor)
            }

            XCTAssertEqual(parsed.count, f.expected.notifications.count, "\(f.name): record count")
            for (index, (got, want)) in zip(parsed, f.expected.notifications).enumerated() {
                let where_ = "\(f.name)[\(index)]"
                XCTAssertEqual(got.bundleID, want.bundleID, where_)
                XCTAssertEqual(got.uuid, want.uuid, where_)
                XCTAssertEqual(got.title, want.title, where_)
                XCTAssertEqual(got.subtitle, want.subtitle, where_)
                XCTAssertEqual(got.body, want.body, where_)
                XCTAssertEqual(got.sender, want.sender, where_)
                XCTAssertEqual(got.threadID, want.threadID, where_)
                XCTAssertEqual(got.category, want.category, where_)
                XCTAssertEqual(got.presented, want.presented, "\(where_): presented flag")
                XCTAssertEqual(got.deliveredAt.timeIntervalSince1970, want.deliveredAt, accuracy: 0.001, "\(where_): deliveredAt (Cocoa → Unix)")
                XCTAssertEqual(got.attachments.count, want.attachments.count, "\(where_): attachments")
                XCTAssertEqual(got.userInfo, want.userInfo, "\(where_): userInfo")
            }
            let cursor = try XCTUnwrap(lastCursor)
            XCTAssertEqual(cursor.lastRecID, f.expected.cursor.lastRecID, "\(f.name): cursor recID")
            XCTAssertEqual(cursor.lastDeliveredDate, f.expected.cursor.lastDeliveredDate, accuracy: 0.001, "\(f.name): cursor date")
        }
    }

    func test_whenDatesConverted_thenAllWithinFixtureWindow() throws {
        // Cocoa reference dates mistaken for Unix would land in 1970–2001; catch that class of bug.
        let lower = Date(timeIntervalSince1970: 1_600_000_000)   // 2020-09
        let upper = Date(timeIntervalSince1970: 2_000_000_000)   // 2033-05
        for dir in try fixtureDirectories() {
            let f = try open(dir)
            let adapter = try XCTUnwrap(StoreAdapterRegistry.resolve(fingerprint: f.fingerprint))
            let dates: [Date] = try f.snapshot.read { db in
                try adapter.records(after: .start, in: db).map { try RecordParser().parse($0).deliveredAt }
            }
            for d in dates {
                XCTAssertTrue(d > lower && d < upper, "\(f.name): deliveredAt \(d) outside plausible window")
            }
        }
    }

    func test_whenUnknownFingerprint_thenRegistryReturnsNil() {
        let bogus = StoreFingerprint(
            schemaHash: String(repeating: "0", count: 64),
            dbinfoVersion: nil,
            osVersion: OperatingSystemVersion(majorVersion: 99, minorVersion: 0, patchVersion: 0)
        )
        XCTAssertNil(StoreAdapterRegistry.resolve(fingerprint: bogus))
    }
}

final class FixtureMacOS14Tests: FixtureStoreTests { override class var only: String? { "macOS14" } }
final class FixtureMacOS15Tests: FixtureStoreTests { override class var only: String? { "macOS15" } }
final class FixtureMacOS26Tests: FixtureStoreTests { override class var only: String? { "macOS26" } }
```

Rules for fixture tests:

- Never construct a store path outside `Tests/Fixtures/`. A test that reads `~/Library/Group Containers/…` is rejected in review even if it is skipped in CI.
- If you change an adapter or the parser, regenerate the affected fixture's `expected.json` with `Scripts/make_fixture.sh` and explain the diff in the PR. A silently updated `expected.json` is a red flag.
- Fixture tests must pass on all three CI runners (`macos-14`, `macos-15`, `macos-26`), because the fixture pins the schema, not the host OS.
- Adding a fixture for a new macOS means: new directory, new one-line subclass, new row in the OS table of [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md).

## Parser fuzz tests

`RecordParser` decodes a binary plist that Apple never promised us. It must be impossible to crash it with a store record — corrupt, truncated, oversized, or simply from a macOS we have not seen. Every failure is a thrown `CaptureError.parseFailed(recID:reason:)`; a crash on parse would take the whole menu bar app down on every poll, since the same record is read again on the next tick.

The failure carries the `rec_id` and one of a small fixed set of reason strings — `not a property list`, `root is not a dictionary`, `empty payload`, `no delivered date`, and the `PlistGuard` shapes (`payload too large: N bytes`, `payload too deep: N`, `collection too large: N`, `string too long: N`) — never a value from the payload. The limits are `PlistGuard`'s (see [SECURITY.md](../security/SECURITY.md#hostile-store-content-the-plist-guard)): 64 KB per record, checked before anything is decoded, then depth 8, 512 entries per collection and 16 K characters per string on the decoded graph.

The generator is a `SplitMix64` in `Tests/…/Support/SplitMix64.swift`, shared by the fuzz tests, the redaction tests, and (via a copy in `FixtureGenerator`) fixture generation:

```swift
/// Deterministic 64-bit generator; same seed → same sequence on every platform and runner.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform Int in 0..<bound.
    mutating func int(below bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    /// Deterministic UUID from the stream.
    mutating func uuid() -> UUID {
        let a = next(), b = next()
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: a >> 56), UInt8(truncatingIfNeeded: a >> 48), UInt8(truncatingIfNeeded: a >> 40), UInt8(truncatingIfNeeded: a >> 32),
            UInt8(truncatingIfNeeded: a >> 24), UInt8(truncatingIfNeeded: a >> 16), UInt8(truncatingIfNeeded: a >> 8), UInt8(truncatingIfNeeded: a),
            UInt8(truncatingIfNeeded: b >> 56), UInt8(truncatingIfNeeded: b >> 48), UInt8(truncatingIfNeeded: b >> 40), UInt8(truncatingIfNeeded: b >> 32),
            UInt8(truncatingIfNeeded: b >> 24), UInt8(truncatingIfNeeded: b >> 16), UInt8(truncatingIfNeeded: b >> 8), UInt8(truncatingIfNeeded: b)
        ))
    }
}
```

The fuzz tests:

```swift
import XCTest
@testable import BackglanceCapture

final class RecordParserFuzzTests: XCTestCase {
    private let parser = RecordParser()

    // MARK: - Builders

    /// A valid record plist shaped like what we have observed (⚠️ undocumented keys), from a seed.
    private func validPlist(_ rng: inout SplitMix64) throws -> Data {
        let req: [String: Any] = [
            "titl": "Title \(rng.int(below: 1_000))",
            "subt": "Subtitle \(rng.int(below: 1_000))",
            "body": "Body text \(rng.int(below: 100_000)) lorem ipsum",
            "iden": rng.uuid().uuidString,
            "cate": "cat.\(rng.int(below: 10))",
            "thre": "thread-\(rng.int(below: 50))",
            "usda": ["k": "v", "url": "https://example.com/\(rng.int(below: 100))"] as [String: Any],
        ]
        let dict: [String: Any] = [
            "app": "com.example.demo",
            "date": Date(timeIntervalSinceReferenceDate: Double(700_000_000 + rng.int(below: 100_000_000))),
            "req": req,
        ]
        return try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
    }

    private func raw(_ plist: Data, recID: Int64 = 1) -> RawStoreRecord {
        RawStoreRecord(
            recID: recID,
            appIdentifier: "com.example.demo",
            uuid: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
            plistData: plist,
            deliveredDate: Date(timeIntervalSince1970: 1_755_421_200),
            requestDate: nil,
            presented: true,
            style: nil
        )
    }

    /// Either succeeds or throws CaptureError.parseFailed. Any other error type, or a crash, is a bug.
    private func assertParsesOrFailsCleanly(_ data: Data, _ context: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try parser.parse(raw(data))
        } catch let error as CaptureError {
            guard case .parseFailed = error else {
                return XCTFail("\(context()): wrong CaptureError case", file: file, line: line)
            }
        } catch {
            XCTFail("\(context()): unexpected error type \(type(of: error)): \(error)", file: file, line: line)
        }
    }

    // MARK: - Property: valid input always parses and round-trips

    func test_whenValidPlistFromAnySeed_thenParsesAndRoundTrips() throws {
        for seed in UInt64(1)...500 {
            var rng = SplitMix64(seed: seed)
            let data = try validPlist(&rng)
            let parsed = try parser.parse(raw(data, recID: Int64(seed)))
            let dict = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            let req = try XCTUnwrap(dict["req"] as? [String: Any])
            XCTAssertEqual(parsed.title, req["titl"] as? String, "seed \(seed)")
            XCTAssertEqual(parsed.body, req["body"] as? String, "seed \(seed)")
            XCTAssertEqual(parsed.threadID, req["thre"] as? String, "seed \(seed)")
            XCTAssertEqual(parsed.bundleID, "com.example.demo", "seed \(seed)")
        }
    }

    // MARK: - Mutations

    func test_whenRandomBytesFlipped_thenNeverCrashes() throws {
        var rng = SplitMix64(seed: 0x5EED_0001)
        let base = try validPlist(&rng)
        for iteration in 0..<3_000 {
            var bytes = [UInt8](base)
            let flips = 1 + rng.int(below: 8)
            for _ in 0..<flips {
                let i = rng.int(below: bytes.count)
                bytes[i] ^= UInt8(truncatingIfNeeded: rng.next() | 1)   // | 1 guarantees a change
            }
            assertParsesOrFailsCleanly(Data(bytes), "flip iteration \(iteration)")
        }
    }

    func test_whenTruncatedAtEveryLength_thenNeverCrashes() throws {
        var rng = SplitMix64(seed: 0x5EED_0002)
        let base = try validPlist(&rng)
        for length in 0..<base.count {
            assertParsesOrFailsCleanly(base.prefix(length), "truncated to \(length) bytes")
        }
        XCTAssertThrowsError(try parser.parse(raw(Data()))) { error in
            XCTAssertEqual(reason(of: error), "not a property list")
        }
    }

    func test_whenValuesHaveWrongTypes_thenFailsCleanlyNotCrash() throws {
        let wrongTyped: [[String: Any]] = [
            ["app": 42, "date": "not a date", "req": ["titl": 1, "body": [1, 2, 3]]],
            ["app": "com.example.demo", "date": Date(), "req": "a string, not a dict"],
            ["app": "com.example.demo", "date": Date(), "req": ["titl": Data([0xFF, 0x00]), "usda": ["k": 1.5]]],
            ["app": ["nested": "dict"], "date": Date(), "req": [:] as [String: Any]],
            ["req": ["body": NSNull()]],   // missing app and date entirely
        ]
        for (i, dict) in wrongTyped.enumerated() {
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
            assertParsesOrFailsCleanly(data, "wrong-typed case \(i)")
        }
    }

    func test_whenNestingPastTheGuardsLimit_thenThrowsTooDeep() throws {
        // 12 levels: past PlistGuard's depth 8, but still something Foundation will decode.
        // (At 2 000 levels PropertyListSerialization refuses first, with "not a property list" —
        // two independent defences, and neither may be removed on the strength of the other.)
        var inner: Any = "leaf"
        for _ in 0..<12 { inner = ["d": inner] }
        let dict: [String: Any] = ["app": "com.example.demo", "date": Date(), "req": ["usda": inner]]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        XCTAssertThrowsError(try parser.parse(raw(data))) { error in
            XCTAssertEqual(reason(of: error), "payload too deep: 9")
        }
    }

    func test_whenPayloadIsTenMegabytes_thenThrowsPayloadTooLargeBeforeDecoding() throws {
        // A 10 MB body inside an otherwise valid plist. The guard must reject on size, not try to decode.
        let big = String(repeating: "x", count: 10 * 1_024 * 1_024)
        let dict: [String: Any] = ["app": "com.example.demo", "date": Date(), "req": ["body": big]]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        XCTAssertGreaterThan(data.count, 10 * 1_024 * 1_024)

        let started = Date()
        XCTAssertThrowsError(try parser.parse(raw(data))) { error in
            XCTAssertEqual(reason(of: error), "payload too large: \(data.count) bytes")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05, "size check must happen before any decoding")
    }

    func test_whenRandomGarbage_thenThrowsNotAPlist() {
        var rng = SplitMix64(seed: 0x5EED_0003)
        for iteration in 0..<1_000 {
            let length = rng.int(below: 512)
            var bytes = [UInt8](repeating: 0, count: length)
            for i in 0..<length { bytes[i] = UInt8(truncatingIfNeeded: rng.next()) }
            assertParsesOrFailsCleanly(Data(bytes), "garbage iteration \(iteration)")
        }
    }
}
```

The seeds are constants on purpose: a failing iteration is reproducible from the seed and the iteration index in the assertion message. Change a seed only if you are adding a case, and say so in the commit.

> 💡 **Tip:** To reproduce a single failing iteration in the debugger, copy the seed and iteration from the message, then loop `iteration` times to advance the generator before building the bytes.

## Redaction-rule tests

`OTPRedactor` is on by default for Messages and Mail, so a false negative leaks a code into the archive and a false positive damages ordinary messages. Both directions are tested, and neither test file may contain a realistic code.

There are two layers, and they answer different questions:

| Suite | Target | Question |
|---|---|---|
| `OTPRedactorTests` | `BackglanceCoreTests` | Does the matcher behave, case by case, readably? |
| `OTPRedactorRuleTests` | `BackglanceCoreTests` | Does it hold over a seeded corpus — every keyword family × 40 codes, plus a false-positive corpus? |
| `PerAppOTPRedactionTests` | `BackglanceCaptureTests` | Does the *gate* let the matcher run on the right apps? |
| `RedactionInvariantTests` | `BackglanceCaptureTests` | Do the digits reach disk? |
| `RedactionEmbeddingTests` | `BackglanceSearchTests` | Do they reach the vectors? |

> ℹ️ **Note:** the sketch below predates the shipped API in two ways. `BackglanceCore` has no `ParsedNotification` — that type belongs to `BackglanceCapture`, so the rule tests take an `OTPRedactor.Content(title:subtitle:body:)` and read `result.content` / `result.event`. And `RedactionEvent` spells its pattern `patternId`, with no `original` property to assert `nil` on, because there is no property that could hold one.

> 🔒 **Security:** No test, fixture, or doc may contain a real one-time code. Codes in tests are produced by `SplitMix64` at run time and inserted into templates; the digits never appear in source. `verify_fixture.sh` and the review checklist enforce the same rule for fixtures.

```swift
import XCTest
@testable import BackglanceCore

final class OTPRedactorRuleTests: XCTestCase {
    private let redactor = OTPRedactor.default
    private let placeholder = "[code redacted]"

    /// One template per keyword family we support. `%@` is where the synthetic code goes.
    private static let templates: [(patternID: String, template: String)] = [
        ("otp.keyword.en", "Your verification code is %@"),
        ("otp.keyword.en", "%@ is your one-time passcode. Do not share it."),
        ("otp.keyword.en", "Use PIN %@ to log in"),
        ("otp.keyword.en", "Login code: %@"),
        ("otp.keyword.tr", "Doğrulama kodunuz: %@"),
        ("otp.keyword.tr", "Tek kullanımlık şifreniz %@"),
        ("otp.keyword.tr", "Giriş kodu %@"),
        ("otp.keyword.de", "Ihr Bestätigungscode lautet %@"),
        ("otp.keyword.de", "Einmalpasswort: %@"),
        ("otp.keyword.de", "Dein Code ist %@"),
    ]

    /// Ordinary messages that contain digit runs and must be left alone.
    private static let falsePositiveCorpus: [String] = [
        "See you at the 2026 reunion, same place as 2019",
        "Total charged: $1,249.00 — thanks for your order",
        "Call me back at +1 555 0100 when you land",
        "Order #48213 has shipped and arrives Thursday",
        "Your flight departs 18:45 from gate 22",
        "Meeting moved to room 4021, third floor",
        "Invoice 2026-0817 is due 2026-09-01",
        "Tracking number 1Z999AA10123456784",
        "The score was 3-1, then 4021 people left early",
        "ISBN 9780306406157 arrived today",
    ]

    /// Digits of the requested width from the seeded generator; never a literal in source.
    private func syntheticCode(width: Int, rng: inout SplitMix64) -> String {
        var limit: UInt64 = 1
        for _ in 0..<width { limit *= 10 }
        let digits = String(rng.next() % limit)
        return String(repeating: "0", count: width - digits.count) + digits
    }

    /// Any run of 4–8 digits once spaces and hyphens are removed.
    private func containsCodeShapedRun(_ text: String) -> Bool {
        let collapsed = text.replacingOccurrences(of: "[ -]", with: "", options: .regularExpression)
        return collapsed.range(of: #"\d{4,8}"#, options: .regularExpression) != nil
    }

    private func notification(bundleID: String = "com.apple.MobileSMS", body: String) -> ParsedNotification {
        var n = ParsedNotification.stub(bundleID: bundleID)
        n.body = body
        return n
    }

    // MARK: - True positives

    func test_whenTemplateWithSyntheticCode_thenPlaceholderPresentAndNoDigitRunRemains() {
        var rng = SplitMix64(seed: 20_260_817)
        for (patternID, template) in Self.templates {
            for _ in 0..<40 {
                let width = 4 + rng.int(below: 5)                       // 4...8
                var code = syntheticCode(width: width, rng: &rng)
                // Sometimes split the code the way real senders do: "123 456" / "123-456".
                if width >= 6, rng.int(below: 3) == 0 {
                    let mid = code.index(code.startIndex, offsetBy: width / 2)
                    let sep = rng.int(below: 2) == 0 ? " " : "-"
                    code = String(code[..<mid]) + sep + String(code[mid...])
                }
                let body = template.replacingOccurrences(of: "%@", with: code)

                let (out, event) = redactor.redact(notification(body: body))

                let redacted = out.body ?? ""
                XCTAssertTrue(redacted.contains(placeholder), "\(patternID): placeholder missing in \(redacted)")
                XCTAssertFalse(redacted.contains(code), "\(patternID): original code survived")
                XCTAssertFalse(containsCodeShapedRun(redacted), "\(patternID): a 4–8 digit run remains in \(redacted)")
                XCTAssertEqual(event?.kind, .otp, patternID)
                XCTAssertEqual(event?.patternID, patternID)
                XCTAssertNil(event?.original, "RedactionEvent must never carry the original text")
            }
        }
    }

    func test_whenWholeBodyIsOnlyACode_thenRedactedWithoutKeyword() {
        var rng = SplitMix64(seed: 20_260_818)
        for _ in 0..<50 {
            let code = syntheticCode(width: 4 + rng.int(below: 5), rng: &rng)
            let (out, event) = redactor.redact(notification(body: code))
            XCTAssertEqual(out.body, placeholder)
            XCTAssertEqual(event?.patternID, "otp.bare")
        }
    }

    func test_whenCodeInTitleAndBody_thenBothRedacted() {
        var rng = SplitMix64(seed: 20_260_819)
        let code = syntheticCode(width: 6, rng: &rng)
        var n = notification(body: "Your verification code is \(code)")
        n.title = "Code \(code)"
        let (out, _) = redactor.redact(n)
        XCTAssertFalse(containsCodeShapedRun(out.title ?? ""))
        XCTAssertFalse(containsCodeShapedRun(out.body ?? ""))
    }

    // MARK: - False positives

    func test_whenOrdinaryMessageWithNumbers_thenUntouched() {
        for body in Self.falsePositiveCorpus {
            let (out, event) = redactor.redact(notification(body: body))
            XCTAssertEqual(out.body, body, "false positive on: \(body)")
            XCTAssertNil(event, "false positive event on: \(body)")
        }
    }

    func test_whenKeywordFarFromDigits_thenUntouched() {
        // Keyword present but the digit run is more than 40 characters away.
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 3)   // 81 chars
        let body = "Please enter the code on the next screen. \(filler) Ref 48213."
        let (out, event) = redactor.redact(notification(body: body))
        XCTAssertEqual(out.body, body)
        XCTAssertNil(event)
    }

    func test_whenAppNotInRedactionList_thenUntouchedEvenWithKeyword() {
        var rng = SplitMix64(seed: 20_260_820)
        let code = syntheticCode(width: 6, rng: &rng)
        let body = "Your verification code is \(code)"
        for bundleID in ["com.example.demo", "com.tinyspeck.slackmacgap"] {
            let (out, event) = redactor.redact(notification(bundleID: bundleID, body: body))
            XCTAssertEqual(out.body, body, bundleID)
            XCTAssertNil(event, bundleID)
        }
    }

    // MARK: - Fixture cross-check

    func test_whenFixtureOTPTemplatesRedacted_thenNoDigitRunRemains() throws {
        // The generator marks OTP-shaped records with userInfo["bg.fixture"] == "[synthetic-otp]".
        let root = Fixtures.systemStore
        struct Row: Decodable { var bundleID: String?; var body: String?; var userInfo: [String: String]? }
        for os in ["macOS14", "macOS15", "macOS26"] {
            let data = try Data(contentsOf: root.appendingPathComponent("\(os)/expected.json"))
            let rows = try JSONDecoder().decode([Row].self, from: data)
            let otpRows = rows.filter { $0.userInfo?["bg.fixture"] == "[synthetic-otp]" }
            XCTAssertFalse(otpRows.isEmpty, "\(os): fixture should contain OTP-shaped records for redaction coverage")
            for row in otpRows {
                let (out, event) = redactor.redact(notification(bundleID: row.bundleID ?? "com.apple.MobileSMS", body: row.body ?? ""))
                XCTAssertNotNil(event, "\(os): OTP-shaped fixture record not redacted: \(row.body ?? "")")
                XCTAssertFalse(containsCodeShapedRun(out.body ?? ""), os)
            }
        }
    }
}
```

There is also a small Swift Testing suite (`OTPRedactorTests`) with a handful of readable single cases; it is shown in [DEVELOPMENT_GUIDE.md](../getting-started/DEVELOPMENT_GUIDE.md#swift-testing). The XCTest file above is the exhaustive one.

### The invariant tests

The rule tests prove the matcher replaces a code *in a string*. That is not the promise. The promise is that the digits are never **written** — and every place they could survive is a separate check.

`RedactionInvariantTests` (`BackglanceCaptureTests/Integration`) takes the OTP-shaped records the fixture generator marks with `userInfo["bg.fixture"] == "[synthetic-otp]"`, runs each fixture store through a real `CaptureEngine` with `PerAppOTPRedaction`, and writes into a **file-backed** archive rather than `Archive(inMemory: true)` — because the assertion is a byte scan of `archive.sqlite`, its `-wal` and its `-shm`. One scan covers the notification rows, the FTS postings and anything the write-ahead log is still holding, and it would fail just as loudly for a copy in a table nobody thought to query. Alongside it: no row's columns carry a code, the code is not searchable while an ordinary word from the same notification still is, the audit rows carry only `kind` and `pattern_id`, and `NotificationLogRef` renders none of it.

The suite's last test is the control. It repeats the run with redaction switched off for Messages and Mail and asserts the same codes **do** reach the archive — which is what makes the other five evidence that redaction ran, rather than evidence that the fixture had nothing to redact.

`RedactionEmbeddingTests` (`BackglanceSearchTests/Integration`) covers the leg capture cannot: semantic indexing is opt-in and never runs during capture, so the vectors do not exist at that point. It indexes a redacted row and scans the file again, and asserts `SemanticIndex.embeddableText` offers the placeholder rather than the digits.

Exports are not covered by either, because there is no exporter yet: the diagnostics export brings its own "excludes content" test ([3.8](../../TASKS.md)), and `ExportService` brings its own. Both read from `notifications`, which these suites prove is already redacted.

## UI tests: FDA onboarding

Onboarding is the one place where the app's behaviour depends on a system permission nothing can
grant — not a CI runner, and not the app itself. macOS has no prompt for `SystemPolicyAllFiles`,
so without a seam exactly one of "a Mac with the grant" and "a Mac without it" would be testable
on any given machine, whichever one it happens to be.

`FullDiskAccessProbe` therefore honours one environment variable, on the same **DEBUG-only**
terms as `BACKGLANCE_STORE_PATH`: a release build ignores it entirely, so no shipped Backglance
can be told it has a permission it does not have.

| Launch input | Effect |
|---|---|
| `BACKGLANCE_FAKE_FDA=granted` (env) | every probe returns `.granted` |
| `BACKGLANCE_FAKE_FDA=denied` (env) | every probe returns `.denied` |
| `BACKGLANCE_FAKE_FDA=storeMissing` (env) | every probe returns `.storeMissing` |
| `BACKGLANCE_ARCHIVE_PATH=…` (env) | the whole support directory moves, so a UI test never touches the archive of whoever is running it |
| `-onboarding.completedVersion 0` (argument) | the *argument domain* outranks anything written, so a developer whose real Backglance has completed setup still gets a first run |

The value is read on every probe rather than cached: a cached override would be a second code
path the tests exercise and users never do.

Screens and their accessibility identifiers: `onboarding.welcome`, `onboarding.whyFDA`,
`onboarding.whatWeRead`, `onboarding.grant` (with `onboarding.grant.status.waiting` /
`.granted` / `.storeMissing`, `onboarding.grant.openSettings`, `onboarding.grant.checkAgain`,
`onboarding.grant.relaunchHint`), `onboarding.done` (with `onboarding.import.progress`,
`onboarding.import.finished`, `onboarding.import.failed`). The footer is fixed across every
screen: `onboarding.back`, `onboarding.skip`, `onboarding.continue`. The degraded banner is
`capture.fdaBanner`, with `.openSettings`, `.checkAgain`, `.learnWhy` and `.dismiss`.

`BackglanceLaunch` in `Tests/BackglanceAppUITests/Support/` bundles all of that into one value,
so a test names the kind of Mac it wants rather than assembling launch arguments:

```swift
private func launch(fullDiskAccess: String, hasCompletedOnboarding: Bool = false) throws -> XCUIApplication {
    let launch = BackglanceLaunch(fullDiskAccess: fullDiskAccess, hasCompletedOnboarding: hasCompletedOnboarding)
    let app = try launch.app(archiveDirectory: XCTUnwrap(archiveDirectory))
    app.launch()
    return app
}
```

Assertions are by accessibility identifier, never by copy: these tests are about the flow, and a
reworded headline should not fail them ([ACCESSIBILITY.md](../reference/ACCESSIBILITY.md#identifiers-for-ui-tests)).
They also query on `.any` rather than on a role — `XCUIApplication.control(_:)`, not `buttons[…]`.
"Skip for now" is `.buttonStyle(.link)`, which macOS exposes with the link role, so a `buttons[…]`
query reports it as non-existent and the failure reads like a missing button rather than a role
mismatch.

What the suite covers: the three explanation screens in order and Continue blocked at Grant
without the permission; the grant acknowledged and setup finishing with it; Back; "Skip for now"
closing setup and leaving the app running (it is an agent app, so finishing is the *window*
going away, not the process); and setup not reopening on a Mac that has already been through it.

`StatusItemMenuTests` drives the menu bar item's right-click menu, which nothing outside the app
could read before: the menu is attached only for the duration of the click, and `screencapture`
cannot photograph it on a Mac whose terminal has no Screen Recording permission. XCUITest right-clicks
for real and the menu lands in the app's own accessibility tree, so the pause submenu's four choices
are asserted by title *and by order* (shortest first), and pausing is asserted to swap the submenu for
"Resume Capture" and to reach the item's accessibility label. Queries are scoped to the status item's
own menu rather than to `app.menuItems`, because the main menu bar has a "Settings…" and a "Quit
Backglance" of its own and an app-wide query would answer even when the context menu never opened.

Two things have to be forced for that suite, both through `BackglanceLaunch`. Capture must be
*running* — a faked FDA grant does not conjure a readable store, so it points
`BACKGLANCE_STORE_PATH` at the macOS 26 fixture; otherwise the item reports `noFullDiskAccess` and
the menu is a different menu. And pause lives in `UserDefaults` so that it survives a relaunch
(`PauseSettings.pausedUntilKey`), which `BACKGLANCE_ARCHIVE_PATH` does not redirect, so every launch
passes `-capture.pausedUntil 0` in the argument domain. Without it a pause left by an earlier run —
or by the developer's own Backglance — decides what the menu offers.

`SettingsWindowTests` lives next to it: the settings window's tabs, asserted to all be visible
(not folded into the toolbar's `»` overflow, which is how BACKGLANCE-249 shipped) and to each
switch to the pane they name, opened by the route a user has — the status item's menu.

Two suites are **planned, not written**: `PopoverTests` (open the popover from the status item,
assert the timeline paints) and `TimelineWindowTests` (open the window, scroll 200 rows, type in
the search field, expect filtered rows). When they are written they should reach the status item
the way `StatusItemMenuTests` does — through the app's own accessibility tree; there is no
popover-opening launch argument in the app today, and adding one would test a code path users
never take. UI tests run only on `macos-26` in CI because the XCUITest runner is the slowest part
of the matrix and the app's UI does not vary by OS.

### Reproducing the runner's time zone

The CI runner is in UTC and the maintainer is not, which is enough to make a green suite here a
red one there. `Stubs.epoch` is 2026-01-01 00:00:00 **UTC**, so rows seeded a second apart sit on
opposite sides of midnight for a UTC machine and land in two day sections instead of one — a test
that groups by day then counts headers gets a different answer depending on who ran it
(BACKGLANCE-252).

The fix belongs in the test: pin the calendar, the way `TimelineFixtures.istanbul` exists to be
pinned, rather than letting `.current` answer "where is midnight" differently per machine. To check
a suite for that dependence before CI does, add `TZ` to the test plan's configuration and run it:

```jsonc
// Backglance.xctestplan, temporarily — the environment in a configuration does reach the test
// host, where `TZ=UTC xcodebuild test …` does not (the same gap PerfGate documents for
// BACKGLANCE_PERF).
{ "key": "TZ", "value": "UTC" }
```

That turns "fails only on CI" into a local failure in one run, which is how the three failures in
BACKGLANCE-252 were diagnosed: one was genuinely time-zone dependent, and the other two were
sleep-then-assert tests that a busy machine could lose.

## Timeline tests

The timeline is tested at the view-model level, not through XCUITest, for everything except "does it render". `TimelineViewModel` takes an `Archive` and a clock and exposes pages of 200 rows.

| Test | Asserts |
|---|---|
| `TimelineViewModelTests.test_whenLoaded_thenFirstPageIs200NewestFirst` | pagination size, `delivered_at DESC` order |
| `…test_whenScrolledToEnd_thenNextPageAppendsWithoutDuplicates` | cursor-based paging, no `uuid` repeats |
| `…test_whenAppFilterSet_thenOnlyThatAppAndCountsMatch` | `apps` join, `notification_count` |
| `…test_whenNotificationMarkedRead_thenUnreadBadgeDecrements` | `is_read` update, badge = unread since last popover open, capped display `99+` |
| `…test_whenRuleHighlights_thenRowCarriesTriage` | `RulesEngine.evaluate` result attached to row; visual only |
| `…test_whenNotificationSoftDeleted_thenHiddenButNotPruned` | `is_deleted = 1` hides from timeline; row still in table until retention job |
| `…test_whenGroupedByThread_thenNewestPerThreadShown` | `thread_id` grouping toggle |
| `…test_whenPresentedFalse_thenMissedGlyphShown` | store's `presented == false` surfaces as "missed" marker |

All use `Archive(inMemory: true)` populated by `ArchivedNotification.stub(…)` with `example.com` bundle IDs; the timing tests inject `TestClock`.

## Search tests

Three layers, matching the engine ([SEARCH.md](../features/SEARCH.md)):

**Parser** — `QueryParserTests` are table-driven over `(input, expectedFTSMatch, expectedFilters)`:

```swift
import XCTest
@testable import BackglanceSearch

final class QueryParserTests: XCTestCase {
    private let parser = QueryParser()

    func test_whenFromAndBeforeAndTerms_thenFTSAndFiltersSplit() throws {
        let q = try parser.parse("from:slack before:2026-08-01 invoice")
        XCTAssertEqual(q.ftsMatch, "invoice*")
        XCTAssertEqual(q.filters.appHint, "slack")
        XCTAssertEqual(q.filters.before, ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z"))
        XCTAssertNil(q.filters.after)
    }

    func test_whenQuotedPhrase_thenPhraseMatchPreserved() throws {
        let q = try parser.parse("\"password reset\" from:mail")
        XCTAssertEqual(q.ftsMatch, "\"password reset\"")
        XCTAssertEqual(q.filters.appHint, "mail")
    }

    func test_whenUnknownOperator_thenTreatedAsText() throws {
        let q = try parser.parse("foo:bar baz")
        XCTAssertEqual(q.ftsMatch, "foo:bar* baz*")   // colon is not special unless the key is known
    }

    func test_whenFTSSpecialCharacters_thenEscaped() throws {
        let q = try parser.parse("c++ (draft) OR NOT")
        XCTAssertFalse(q.ftsMatch.contains("("), "parentheses must be quoted so FTS5 does not parse them")
        XCTAssertFalse(q.ftsMatch.contains(" OR "), "boolean operators are escaped, not interpreted")
    }

    func test_whenEmptyQuery_thenThrows() {
        XCTAssertThrowsError(try parser.parse("   "))
    }
}
```

**Ranking** — `HybridRankingTests` build a small archive with known documents and assert order, not scores: an exact FTS hit outranks a fuzzy-only hit; a semantic-only hit ranks below an FTS hit at default weights (FTS 0.4, semantic 0.5, fuzzy 0.3 as documented); a pinned notification with the same score wins the tie; results are unique by `uuid`. `FuzzyMatcherTests` check Levenshtein threshold 0.6 at word boundaries with diacritics folded (`unicode61 remove_diacritics 2` means `doğrulama` and `dogrulama` meet).

**Integration** — `HybridSearchOverArchiveTests` populate 5 000 rows via `Archive(inMemory: true)`, run 20 queries from a fixed list, and assert every hit's text actually contains a query term or a fuzzy neighbour. `SemanticIndexTests` are `XCTSkip`ped when `NLEmbedding.sentenceEmbedding(for: .english)` returns `nil` (older runner images).

## Digest tests

Neither `AwaySessionTracker` nor `DigestEngine` touches the wall clock in tests. The tracker takes an `AwayClock`, the engine takes a `now` closure, and the archive is `Archive(inMemory: true)`.

The tracker's 60-second merge gap is the reason the clock is injected rather than the events being fast: a test that waited it out would cost a minute per case. `ScriptedAwayClock` (in `AwaySessionTrackerTests`) is a clock the test moves, whose `sleep` polls it — one real millisecond per turn, returning the instant the test advances past the deadline.

```swift
// Tests/BackglanceCoreTests/Integration/DigestFlowTests.swift
let clock = ScriptedAwayClock(now: base)
let recorder = AwaySessionRecorder(archive: archive, policy: { DigestPolicy(defaults: defaults) })
let tracker = AwaySessionTracker(clock: clock, minDuration: { 300 }) { ended in
    recorder.record(ended)
}

await tracker.handle(.screenLocked)
clock.advance(by: 10 * 60)
try seedNotification(at: clock.now)
await tracker.handle(.screenUnlocked)
clock.advance(by: AwaySessionTracker.mergeGap + 1)   // let the session commit
```

`AwaySessionRecorder` is what makes this an integration test rather than a lookalike. Recording a session, linking what arrived during it, and building the digest are one ordered decision, and it lives in `BackglanceCore` precisely so a test can drive the same code the app delegate calls — wiring that only exists inside an `NSApplicationDelegate` is wiring nothing can check.

| Test | Asserts |
|---|---|
| `DigestFlowTests` — the headline case | lock → 10 min with one notification → unlock produces one session, one digest, `item_count == 1`, and the notification linked to that session |
| `DigestFlowTests` — never twice | a second `record` for the same session builds nothing; `pendingDigest()` returns the one digest, and nothing after it is dismissed |
| `DigestFlowTests` — under the threshold | a 2-minute session **is** recorded (that is what makes `is:missed` work) but earns no digest |
| `DigestFlowTests` — nothing arrived | a session with zero notifications writes no digest row at all |
| `DigestFlowTests` — "never" means never | `digest.threshold = never` records the session and builds nothing |
| `DigestFlowTests` — a disabled reason | a lock-only session is suppressed when `locked` is disabled; `{locked, focus}` still builds, because one live cause is enough |
| `DigestEngineTests` | the two selection signals, the ± 2 min skew edges, exclusions, VIP-first ranking, the shown cap, and `alreadyBuilt` inside the transaction |
| `DigestPolicyTests`, `DigestBannerPolicyTests` | the build gate and the banner gate, as pure functions |
| `DigestPresenterTests` | only an undismissed digest is ever surfaced, and the same digest keeps the same model |
| `AwaySessionTrackerTests` | overlapping lock + sleep collapse to one session with the earliest cause as primary |

`AwaySessionTracker.Event` is the tracker's input enum (`screenLocked`, `screenUnlocked`, `willSleep`, `didWake`, `focusChanged(active:)`, `presentingChanged(active:)`, `manualAway(active:)`). The production adapters that turn `DistributedNotificationCenter`, `NSWorkspace` and the DoNotDisturb JSON into these events are not unit-tested — they are covered by the manual checklist in [MISSED_DIGEST.md](../features/MISSED_DIGEST.md), and marked ⚠️ fragile there.

## Retention tests

`RetentionJobTests` (shown in [DEVELOPMENT_GUIDE.md](../getting-started/DEVELOPMENT_GUIDE.md#in-memory-archive)) cover the policy matrix; the integration variant runs the same job over a 20 000-row in-memory archive and asserts timing (< 500 ms) and that FTS rows for hard-pruned notifications are gone (`notifications_fts` count equals `notifications` count after `PRAGMA wal_checkpoint`).

| Case | Expected |
|---|---|
| global `days30`, no per-app override, 40-day-old row | soft-deleted, then hard-pruned on the next run after the grace period |
| per-app `forever` | never deleted regardless of age |
| per-app `never` | rows never inserted in the first place (`CaptureEngine` drops them; test at the engine level) |
| per-app `hours24` | 25-hour-old row soft-deleted |
| `is_pinned = 1` | exempt from retention until unpinned |
| soft-deleted by the user (`is_deleted = 1`) | hard-pruned on the next run regardless of age |
| `RedactionEvent` rows for a pruned notification | cascade-deleted (`ON DELETE CASCADE`) |
| `embeddings` row (v1.x) for a pruned notification | cascade-deleted |
| retention run while capture is mid-batch | serialised through `Archive`'s write queue; no lost rows (`DatabasePool` barrier test) |

## Migration tests

`ArchiveMigrationTests` open a copy of every archived database under `Tests/Fixtures/Archive/v*.sqlite` (each created by the version of the app whose `archive_version` it carries, with synthetic rows) and run the current migrator on it.

```swift
import XCTest
import GRDB
import BackglanceTestSupport
@testable import BackglanceCore

final class ArchiveMigrationTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bg-migrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: scratch)
    }

    private func archivedFixtures() throws -> [URL] {
        let root = Fixtures.archive
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("v") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func test_whenOldArchiveOpened_thenMigratesToCurrentAndKeepsRows() throws {
        for fixture in try archivedFixtures() {
            let copy = scratch.appendingPathComponent(fixture.lastPathComponent)
            try FileManager.default.copyItem(at: fixture, to: copy)

            // Count rows before with plain GRDB, then open through Archive (which migrates).
            var config = Configuration(); config.readonly = true
            let before = try DatabaseQueue(path: copy.path, configuration: config).read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notifications") ?? -1
            }

            let archive = try Archive(path: copy)
            XCTAssertEqual(try archive.schemaVersion(), ArchiveMigrations.currentVersion, fixture.lastPathComponent)
            XCTAssertEqual(try archive.countNotifications(includingDeleted: true), before, "\(fixture.lastPathComponent): rows lost in migration")

            // Every applied migration name is in the known ordered list; none skipped.
            let applied = try archive.appliedMigrations()
            XCTAssertEqual(applied, Array(ArchiveMigrations.allNames.prefix(applied.count)), fixture.lastPathComponent)

            // FTS is consistent after migration.
            let (n, fts) = try archive.read { db in
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notifications") ?? -1,
                 try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notifications_fts") ?? -1)
            }
            XCTAssertEqual(n, fts, "\(fixture.lastPathComponent): FTS out of sync after migration")
        }
    }

    func test_whenMigratedTwice_thenIdempotent() throws {
        for fixture in try archivedFixtures() {
            let copy = scratch.appendingPathComponent("twice-\(fixture.lastPathComponent)")
            try FileManager.default.copyItem(at: fixture, to: copy)
            _ = try Archive(path: copy)
            XCTAssertNoThrow(try Archive(path: copy), fixture.lastPathComponent)
        }
    }

    func test_whenFutureVersion_thenRefusesToOpenWithClearError() throws {
        let path = scratch.appendingPathComponent("future.sqlite")
        let archive = try Archive(path: path)
        try archive.write { db in
            try db.execute(sql: "UPDATE schema_meta SET value = ? WHERE key = 'archive_version'", arguments: [ArchiveMigrations.currentVersion + 1])
        }
        XCTAssertThrowsError(try Archive(path: path)) { error in
            guard case ArchiveError.newerThanApp(let found, let supported) = error else {
                return XCTFail("expected ArchiveError.newerThanApp, got \(error)")
            }
            XCTAssertEqual(found, ArchiveMigrations.currentVersion + 1)
            XCTAssertEqual(supported, ArchiveMigrations.currentVersion)
        }
    }
}
```

Adding a migration means adding a `v<N>.sqlite` fixture generated by the *previous* release (script: `Scripts/make_fixture.sh --archive --version <N-1> --count 500`, seeded, synthetic) so the upgrade path from every shipped version keeps being exercised. Fixtures under `Tests/Fixtures/Archive/` are subject to the same hygiene rules as system-store fixtures.

## Performance tests

Performance tests use `XCTMetric` (`XCTClockMetric`, `XCTMemoryMetric`, `XCTOSSignpostMetric`) and are skipped unless `PerfGate.isEnabled` — that is, unless the run uses the test plan's `Performance` configuration, the only thing that sets `BACKGLANCE_PERF=1`. They compare against checked-in `.xcbaseline` bundles per runner and fail at baseline + 50 %. The full list, the budgets, and the nightly policy are in [PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md#xctmetric-performance-tests); the short version:

| Test | Budget |
|---|---|
| `SearchLatencyTests.testFTSCommonTermUnder50msP95` | 50 ms |
| `SearchLatencyTests.testHybridUnder250msP95` | 250 ms |
| `ImportPerformanceTests.testImport10k` | 10 s for 10 000 store records |
| `PopoverLaunchTests.testFirstPaint` | 100 ms (`os_signpost` `popover.open`) |
| `MemoryFootprintTests.testIdle` / `.testWindowAt100k` | 60 MB / 150 MB RSS |
| `ArchiveSizeTests.testBytesPerNotification` | ~1 KB, fail > 2 KB |
| `RecordParserPerformanceTests.testParse10kRecords` | < 1 s (parser must not be the import bottleneck) |

Perf tests do not run on PRs; hosted-runner variance is larger than the budgets.

## Snapshot tests

Not in v1.0. Views have `#Preview`s using `PreviewData` and are reviewed by eye. Snapshot testing (image diffs of `TimelineView`, `DigestView`, settings) is on the list for v1.x once the visual design settles; introducing it earlier would mean re-recording snapshots every week. When it lands it will use a small in-tree renderer over `NSHostingView`, no third-party dependency, and snapshots will be recorded on `macos-26` only.

## Test naming

- Files: `<TypeUnderTest>Tests.swift`; fuzz files `<Type>FuzzTests.swift`; perf files `<Area>PerformanceTests.swift` or `<Area>LatencyTests.swift`.
- XCTest methods: `test_when<Condition>_then<Outcome>` — `test_whenSessionShorterThanFiveMinutes_thenNoDigest`. The `when` clause names the input, the `then` clause names the observable result. No `testFoo1`, `testFoo2`.
- Swift Testing: `@Suite("<Type>")` and `@Test("<plain sentence>")`, method names in lowerCamelCase describing the case.
- One assertion subject per test; several `XCTAssert`s about that subject are fine. Loops over cases include the case in the assertion message so a failure is locatable.
- Test doubles: `Stub<Type>` for canned values, `Spy<Type>` when the test asserts on calls, `Fake<Type>` for working in-memory implementations (`FakeFDAProbe`). No `Mock` prefix.
- Fixtures and stubs always use `example.com`/`example.org` bundle IDs and addresses, `+1 555 01xx` numbers, and lorem text.

## Running locally

All commands from the repository root. The full table of everyday commands is in [DEVELOPMENT_GUIDE.md](../getting-started/DEVELOPMENT_GUIDE.md#useful-commands).

```bash
# Everything the PR job runs (unit + fixtures + integration), pretty output
xcodebuild test -scheme Backglance -testPlan Backglance -testPlanConfiguration Fast 2>&1 | xcbeautify

# Everything including UI tests
xcodebuild test -scheme Backglance -testPlan Backglance -testPlanConfiguration Full 2>&1 | xcbeautify

# One package, fast, no Xcode UI
swift test --package-path Packages/BackglanceCore
swift test --package-path Packages/BackglanceCapture --filter RecordParserFuzzTests

# One test class / one test
xcodebuild test -scheme Backglance -testPlan Backglance -only-testing:BackglanceCaptureTests/FixtureMacOS26Tests
xcodebuild test -scheme Backglance -testPlan Backglance \
  -only-testing:BackglanceCoreTests/OTPRedactorRuleTests/test_whenOrdinaryMessageWithNumbers_thenUntouched

# UI tests only
xcodebuild test -scheme Backglance -testPlan Backglance -only-testing:BackglanceUITests

# Fixtures: verify one / all
Scripts/verify_fixture.sh --os 26
for os in 14 15 26; do Scripts/verify_fixture.sh --os "$os"; done

# Hygiene only (fast; what the pre-push hook runs when Tests/Fixtures changed)
for os in 14 15 26; do Scripts/verify_fixture.sh --os "$os" --hygiene-only; done

# Perf suite (local, quiet machine, plugged in). The Performance configuration is
# what sets BACKGLANCE_PERF; an `env BACKGLANCE_PERF=1` prefix does not reach the
# test host and every budget would skip.
xcodebuild test -scheme Backglance -testPlan Backglance \
  -only-test-configuration Performance \
  -only-testing:BackglanceSearchTests/SearchLatencyTests 2>&1 | xcbeautify

# Coverage report (what CI uploads as an artifact)
xcodebuild test -scheme Backglance -testPlan Backglance -testPlanConfiguration Fast \
  -enableCodeCoverage YES -resultBundlePath build/Fast.xcresult 2>&1 | xcbeautify
xcrun xccov view --report --only-targets build/Fast.xcresult
```

> 💡 **Tip:** `swift test --package-path Packages/BackglanceCapture` runs the fixture tests too, because `Tests/Fixtures` is a package resource. It is the fastest loop when working on an adapter.

If a test needs the app to have FDA, it is not a test. Run the manual checklist in [SETUP_GUIDE.md](../getting-started/SETUP_GUIDE.md#verifying-capture-works) instead.

## CI configuration

The workflows are documented in full in [CI_CD.md](../deployment/CI_CD.md). What matters for tests:

| Workflow | Trigger | Runners | Runs |
|---|---|---|---|
| `ci.yml` `build-test` | every PR and push to `main` | `macos-26` | Builds the app and all four test bundles, runs the `Backglance` test plan (unit + integration + `BackglanceUITests`); coverage gate |
| `ci.yml` `lint` | every PR and push to `main` | `macos-26` | `swiftformat --lint` + `swiftlint --strict` (includes the no-content-in-logs rule) |
| `ci.yml` `adapter-guard` | every PR | `ubuntu-latest` | fails if `Adapters/**` or `RecordParser*` changed without a change under `Tests/Fixtures/SystemStore/**` (see [CONTRIBUTING.md](../contributing/CONTRIBUTING.md#adapter-and-parser-changes-require-fixtures)) |
| `ci.yml` `ci-complete` | every PR and push to `main` | `ubuntu-latest` | Aggregates the jobs above into the single required status check, so docs-only PRs are not blocked by a check that never reports |
| `perf.yml` `budgets` | nightly `schedule`; PRs touching the gate, the test plan or the workflow; `workflow_dispatch` | `macos-26` | `-only-test-configuration Performance` (the only thing that sets `BACKGLANCE_PERF=1`) against the budgets; fails if any of its tests were *skipped* rather than run; opens a `perf` issue on failure |
| `fixtures.yml` | every PR touching `Tests/Fixtures/**`, `Packages/BackglanceCapture/**`, `Scripts/*fixture*`; **nightly**; `workflow_dispatch` | `macos-14`, `macos-15`, `macos-26` | `verify_fixture.sh --os` for all three fixtures on every runner; on `macos-26` additionally regenerates each fixture with its manifest seed and fails on any diff (non-determinism guard); nightly compares each runner's own store `schemaHash` (DDL only, never rows, only if FDA can be granted to the runner) and opens a "Store schema drift on macOS X.Y" issue on mismatch |

The nightly fixture run is the early-warning system for macOS point releases: GitHub updates runner images within days of a release, so a schema change shows up as a red nightly before most users have updated. `DEVELOPER_DIR` is pinned per runner (Xcode 16.2 on `macos-14`/`macos-15`, Xcode 26.x on `macos-26`).

> ℹ️ **Info:** `ci.yml` builds on `macos-26` only; the three-OS matrix lives in `fixtures.yml`, where it runs one test bundle instead of a whole build. The tests themselves are OS-independent — a fixture pins the schema, not the host — so a per-OS build would buy little and cost triple. See [CI_CD.md](../deployment/CI_CD.md#what-ci-costs).

The fixture matrix is required for merge on capture PRs; a single red leg blocks. The perf and nightly jobs do not block merges but do block the next release until triaged ([DEPLOYMENT_GUIDE.md](../deployment/DEPLOYMENT_GUIDE.md)).

## Coverage targets

Coverage is measured by `xccov` on the `macos-26` leg and posted as a PR comment; the gate is enforced by a small script (`Scripts/coverage_gate.sh`, called from `ci.yml`) that reads the `xcresult`.

| Target | Minimum line coverage | Why this number |
|---|---|---|
| `BackglanceCore` | **80 %** | business logic; the untested remainder is mostly `Archive` file-system plumbing |
| `BackglanceCapture` — `Adapters/`, `RecordParser`, `StoreFingerprint`, `StoreCursor` | **90 %** | this is the code that talks to the undocumented store; fixtures + fuzz should reach nearly everything |
| `BackglanceCapture` — rest (`StoreWatcher`, `StoreLocation`, `EnrichmentService`) | 60 % | wraps system APIs (`DispatchSource`, `NSWorkspace`); tested via fakes where practical |
| `BackglanceSearch` | 75 % | `SemanticIndex` is partly untestable on runners without `NLEmbedding` |
| `BackglanceUI`, app target | no gate | covered by UI tests and previews; coverage numbers here are not meaningful |

A PR that lowers a gated package below its target fails `ci.yml`. A PR that lowers coverage without crossing the gate gets a comment, not a failure. Coverage is a floor, not a goal: a fixture that pins behaviour is worth more than a unit test that pins implementation.

## Flaky-test policy

- A test that fails and then passes on re-run without a code change is flaky. CI does not auto-retry; a red run is a red run.
- **First occurrence:** open an issue labelled `flaky-test` with the test name, runner, and log excerpt. Re-run the job manually.
- **Second occurrence within 30 days:** the test is quarantined — moved to the `Quarantine` test plan configuration (which runs but does not gate) in a PR that links the issue. Quarantine is a maximum of 30 days; after that the test is fixed or deleted.
- **Fixing:** the usual causes here are wall-clock use (inject the clock), real `Date()` in stubs, `DispatchSource` timing in `StoreWatcherTests` (use the fake watcher or generous `XCTestExpectation` timeouts of ≥ 5 s, never `sleep`), UI test timing (`waitForExistence`, never fixed delays), and shared `UserDefaults` (always `--uitest-reset`).
- Fixture tests are never quarantined. A flaky fixture test means non-determinism in the generator or the parser, and that is a bug in the code under test.
- Perf tests are excluded from this policy; their variance is handled by the +50 % threshold and the nightly-only schedule.

## Test data hygiene checklist

Go through this before pushing anything under `Tests/`:

- [ ] No file named `db`, `db-wal`, `db-shm`, `archive.sqlite*` is staged (the pre-commit hook checks; you check first).
- [ ] No test constructs a path under `~/Library/Group Containers/`, `~/Library/Application Support/Backglance/`, or `~/Library/DoNotDisturb/`. Tests use `Fixtures`, `Archive(inMemory:)`, or `FileManager.default.temporaryDirectory`.
- [ ] Bundle IDs in stubs are `com.example.*` or the well-known Apple/third-party IDs the redactor and exclusion list need (`com.apple.MobileSMS`, `com.apple.mail`, `com.tinyspeck.slackmacgap`, `com.1password.1password`).
- [ ] Email addresses end in `example.com` / `example.org`; phone numbers are `+1 555 01xx`; names are `<Word> Example`.
- [ ] No literal 4–8 digit code in source next to a keyword like code/verification/PIN. Generate with `SplitMix64` at run time.
- [ ] Any new fixture passed `Scripts/verify_fixture.sh --os <n>` locally, including the hygiene section, and `manifest.json` `notes` starts with `Synthetic.`.
- [ ] Any new fixture was generated on a machine running that macOS with `--capture-schema`, and the PR says which build (`sw_vers -buildVersion`) — the schema, never the rows.
- [ ] `expected.json` diffs are explained in the PR description (what changed in the parser or adapter and why the expectation moved).
- [ ] No test asserts on log output that would contain notification content; log assertions use `no_content_in_logs` patterns only.
- [ ] Screenshots attached to UI test failures (`XCTAttachment`) come from the fixture-fed app, never from a build pointed at a real store.
- [ ] Anything copied from a real machine for debugging (a schema dump, a `PRAGMA table_info` listing) is DDL/metadata only, and lives in `Scripts/fixtures/schema_v<n>.sql`, not in a test.

## Next Steps

- Run `Scripts/verify_fixture.sh --os 26` once to see the pipeline end to end, then read [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md) for what happens when a fixture goes red.
- If you are adding an adapter, start from the fixture (make it, verify it, watch `FixtureStoreTests` fail), then write the adapter until it passes. The PR rules are in [CONTRIBUTING.md](../contributing/CONTRIBUTING.md#adapter-and-parser-changes-require-fixtures).
- If you are touching redaction, run `OTPRedactorRuleTests` with a few extra seeds locally before opening the PR; keep the false-positive corpus growing.

## Related Documentation

- [Development Guide](../getting-started/DEVELOPMENT_GUIDE.md) — conventions, git workflow, writing tests, review checklist
- [Setup Guide](../getting-started/SETUP_GUIDE.md) — building, FDA, fixture setup, running against a fixture
- [Quick Start](../getting-started/QUICK_START.md) — clone to running app
- [Architecture](../architecture/ARCHITECTURE.md) — packages and the capture pipeline under test
- [Database Schema](../architecture/DATABASE_SCHEMA.md) — archive DDL, migrations, fixture layout
- [OS Compatibility Playbook](../architecture/OS_COMPATIBILITY_PLAYBOOK.md) — adapters, fingerprints, new macOS releases
- [Capture](../features/CAPTURE.md) — the capture layer the fixtures exercise
- [Search](../features/SEARCH.md) — query language and hybrid weights the search tests pin
- [Missed Digest](../features/MISSED_DIGEST.md) — away sessions and the digest the engine tests cover
- [Privacy Controls](../features/PRIVACY_CONTROLS.md) — redaction, exclusion list, panic wipe
- [Permissions & Privacy](../features/PERMISSIONS_PRIVACY.md) — FDA onboarding the UI tests walk through
- [CI/CD](../deployment/CI_CD.md) — `ci.yml`, `fixtures.yml`, runners, secrets
- [Performance Guide](../deployment/PERFORMANCE_GUIDE.md) — `XCTMetric` tests, budgets, nightly policy
- [Deployment Guide](../deployment/DEPLOYMENT_GUIDE.md) — release checklist that depends on green fixtures
- [Monitoring & Logging](../operations/MONITORING_LOGGING.md) — `no_content_in_logs`, parse-failure logging
- [Security](../security/SECURITY.md) — threat model, why fixtures are synthetic
- [Contributing](../contributing/CONTRIBUTING.md) — PR process, adapter guard, contributing a fixture
- [Accessibility](../reference/ACCESSIBILITY.md) — identifiers the UI tests rely on
