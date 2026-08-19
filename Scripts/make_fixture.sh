#!/usr/bin/env bash
# Scripts/make_fixture.sh — (re)generate a SYNTHETIC system-store fixture.
#
#   Scripts/make_fixture.sh --os 26                    # regenerate from the checked-in schema + manifest
#   Scripts/make_fixture.sh --os 27 --capture-schema   # on a macOS 27 machine: dump .schema (DDL only), then generate
#   Scripts/make_fixture.sh --os 27 --from 26 --seed 20260817 --records 250
#
# ⚠️ This script never reads a row from the live store. --capture-schema runs
# `sqlite3 .schema` against it and nothing else, and only when you ask for it. Everything
# in the resulting fixture is generated from a seed — see docs/testing/TESTING.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS_MAJOR=""; FROM=""; SEED=""; RECORDS=""; CAPTURE_SCHEMA=0; BUILD=""; NOTES=""

usage() {
  cat <<'EOF'
usage: make_fixture.sh --os <major> [--from <major>] [--seed <int>] [--records <n>] [--capture-schema]
  --os              target macOS major version (14, 15, 26, ...)
  --from            take generator parameters from another fixture's manifest (default: --os)
  --seed            RNG seed (default: the source manifest's, else 20260817)
  --records         records to generate (default: the source manifest's, else 250)
  --capture-schema  refresh Scripts/fixtures/schema_v<major>.sql from the live store's .schema (DDL only)
  --build           build number to record (default: this machine's, which is only right
                    if the schema was captured here)
  --notes           manifest notes; must start with "Synthetic."
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --os) OS_MAJOR="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    --records) RECORDS="$2"; shift 2 ;;
    --capture-schema) CAPTURE_SCHEMA=1; shift ;;
    --build) BUILD="$2"; shift 2 ;;
    --notes) NOTES="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$OS_MAJOR" ]] || { usage; exit 2; }

OUT_DIR="$REPO_ROOT/Tests/Fixtures/SystemStore/macOS${OS_MAJOR}"
SRC_MANIFEST="$REPO_ROOT/Tests/Fixtures/SystemStore/macOS${FROM:-$OS_MAJOR}/manifest.json"
SCHEMA_SQL="$REPO_ROOT/Scripts/fixtures/schema_v${OS_MAJOR}.sql"
LIVE_STORE="$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"
mkdir -p "$(dirname "$SCHEMA_SQL")"

# Phase 1 — the schema. DDL only, and only on the macOS it claims to describe: a schema
# captured on the wrong release would mislabel every fixture generated from it afterwards.
if [[ "$CAPTURE_SCHEMA" -eq 1 ]]; then
  HOST_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
  if [[ "$HOST_MAJOR" != "$OS_MAJOR" ]]; then
    echo "error: --capture-schema for macOS $OS_MAJOR must run on macOS $OS_MAJOR (this is $HOST_MAJOR)" >&2
    exit 1
  fi
  if ! sqlite3 -readonly "file:${LIVE_STORE}?immutable=1" ".schema" > "$SCHEMA_SQL.tmp" 2>/dev/null; then
    echo "error: could not read the store schema. Grant Full Disk Access to your terminal" >&2
    echo "       (System Settings ▸ Privacy & Security ▸ Full Disk Access) and try again." >&2
    rm -f "$SCHEMA_SQL.tmp"
    exit 1
  fi
  # `.schema` emits DDL. Belt and braces: refuse anything that is not a CREATE, a comment,
  # or the punctuation those span — a row would be someone's notification.
  if grep -Ev '^(CREATE|--|$|[[:space:]]|\)|;)' "$SCHEMA_SQL.tmp" | grep -q .; then
    echo "error: captured schema contains non-DDL lines; refusing to write it" >&2
    rm -f "$SCHEMA_SQL.tmp"
    exit 1
  fi
  mv "$SCHEMA_SQL.tmp" "$SCHEMA_SQL"
  echo "captured DDL -> $SCHEMA_SQL ($(grep -c '^CREATE' "$SCHEMA_SQL") statements)"
fi

if [[ ! -f "$SCHEMA_SQL" ]]; then
  echo "error: no schema template at $SCHEMA_SQL" >&2
  echo "       run this script with --capture-schema on a macOS $OS_MAJOR machine first." >&2
  exit 1
fi

# Phase 2 — an empty database with that DDL, then synthetic rows.
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/store.db" "$OUT_DIR/store.db-wal" "$OUT_DIR/store.db-shm"
sqlite3 "$OUT_DIR/store.db" < "$SCHEMA_SQL"

# FixtureGenerator inserts the app and record rows (bplist `data` blobs) from a seeded
# generator, writes expected.json, and computes the manifest's schema hash with the app's
# own StoreFingerprint — so this script and the capture layer can never disagree about
# normalisation. It never reads ~/Library.
GENERATOR_ARGS=(
  --os "$OS_MAJOR"
  --db "$OUT_DIR/store.db"
  --expected "$OUT_DIR/expected.json"
  --manifest "$OUT_DIR/manifest.json"
  --build "${BUILD:-$(sw_vers -buildVersion)}"
)
[[ -n "$NOTES" ]] && GENERATOR_ARGS+=(--notes "$NOTES")
[[ -f "$SRC_MANIFEST" ]] && GENERATOR_ARGS+=(--source-manifest "$SRC_MANIFEST")
[[ -n "$SEED" ]] && GENERATOR_ARGS+=(--seed "$SEED")
[[ -n "$RECORDS" ]] && GENERATOR_ARGS+=(--records "$RECORDS")

swift run --package-path "$REPO_ROOT/Packages/BackglanceCapture" -c release FixtureGenerator "${GENERATOR_ARGS[@]}"

# Checkpoint so the fixture is one file in the tree, then make it read-only: a fixture that
# a test could write to is a fixture that stops describing what it claims to.
sqlite3 "$OUT_DIR/store.db" "PRAGMA wal_checkpoint(TRUNCATE);" > /dev/null
rm -f "$OUT_DIR/store.db-wal" "$OUT_DIR/store.db-shm"
chmod 0444 "$OUT_DIR/store.db"

echo "wrote $OUT_DIR/{store.db,manifest.json,expected.json}"
echo "now run: Scripts/verify_fixture.sh --os $OS_MAJOR"
