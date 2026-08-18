#!/usr/bin/env bash
# Scripts/build.sh — archive + export a Developer ID build into build/export/Backglance.app
set -euo pipefail

PROJECT="Backglance.xcodeproj"
SCHEME="Backglance"
ARCHIVE="build/Backglance.xcarchive"
EXPORT_DIR="build/export"
TEAM_ID="${TEAM_ID:-TEAMID1234}"

rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p build

# Resolve packages into a project-local directory so CI can cache it and so the
# Sparkle command-line tools have a predictable path (build/SourcePackages/artifacts/sparkle/Sparkle/bin).
xcodebuild -resolvePackageDependencies \
  -project "$PROJECT" -scheme "$SCHEME" \
  -clonedSourcePackagesDirPath build/SourcePackages

set -o pipefail
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -clonedSourcePackagesDirPath build/SourcePackages \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  | xcbeautify

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist Scripts/ExportOptions.plist \
  -exportPath "$EXPORT_DIR" \
  | xcbeautify

echo "Exported: $EXPORT_DIR/Backglance.app"
lipo -archs "$EXPORT_DIR/Backglance.app/Contents/MacOS/Backglance"   # expect: x86_64 arm64
