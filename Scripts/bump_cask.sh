#!/usr/bin/env bash
# Scripts/bump_cask.sh — bump Casks/backglance.rb in backglance/homebrew-tap to <version> and open a PR.
#
# usage: Scripts/bump_cask.sh <version>
# env:   REPO (default backglance/backglance), TAP_REPO (default backglance/homebrew-tap),
#        GH_TOKEN (CI: the HOMEBREW_TAP_TOKEN secret; locally `gh auth login` is enough)
set -euo pipefail

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

VERSION="${1:?usage: bump_cask.sh <version>}"
REPO="${REPO:-backglance/backglance}"
TAP_REPO="${TAP_REPO:-backglance/homebrew-tap}"
ZIP="Backglance-$VERSION.zip"
BASE="https://github.com/$REPO/releases/download/v$VERSION"
WORK="build/cask-bump"
CASK="Casks/backglance.rb"
BRANCH="bump-backglance-$VERSION"

rm -rf "$WORK" && mkdir -p "$WORK"

log "Downloading $ZIP and SHA256SUMS.txt from v$VERSION"
curl -fsSL -o "$WORK/$ZIP" "$BASE/$ZIP"                    || die "release asset not found: $BASE/$ZIP (is the release published?)"
curl -fsSL -o "$WORK/SHA256SUMS.txt" "$BASE/SHA256SUMS.txt" || die "SHA256SUMS.txt missing on the release"
SHA="$(shasum -a 256 "$WORK/$ZIP" | awk '{print $1}')"
grep -Fq "$SHA  $ZIP" "$WORK/SHA256SUMS.txt" || die "sha256 $SHA does not match SHA256SUMS.txt — refusing to bump"
log "sha256 $SHA matches SHA256SUMS.txt"

log "Cloning $TAP_REPO"
gh repo clone "$TAP_REPO" "$WORK/tap" -- --depth 1 --quiet
cd "$WORK/tap"
[[ -f "$CASK" ]] || die "$CASK not found in tap"
git checkout -q -b "$BRANCH"

# Rewrite exactly the two stanzas; portable sed (no -i differences between BSD and GNU)
sed -e "s/^  version \".*\"/  version \"$VERSION\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
    "$CASK" > "$CASK.tmp" && mv "$CASK.tmp" "$CASK"
git diff --quiet -- "$CASK" && die "cask is already at $VERSION with this sha256"
git --no-pager diff -- "$CASK"

if command -v brew >/dev/null 2>&1; then
  brew style "$CASK" || die "brew style failed"
fi

git -c user.name="${GIT_AUTHOR_NAME:-backglance-release}" \
    -c user.email="${GIT_AUTHOR_EMAIL:-release@backglance.app}" \
    commit -q -am "backglance $VERSION"
git push -q -u origin "$BRANCH"

PR_URL="$(gh pr create --repo "$TAP_REPO" --base main --head "$BRANCH" \
  --title "backglance $VERSION" \
  --body "Bump to $VERSION.

- url: $BASE/$ZIP
- sha256: \`$SHA\` (matches SHA256SUMS.txt on the release)
- Release notes: https://github.com/$REPO/releases/tag/v$VERSION")"
log "$PR_URL"
