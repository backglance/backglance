#!/usr/bin/env bash
# Scripts/sign_and_notarize.sh — sign (inside-out, hardened runtime, timestamp), notarize, staple,
# and package a Backglance.app into build/dist/{Backglance-<v>.zip, Backglance-<v>.dmg, SHA256SUMS.txt}.
#
# usage:
#   Scripts/sign_and_notarize.sh [--sign-only] [--skip-dmg] <path/to/Backglance.app> [<version>]
#
# env (all optional):
#   SIGN_IDENTITY     default "Developer ID Application: Backglance (TEAMID1234)"
#   NOTARY_PROFILE    keychain profile, default "backglance-notary" (local path)
#   NOTARY_APPLE_ID / NOTARY_TEAM_ID / NOTARY_PASSWORD
#                     if all three are set they are used instead of the profile (CI path)
#   DIST_DIR          default build/dist
#
# This is the one implementation of the signing order and the packaging layout: the manual
# release path in docs/deployment/DEPLOYMENT_GUIDE.md and the `release` job in
# .github/workflows/release.yml both run this script, and differ only in where the notary
# credentials and the certificate come from.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

SIGN_ONLY=0
SKIP_DMG=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign-only) SIGN_ONLY=1; shift ;;
    --skip-dmg)  SKIP_DMG=1; shift ;;
    -h|--help)   sed -n '2,13p' "$0"; exit 0 ;;
    --)          shift; break ;;
    -*)          die "unknown option: $1" ;;
    *)           break ;;
  esac
done

APP="${1:?usage: sign_and_notarize.sh [--sign-only] [--skip-dmg] <Backglance.app> [<version>]}"
[[ -d "$APP/Contents" ]] || die "not an app bundle: $APP"
VERSION="${2:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Backglance (TEAMID1234)}"
DIST="${DIST_DIR:-build/dist}"
WORK="build/notary"
ENTITLEMENTS="$REPO_ROOT/Backglance/Backglance.entitlements"
[[ -f "$ENTITLEMENTS" ]] || die "entitlements not found: $ENTITLEMENTS"
mkdir -p "$DIST" "$WORK"

log "Backglance $VERSION (build $BUILD_NUMBER) — $APP"
security find-identity -v -p codesigning | grep -Fq "$IDENTITY" \
  || die "signing identity not found in any keychain: $IDENTITY"

# Notary credentials: CI secrets if all present, else the keychain profile.
if [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
  NOTARY=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
  log "notary credentials: environment"
else
  NOTARY=(--keychain-profile "${NOTARY_PROFILE:-backglance-notary}")
  log "notary credentials: keychain profile ${NOTARY_PROFILE:-backglance-notary}"
fi

sign() {   # sign <path> [extra codesign flags...]
  local target="$1"; shift
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@" "$target"
}

# ---------------------------------------------------------------- 1. sign inside-out
log "Signing (inside-out)"
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$FW" ]]; then
  sign "$FW/Versions/B/XPCServices/Installer.xpc"
  sign "$FW/Versions/B/XPCServices/Downloader.xpc" --preserve-metadata=entitlements   # keeps its network.client sandbox entitlements
  sign "$FW/Versions/B/Autoupdate"
  sign "$FW/Versions/B/Updater.app"
  sign "$FW"
fi
# Any other embedded framework (none today; the loop exists so a new one is not forgotten)
if [[ -d "$APP/Contents/Frameworks" ]]; then
  find "$APP/Contents/Frameworks" -maxdepth 1 -name '*.framework' ! -name 'Sparkle.framework' -print0 \
    | while IFS= read -r -d '' fw; do sign "$fw"; done
fi
# App extensions (v1.x WidgetKit). Extensions are sandboxed and keep their own entitlements.
if [[ -d "$APP/Contents/PlugIns" ]]; then
  find "$APP/Contents/PlugIns" -maxdepth 1 -name '*.appex' -print0 \
    | while IFS= read -r -d '' ex; do sign "$ex" --preserve-metadata=entitlements; done
fi
sign "$APP" --entitlements "$ENTITLEMENTS"

log "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# The get-task-allow refusal. A Debug-signed build is a debuggable build, and shipping one
# would hand anything on the user's Mac a debugger attach to a process that reads the
# notification archive. The extraction has to succeed for the check to mean anything: if
# codesign cannot print the entitlements, an empty grep would pass this silently.
ENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)" \
  || die "could not read the entitlements back off $APP — refusing to ship an unverified build"
if grep -q 'get-task-allow' <<<"$ENTS"; then
  die "get-task-allow entitlement present — this is a Debug-signed build; archive with -configuration Release"
fi
codesign -dvv "$APP" 2>&1 | grep -E '^Authority=Developer ID Application' >/dev/null \
  || die "app is not signed with a Developer ID Application identity"

if [[ "$SIGN_ONLY" -eq 1 ]]; then
  log "--sign-only: done"
  exit 0
fi

# ---------------------------------------------------------------- 2. notarize + staple the app
notarize() {   # notarize <file> <label>   (sets NOTARY_STATUS, NOTARY_ID)
  local file="$1" label="$2" result="$WORK/notary-$2.json"
  log "Submitting $label for notarization (this takes a few minutes)"
  # notarytool's exit code is not a reliable Accepted/Invalid signal; parse the JSON.
  xcrun notarytool submit "$file" "${NOTARY[@]}" --wait --timeout 30m --output-format json > "$result" || true
  NOTARY_STATUS="$(plutil -extract status raw -o - "$result" 2>/dev/null || echo "Unknown")"
  NOTARY_ID="$(plutil -extract id raw -o - "$result" 2>/dev/null || echo "")"
  if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    log "Notarization of $label: $NOTARY_STATUS (submission ${NOTARY_ID:-none})"
    if [[ -n "$NOTARY_ID" ]]; then
      xcrun notarytool log "$NOTARY_ID" "${NOTARY[@]}" "$WORK/notary-$label-log.json" || true
      plutil -p "$WORK/notary-$label-log.json" 2>/dev/null | grep -E '"(severity|path|message)"' || cat "$result"
    else
      cat "$result"
    fi
    die "notarization failed for $label — see docs/deployment/PACKAGING_NOTARIZATION.md#reading-notarytool-log-common-errors"
  fi
  log "Notarization of $label: Accepted (submission $NOTARY_ID)"
}

ditto -c -k --keepParent "$APP" "$WORK/Backglance-notary.zip"
notarize "$WORK/Backglance-notary.zip" "app"

log "Stapling app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP" 2>&1 | tee "$WORK/spctl-app.txt"
grep -q 'source=Notarized Developer ID' "$WORK/spctl-app.txt" || die "Gatekeeper does not see a notarized app"

# ---------------------------------------------------------------- 3. package: zip (Sparkle + Homebrew)
ZIP="$DIST/Backglance-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"
log "Wrote $ZIP ($(du -h "$ZIP" | cut -f1))"

# ---------------------------------------------------------------- 4. package: dmg (humans)
DMG="$DIST/Backglance-$VERSION.dmg"
if [[ "$SKIP_DMG" -eq 1 ]]; then
  log "--skip-dmg: no disk image"
elif ! command -v create-dmg >/dev/null 2>&1; then
  log "create-dmg not installed (brew install create-dmg) — skipping dmg"
else
  rm -rf build/dmg-root "$DMG"
  mkdir -p build/dmg-root
  cp -R "$APP" build/dmg-root/
  create-dmg \
    --volname "Backglance $VERSION" \
    --window-pos 200 120 \
    --window-size 560 380 \
    --icon-size 128 \
    --icon "Backglance.app" 140 180 \
    --app-drop-link 420 180 \
    --no-internet-enable \
    "$DMG" \
    build/dmg-root/
  # The DMG is its own notarization unit.
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  notarize "$DMG" "dmg"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
  log "Wrote $DMG ($(du -h "$DMG" | cut -f1))"
fi

# ---------------------------------------------------------------- 5. checksums
( cd "$DIST" && shasum -a 256 Backglance-"$VERSION".zip $( [[ -f "Backglance-$VERSION.dmg" ]] && echo "Backglance-$VERSION.dmg" ) > SHA256SUMS.txt )
log "Checksums:"
cat "$DIST/SHA256SUMS.txt"
log "Done. Next: Scripts/make_appcast.sh $VERSION $DIST"
