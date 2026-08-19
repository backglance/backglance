#!/usr/bin/env bash
# Scripts/verify_fixture.sh — verify one synthetic fixture: hygiene, manifest, fingerprint, parse.
#
#   Scripts/verify_fixture.sh --os 26
#   Scripts/verify_fixture.sh --os 26 --hygiene-only
#   Scripts/verify_fixture.sh --live                  # report this Mac's own store fingerprint
#
# Two jobs: prove the fixture still parses the way its manifest and expected.json claim,
# and prove there is nothing personal in it. The second job is why this script exists at
# all — a fixture is committed to a public repository, and "we checked" has to mean
# something more than a person skimming a JSON file.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS_MAJOR=""; HYGIENE_ONLY=0; LIVE=0

usage() {
  cat <<'EOF'
usage: verify_fixture.sh --os <major> [--hygiene-only]
       verify_fixture.sh <path/to/store.db>          # hygiene only, for the pre-commit hook
       verify_fixture.sh --live                      # report this Mac's own store fingerprint
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --os) OS_MAJOR="$2"; shift 2 ;;
    --hygiene-only) HYGIENE_ONLY=1; shift ;;
    --live) LIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    # A bare path is how Scripts/hooks/pre-commit calls this: it is about to commit a
    # fixture and wants the synthetic-data check, not the whole verification.
    /*|./*|Tests/*)
      OS_MAJOR="$(basename "$(dirname "$1")" | sed -E 's/^macOS//')"
      HYGIENE_ONLY=1
      shift
      ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# The schema hash, computed by the app's own StoreFingerprinter rather than reimplemented
# here.
#
# ⚠️ The normalization has to agree byte-for-byte with what capture computes at runtime —
# one space apart is a different hash, and a different hash reads as "macOS changed the
# store". The only way to guarantee that is to have one implementation, so this shells out
# to FixtureGenerator instead of mirroring the logic in awk.
schema_hash() {
  swift run --package-path "$REPO_ROOT/Packages/BackglanceCapture" FixtureGenerator \
    --print-fingerprint --db "$1" 2> /dev/null | cut -d" " -f1
}

# ---- --live: what this Mac's own store looks like, without reading a single row. ----
if [[ "$LIVE" -eq 1 ]]; then
  LIVE_STORE="$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"
  if [[ ! -r "$LIVE_STORE" ]]; then
    echo "live      no store readable at that path — grant Full Disk Access to your terminal"
    exit 0
  fi
  # Copied first, exactly as capture does: Apple's live database is never opened.
  SNAPSHOT_DIR="$(mktemp -d)"
  trap 'rm -rf "$SNAPSHOT_DIR"' EXIT
  cp "$LIVE_STORE" "$SNAPSHOT_DIR/db"
  [[ -f "${LIVE_STORE}-wal" ]] && cp "${LIVE_STORE}-wal" "$SNAPSHOT_DIR/db-wal"
  HASH="$(schema_hash "$SNAPSHOT_DIR/db")"
  KNOWN="$REPO_ROOT/Packages/BackglanceCapture/Sources/BackglanceCapture/Resources/KnownFingerprints.json"
  echo "live      macOS $(sw_vers -productVersion) schema ${HASH:0:12}"
  if command -v jq > /dev/null 2>&1 && jq -e --arg h "$HASH" 'any(.adapters[]?[]?; . == $h)' "$KNOWN" > /dev/null; then
    echo "live      known fingerprint"
  else
    echo "live      UNKNOWN fingerprint — regenerate the fixture for this macOS (Scripts/make_fixture.sh)"
  fi
  exit 0
fi

[[ -n "$OS_MAJOR" ]] || { usage >&2; exit 2; }

DIR="$REPO_ROOT/Tests/Fixtures/SystemStore/macOS${OS_MAJOR}"
for f in store.db manifest.json expected.json; do
  [[ -f "$DIR/$f" ]] || { echo "error: missing $DIR/$f" >&2; exit 1; }
done
if [[ -e "$DIR/store.db-wal" || -e "$DIR/store.db-shm" ]]; then
  echo "error: fixture must be checkpointed (no -wal/-shm beside store.db)" >&2
  exit 1
fi

# ---- 1. Hygiene: nothing that looks like a real address, number, path or code. ----
FAIL=0
TEXT_DUMP="$(mktemp)"
trap 'rm -f "$TEXT_DUMP"' EXIT
# expected.json is the readable projection of every record; the `data` blobs are binary
# plists, so the database's own printable strings are scanned too.
{ cat "$DIR/expected.json"; strings -n 6 "$DIR/store.db"; } > "$TEXT_DUMP"

# Addresses: anything whose domain is not an example.* one. The match is tested for
# "example." rather than anchored, because a match taken out of a binary plist has the
# next field's bytes glued to it — the check has to survive that or it cries wolf on every
# fixture. The shape is strict (a real TLD) so that binary noise like "x@bplist00" is not
# mistaken for an address.
if grep -Eio '[A-Z0-9._%+-]{2,}@[A-Z0-9-]+(\.[A-Z0-9-]+)*\.[A-Z]{2,}' "$TEXT_DUMP" \
    | grep -vi 'example\.' | grep -q .; then
  echo "hygiene   FAIL: email address outside the example.* domains"; FAIL=1
fi

# Phone-shaped runs, in the human-readable fields only. Raw bytes and JSON numbers are
# full of digit runs — UUIDs, epochs, row ids — and flagging those would make this check
# noise nobody reads. A store copied from a real Mac is caught by the address, path and
# iCloud rules, which do scan the binary.
if command -v jq > /dev/null 2>&1; then
  if jq -r '.notifications[] | [.title, .subtitle, .body, .sender] | map(select(. != null)) | join(" ")' \
      "$DIR/expected.json" \
      | grep -Eo '\+?[0-9][0-9 ().-]{6,}[0-9]' | grep -Ev '555[ .-]?01[0-9]{2}$' | grep -q .; then
    echo "hygiene   FAIL: phone-number-like text outside the +1 555 01xx range"; FAIL=1
  fi
fi

# Code-shaped text is only allowed in records the generator marked as its own.
if command -v jq > /dev/null 2>&1; then
  KEYWORDS='(code|verification|passcode|otp|one-time|pin|login|kod|doğrulama|şifre|bestätigungscode|einmalpasswort)'
  if jq -r '
        .notifications[]
        | select((.userInfo["bg.fixture"] // "") != "[synthetic-otp]")
        | [.title, .subtitle, .body] | map(select(. != null)) | join(" ")
      ' "$DIR/expected.json" \
      | grep -Eiq "${KEYWORDS}.{0,40}[0-9]{4,8}|[0-9]{4,8}.{0,40}${KEYWORDS}"; then
    echo "hygiene   FAIL: code-shaped text in a record the generator did not mark"; FAIL=1
  fi
else
  echo "hygiene   WARN: jq not installed; the one-time-code check was skipped"
fi

if grep -Eq '/Users/[^/ ]+/' "$TEXT_DUMP"; then
  echo "hygiene   FAIL: a /Users/<name>/ path is in the fixture"; FAIL=1
fi
if grep -Eq '@(icloud|me|mac)\.com' "$TEXT_DUMP"; then
  echo "hygiene   FAIL: an iCloud address is in the fixture"; FAIL=1
fi

if [[ "$FAIL" -eq 1 ]]; then
  echo "hygiene   FAILED — this fixture must not be committed." >&2
  exit 1
fi
echo "hygiene   OK"
[[ "$HYGIENE_ONLY" -eq 1 ]] && exit 0

# ---- 2. Manifest sanity, before anything slow. ----
if command -v jq > /dev/null 2>&1; then
  RC_MANIFEST="$(jq -r '.record_count' "$DIR/manifest.json")"
  RC_EXPECTED="$(jq '.notifications | length' "$DIR/expected.json")"
  [[ "$RC_MANIFEST" == "$RC_EXPECTED" ]] \
    || { echo "manifest  FAIL: record_count $RC_MANIFEST != expected.json $RC_EXPECTED" >&2; exit 1; }
  jq -e '.notes | startswith("Synthetic.")' "$DIR/manifest.json" > /dev/null \
    || { echo "manifest  FAIL: notes must start with \"Synthetic.\"" >&2; exit 1; }
  echo "manifest  OK (record_count $RC_MANIFEST)"

  # ---- 3. The schema hash, recomputed here rather than trusted. ----
  CLAIMED="$(jq -r '.schema_sha256' "$DIR/manifest.json")"
  ACTUAL="$(schema_hash "$DIR/store.db")"
  if [[ "$CLAIMED" != "$ACTUAL" ]]; then
    echo "schema    FAIL: manifest claims ${CLAIMED:0:12}, store.db hashes to ${ACTUAL:0:12}" >&2
    echo "          (either the fixture was edited by hand, or this script and" >&2
    echo "           StoreFingerprinter no longer normalize the same way)" >&2
    exit 1
  fi
  echo "schema    OK (${ACTUAL:0:12})"
fi

# ---- 4. Store column names must not leak out of the adapter boundary. ----
# ⚠️ Apple's column names are an observation, not an API. Keeping them inside Adapters/
# and Parsing/ is what makes a macOS change a one-file fix instead of a search-and-replace
# across the app (docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md).
# Deliberately not `presented` or `app_id`: those are also the archive's own column
# names and ordinary domain words, and a rule that cries wolf gets switched off.
STORE_COLUMNS='rec_id|delivered_date|request_date|request_last_date|snooze_fire_date'
# Comments are exempt, and so is FixtureGenerator: explaining the boundary is not
# crossing it, and the generator's whole job is to write a store-shaped database. What the
# rule is actually looking for is a column name reaching live code that has no business
# knowing it.
LEAKS="$(grep -REn "\b(${STORE_COLUMNS})\b" \
  --include='*.swift' \
  "$REPO_ROOT/Packages" "$REPO_ROOT/Backglance" 2> /dev/null \
  | grep -v '/Adapters/' | grep -v '/Parsing/' | grep -v '/FixtureGenerator/' | grep -v '/\.build/' \
  | awk -v pat="${STORE_COLUMNS}" '
      {
        rest = substr($0, index($0, ":") + 1)
        code = substr(rest, index(rest, ":") + 1)
        sub(/\/\/.*/, "", code)
        sub(/--.*/, "", code)
        # POSIX awk has no word-boundary escape, so the boundary is spelled out here.
        # Without it, store_rec_id — a column of the archive, not of the store — matches.
        if (code ~ "(^|[^A-Za-z0-9_])(" pat ")([^A-Za-z0-9_]|$)") { print }
      }' || true)"
if [[ -n "$LEAKS" ]]; then
  echo "columns   FAIL: store column names outside Adapters/ and Parsing/:" >&2
  echo "$LEAKS" >&2
  exit 1
fi
echo "columns   OK"

# ---- 5. The fixture parses the way expected.json says. ----
# The package's own test target rather than `xcodebuild test`: the fixture harness needs no
# app bundle, and running it this way works on a machine with no signing identity.
TEST_LOG="$(mktemp)"
trap 'rm -f "$TEXT_DUMP" "$TEST_LOG"' EXIT
if ! swift test --package-path "$REPO_ROOT/Packages/BackglanceCapture" \
    --filter "FixtureMacOS${OS_MAJOR}Tests" > "$TEST_LOG" 2>&1; then
  tail -n 20 "$TEST_LOG" >&2
  echo "fixture   macOS${OS_MAJOR} FAILED" >&2
  exit 1
fi
# A filter that matches nothing exits 0 and proves nothing — the harness has to have run.
if ! grep -Eq "Executed [1-9][0-9]* tests?" "$TEST_LOG"; then
  echo "fixture   FAIL: no FixtureMacOS${OS_MAJOR}Tests ran (is the harness written?)" >&2
  exit 1
fi
echo "fixture   macOS${OS_MAJOR} OK ($(grep -Eo 'Executed [0-9]+ tests?' "$TEST_LOG" | head -1))"
