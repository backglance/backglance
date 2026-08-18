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
if [[ ! -f "$LOCAL_XCCONFIG" ]]; then
  # Try to discover a team from the login keychain; fall back to a placeholder.
  TEAM_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '\(([A-Z0-9]{10})\)' | head -n1 | tr -d '()' || true)"
  if [[ -z "${TEAM_ID:-}" ]]; then
    TEAM_ID="TEAMID1234"
    warn "No signing identity found; wrote placeholder DEVELOPMENT_TEAM. Edit Config/Local.xcconfig."
  fi
  mkdir -p "$(dirname "$LOCAL_XCCONFIG")"
  cat > "$LOCAL_XCCONFIG" <<EOF
// Local, git-ignored overrides. Created by Scripts/bootstrap.sh.
DEVELOPMENT_TEAM = $TEAM_ID
CODE_SIGN_STYLE = Automatic
EOF
  info "Wrote $LOCAL_XCCONFIG (DEVELOPMENT_TEAM = $TEAM_ID)"
else
  info "Config/Local.xcconfig already exists; leaving it alone"
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
