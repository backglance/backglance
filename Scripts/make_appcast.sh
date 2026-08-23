#!/usr/bin/env bash
# Scripts/make_appcast.sh — build appcast.xml (+ delta updates) for one release.
#
# usage: Scripts/make_appcast.sh <version> <dist-dir>
#   <dist-dir> must contain Backglance-<version>.zip (from Scripts/sign_and_notarize.sh)
#   writes <dist-dir>/appcast.xml and <dist-dir>/Backglance<new>-<old>.delta files
#
# env (all optional):
#   SPARKLE_PRIVATE_KEY   exported EdDSA private key (contents of the file written by generate_keys -x).
#                         If unset, generate_appcast uses the key in the login Keychain (local path).
#   SPARKLE_BIN           path to Sparkle's bin dir (default: found under build/SourcePackages)
#   MAX_DELTAS            previous releases to build deltas from (default 2)
#   REPO                  GitHub repo (default backglance/backglance)
#   FEED_URL              published appcast to merge into (default https://backglance.github.io/backglance/appcast.xml)
set -euo pipefail

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

VERSION="${1:?usage: make_appcast.sh <version> <dist-dir>}"
DIST="${2:?usage: make_appcast.sh <version> <dist-dir>}"
REPO="${REPO:-backglance/backglance}"
MAX_DELTAS="${MAX_DELTAS:-2}"
FEED_URL="${FEED_URL:-https://backglance.github.io/backglance/appcast.xml}"
ZIP="$DIST/Backglance-$VERSION.zip"
WORK="build/appcast-work"
DOWNLOAD_PREFIX="https://github.com/$REPO/releases/download/v$VERSION/"

[[ -f "$ZIP" ]] || die "missing $ZIP — run Scripts/sign_and_notarize.sh first"
command -v pandoc  >/dev/null || die "pandoc not installed (brew install pandoc)"
command -v gh      >/dev/null || die "gh not installed (brew install gh)"
command -v xmllint >/dev/null || die "xmllint not found"

# 1. Sparkle command-line tools (SPM binary artifact resolved by Scripts/build.sh)
if [[ -z "${SPARKLE_BIN:-}" ]]; then
  SPARKLE_BIN="$(find build/SourcePackages/artifacts -maxdepth 4 -type d -path '*sparkle/Sparkle/bin' 2>/dev/null | head -n 1 || true)"
fi
[[ -x "${SPARKLE_BIN:-}/generate_appcast" ]] || die "generate_appcast not found; run Scripts/build.sh first or set SPARKLE_BIN"
log "Sparkle tools: $SPARKLE_BIN"

rm -rf "$WORK"
mkdir -p "$WORK"
cp "$ZIP" "$WORK/"

# 2. Existing appcast, so older items keep their URLs and signatures untouched
if curl -fsSL "$FEED_URL" -o "$WORK/appcast.xml"; then
  log "Fetched current appcast ($(grep -c '<item>' "$WORK/appcast.xml") items)"
else
  log "No published appcast at $FEED_URL — starting a new one"
  rm -f "$WORK/appcast.xml"
fi

# 3. Previous release zips, for delta updates (newest first, up to MAX_DELTAS).
# The greps are allowed to come up empty: on the very first release there is no
# previous tag at all, and `grep` exiting 1 on no matches must not kill the
# script under pipefail.
gh release list --repo "$REPO" --exclude-drafts --exclude-pre-releases --limit 20 \
    --json tagName --jq '.[].tagName' \
  | { grep -v "^v$VERSION\$" || true; } | head -n "$MAX_DELTAS" \
  | while IFS= read -r tag; do
      prev="${tag#v}"
      if gh release download "$tag" --repo "$REPO" --pattern "Backglance-$prev.zip" --dir "$WORK" 2>/dev/null; then
        log "Delta source: $tag"
      else
        log "No zip on $tag — no delta from it"
      fi
    done

# 4. Release notes: this version's CHANGELOG section -> HTML next to the zip (same basename)
awk -v ver="$VERSION" '
  $0 ~ "^## \\[" ver "\\]" { grab = 1; next }
  grab && /^## \[/       { exit }
  grab                   { print }
' CHANGELOG.md > "$WORK/notes.md"
[[ -s "$WORK/notes.md" ]] || die "no CHANGELOG section for [$VERSION]"
{
  printf '<!doctype html><meta charset="utf-8">'
  printf '<style>body{font:13px -apple-system,system-ui,sans-serif;margin:12px;color:#222}h3{margin:12px 0 4px}</style>'
  pandoc -f gfm -t html "$WORK/notes.md"
} > "$WORK/Backglance-$VERSION.html"

# 5. generate_appcast
ARGS=(
  --download-url-prefix "$DOWNLOAD_PREFIX"
  --link "https://github.com/$REPO/releases/tag/v$VERSION"
  --embed-release-notes
  --maximum-deltas "$MAX_DELTAS"
)
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  log "Signing with SPARKLE_PRIVATE_KEY from environment"
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/generate_appcast" --ed-key-file - "${ARGS[@]}" "$WORK"
else
  log "Signing with the EdDSA key in the login Keychain"
  "$SPARKLE_BIN/generate_appcast" "${ARGS[@]}" "$WORK"
fi

# 6. Collect + sanity-check
cp "$WORK/appcast.xml" "$DIST/appcast.xml"
find "$WORK" -maxdepth 1 -name '*.delta' -exec cp {} "$DIST/" \;
xmllint --noout "$DIST/appcast.xml"
grep -Fq "Backglance-$VERSION.zip" "$DIST/appcast.xml" || die "appcast has no item for $VERSION"
grep -Fq 'sparkle:edSignature="' "$DIST/appcast.xml" || die "appcast item is not EdDSA-signed"

log "Wrote $DIST/appcast.xml"
ls "$DIST"/*.delta 2>/dev/null | sed 's/^/==> delta: /' || true
grep -E 'sparkle:(version|shortVersionString|minimumSystemVersion)>|enclosure url' "$DIST/appcast.xml" | head -n 8
log "Do NOT push the appcast before the GitHub Release is published (see DEPLOYMENT_GUIDE Step 7)."
