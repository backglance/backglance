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
