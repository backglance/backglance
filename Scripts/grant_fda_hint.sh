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
