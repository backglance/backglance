# Deployment Guide

Last Updated: 2026-08-18

This document is the end-to-end release process for Backglance: from "the branch is green" to "a user on a fresh Mac installs it, and a user on the previous version gets a Sparkle update". Backglance is a Developer ID signed and notarized menu bar app distributed outside the Mac App Store (Full Disk Access is incompatible with App Sandbox, so the App Store is not an option). There are two ways to run a release: the **manual path** (every command typed by hand, useful for the first release and for understanding what the automation does) and the **automated path** (push a `vX.Y.Z` tag, `release.yml` does the rest). Both produce identical artifacts. Where a step needs the deeper signing / notarization / Sparkle details, it links to [PACKAGING_NOTARIZATION.md](./PACKAGING_NOTARIZATION.md); where it needs the workflow YAML, it links to [CI_CD.md](./CI_CD.md).

## Table of Contents

- [Release at a glance](#release-at-a-glance)
- [Prerequisites (one-time)](#prerequisites-one-time)
- [Pre-flight checklist](#pre-flight-checklist)
- [Step 1 — Version bump and tag](#step-1--version-bump-and-tag)
- [Step 2 — Build the archive and export](#step-2--build-the-archive-and-export)
- [Step 3 — Sign](#step-3--sign)
- [Step 4 — Notarize and staple](#step-4--notarize-and-staple)
- [Step 5 — Package (zip + dmg)](#step-5--package-zip--dmg)
- [Step 6 — Sparkle appcast](#step-6--sparkle-appcast)
- [Step 7 — GitHub Release](#step-7--github-release)
- [Step 8 — Homebrew cask bump](#step-8--homebrew-cask-bump)
- [Step 9 — Announce](#step-9--announce)
- [Step 10 — Post-release verification](#step-10--post-release-verification)
- [The automated path](#the-automated-path)
- [Rollback and hotfixes](#rollback-and-hotfixes)
- [Release cadence and hotfix policy](#release-cadence-and-hotfix-policy)
- [Release checklist (copy into the tracking issue)](#release-checklist-copy-into-the-tracking-issue)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Release at a glance

```
 main branch (green CI, fixtures green on macOS 14 / 15 / 26)
        │
        ▼
 ┌─────────────────┐   agvtool / git tag vX.Y.Z
 │ 1. version bump │─────────────────────────────┐
 └─────────────────┘                             │
        │                                        │ (tag push triggers release.yml)
        ▼                                        ▼
 ┌─────────────────┐  xcodebuild archive + -exportArchive (developer-id, universal)
 │ 2. build        │
 └─────────────────┘
        │
        ▼
 ┌─────────────────┐  codesign inside-out (Sparkle XPCs → framework → app), hardened runtime, --timestamp
 │ 3. sign         │
 └─────────────────┘
        │
        ▼
 ┌─────────────────┐  notarytool submit --wait  →  stapler staple
 │ 4. notarize     │
 └─────────────────┘
        │
        ▼
 ┌─────────────────┐  ditto zip (for Sparkle + Homebrew)  ·  create-dmg (for humans)
 │ 5. package      │
 └─────────────────┘
        │
        ▼
 ┌─────────────────┐  generate_appcast (EdDSA, deltas, minimumSystemVersion) → appcast.xml
 │ 6. appcast      │
 └─────────────────┘
        │
        ▼
 ┌─────────────────┐  gh release create (draft → assets → publish)  ·  push appcast to gh-pages (LAST)
 │ 7. release      │
 └─────────────────┘
        │
        ▼
 ┌─────────────────┐  Scripts/bump_cask.sh → PR to backglance/homebrew-tap
 │ 8. cask         │
 └─────────────────┘
        │
        ▼
 ┌─────────────────┐  README compat table · GitHub Discussions post
 │ 9. announce     │
 └─────────────────┘
        │
        ▼
 ┌─────────────────┐  fresh-Mac install · Sparkle update from previous version · spctl --assess
 │ 10. verify      │
 └─────────────────┘
```

> ℹ️ **Info:** The point of no return is pushing `appcast.xml` to `gh-pages`. Everything before it can be redone quietly (a draft GitHub Release is invisible; an unsigned zip on your disk hurts nobody). Once the appcast is live, every running copy of Backglance with automatic checks enabled will see the new version within 24 hours.

## Prerequisites (one-time)

| Item | How to get it | Where it is used |
|---|---|---|
| Apple Developer Program membership | developer.apple.com (paid, yearly) | Developer ID certificate, notarization |
| `Developer ID Application: Backglance (TEAMID1234)` certificate in the login keychain | See [PACKAGING_NOTARIZATION.md → Developer ID codesigning](./PACKAGING_NOTARIZATION.md#developer-id-codesigning) | Step 3 |
| Notary keychain profile `backglance-notary` | `xcrun notarytool store-credentials backglance-notary --apple-id "$AC_APPLE_ID" --team-id "$AC_TEAM_ID" --password "$AC_PASSWORD"` | Step 4 |
| Sparkle EdDSA key pair (private key in Keychain, public key in `Info.plist` `SUPublicEDKey`) | `generate_keys` from the Sparkle SPM artifact | Step 6 |
| Xcode 26.2 (minimum 16.2), command line tools selected | `sudo xcode-select -s /Applications/Xcode.app` | Steps 2–4 |
| Homebrew tools | `brew install xcbeautify create-dmg gh pandoc` | Steps 2, 5, 6, 7 |
| `gh` authenticated with push rights to `backglance/backglance` and `backglance/homebrew-tap` | `gh auth login` | Steps 7–8 |
| GitHub Pages enabled for `backglance/backglance`, source: `gh-pages` branch, root | Repository → Settings → Pages | Step 6 |

Verify the toolchain before a release day, not on it:

```bash
xcodebuild -version                       # Xcode 26.2 / Build version ...
security find-identity -v -p codesigning  # must list "Developer ID Application: Backglance (TEAMID1234)"
xcrun notarytool history --keychain-profile backglance-notary | head -5   # proves the profile works
gh auth status
which create-dmg xcbeautify pandoc
```

## Pre-flight checklist

Do all of these on `main` before touching a version number. Each one is cheap; skipping any of them is how you end up publishing a hotfix the same evening.

1. **CHANGELOG is written.** `CHANGELOG.md` has a section for the version you are about to release, moved out of `[Unreleased]`, in the Keep a Changelog format (`Added / Changed / Fixed / Removed / Security`). The release notes for GitHub and Sparkle are generated from this section — nothing is typed twice.
2. **CI is green** on the merge commit: `ci / build-test` and `ci / lint` (see [CI_CD.md](./CI_CD.md#ciyml--build-and-test-on-every-pr)).
3. **Fixtures are green on all supported macOS.** The last nightly `fixtures.yml` run passed on `macos-14`, `macos-15` and `macos-26`. If a fingerprint on a runner was reported unknown, an issue was auto-opened; a release with a red fixture job on a supported OS is a hotfix waiting to happen — fix the adapter or document the degraded mode first ([OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md)).
4. **Compatibility table is up to date** in `README.md` and in the playbook (they must be identical). If this release adds or finalizes an adapter (for example the macOS 27 GM adapter), the row changes in both files in the same PR.
5. **Manual smoke test on the primary dev Mac (macOS 26)**: fresh clone, `Scripts/bootstrap.sh`, run from Xcode, grant FDA, see the archive fill, run a search, trigger a digest by locking the screen for five minutes.
6. **Sparkle key sanity:** `SUPublicEDKey` in `Backglance/Info.plist` matches the private key you will sign with (`generate_keys -p` prints the public key for the Keychain-stored private key). A mismatch means every user sees "update is improperly signed" and you cannot fix it remotely for users already on the bad build.
7. **No debug leftovers:** `git grep -n "get-task-allow" Backglance/` returns nothing in the release entitlements; `eraseDatabaseOnSchemaChange` is DEBUG-only; no `print(` of notification content anywhere (`git grep -n "print(" Packages/ Backglance/`).
8. **Working tree clean, on `main`, up to date:** `git status --porcelain` empty, `git pull --ff-only`.

> ⚠️ **Warning:** Capture reads Apple's undocumented system store. A release is only as good as its fixtures. If a new macOS point release shipped in the last week, regenerate the fixture for it (`Scripts/make_fixture.sh`) and run `Scripts/verify_fixture.sh` before releasing — see [TESTING.md](../testing/TESTING.md).

## Step 1 — Version bump and tag

Backglance uses Apple Generic Versioning (`agvtool`), which edits `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Backglance.xcodeproj/project.pbxproj` for the app target and its extensions in one go.

| Setting | Meaning | Rule |
|---|---|---|
| `MARKETING_VERSION` (`CFBundleShortVersionString`) | Human version `X.Y.Z` (semver) | Patch = bug fix / adapter hotfix, minor = features, major = breaking archive migration or UI overhaul |
| `CURRENT_PROJECT_VERSION` (`CFBundleVersion`) | Integer build number | Strictly increases by 1 on every tagged release, including hotfixes and betas. Sparkle compares **this** number (`sparkle:version`), never the marketing version. |

Example: `0.1.0` was build `1`; `1.0.0` is build `20`; the first hotfix `1.0.1` is build `21`.

```bash
cd /path/to/backglance
git checkout main && git pull --ff-only

# 1. Bump the marketing version and the build number
agvtool new-marketing-version 1.0.0          # sets MARKETING_VERSION for all targets
agvtool next-version -all                    # CURRENT_PROJECT_VERSION 19 -> 20

# 2. Confirm what agvtool did
agvtool what-marketing-version -terse1       # 1.0.0
agvtool what-version -terse                  # 20

# 3. Move the CHANGELOG section (do this by hand: [Unreleased] -> [1.0.0] - 2026-08-17)
#    Two edits, not one: give the section its date, and delete the "> The tag is not cut"
#    note the section carries while the milestone is open. release.yml ships this section
#    verbatim as the GitHub Release body and as what Sparkle shows, so shipping it unedited
#    announces the release by explaining that it has not happened. The workflow refuses to
#    publish a section whose header still says "unreleased", which catches the first of the
#    two edits but cannot catch the second.
"${EDITOR:-vim}" CHANGELOG.md

# 4. Commit and tag. The tag is annotated so `git describe` and GitHub both show it.
git add Backglance.xcodeproj/project.pbxproj CHANGELOG.md
git commit -m "release: 1.0.0 (build 20)"
git tag -a v1.0.0 -m "Backglance 1.0.0"
git push origin main
git push origin v1.0.0                       # <- on the automated path this single push starts release.yml
```

If you prefer the values in an xcconfig (some contributors do, because it makes diffs trivial), the equivalent is a `Backglance/Version.xcconfig` with `MARKETING_VERSION = 1.0.0` and `CURRENT_PROJECT_VERSION = 20`, referenced from the project's build settings; `agvtool` will not edit that file, so bump it with `sed`. The project as committed uses `agvtool`; do not mix the two.

> ❌ **Don't:** reuse a build number, or tag a commit whose `CURRENT_PROJECT_VERSION` is lower than the last published appcast item. Sparkle will refuse to offer the "downgrade" and users stay stuck.

## Step 2 — Build the archive and export

The build is a Release archive for `arm64 x86_64` (Universal 2), exported with the `developer-id` method. `Scripts/build.sh` wraps the two `xcodebuild` calls; the commands below are what it runs.

```bash
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
```

`Scripts/ExportOptions.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>TEAMID1234</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
```

Run it:

```bash
Scripts/build.sh
# Success looks like:
#   ▸ Archive Succeeded
#   ▸ Export Succeeded
#   Exported: build/export/Backglance.app
#   x86_64 arm64
```

Common failure: `error: No signing certificate "Developer ID Application" found` — the certificate is not in the keychain, or its private key is missing (you imported only the `.cer`). Fix per [PACKAGING_NOTARIZATION.md](./PACKAGING_NOTARIZATION.md#developer-id-codesigning).

## Step 3 — Sign

Xcode's export already signs the app, but the release script re-signs deterministically so that the manual and CI paths agree byte-for-byte on flags: Developer ID identity, hardened runtime (`--options runtime`), secure timestamp (`--timestamp`), and **inside-out** order for the embedded Sparkle framework (its XPC services and helper first, then the framework, then the app). `--deep` is deliberately not used; the reasons are in [PACKAGING_NOTARIZATION.md → codesign commands](./PACKAGING_NOTARIZATION.md#codesign-commands-and-the---deep-caveat).

`Scripts/sign_and_notarize.sh` does signing, notarization, stapling and zip creation in one go (full script in [PACKAGING_NOTARIZATION.md](./PACKAGING_NOTARIZATION.md#scriptssign_and_notarizesh)). To sign only:

```bash
Scripts/sign_and_notarize.sh --sign-only build/export/Backglance.app
```

Verify:

```bash
codesign --verify --deep --strict --verbose=2 build/export/Backglance.app
# build/export/Backglance.app: valid on disk
# build/export/Backglance.app: satisfies its Designated Requirement

codesign -dvv build/export/Backglance.app 2>&1 | grep -E 'Authority|Timestamp|flags'
# Authority=Developer ID Application: Backglance (TEAMID1234)
# Timestamp=17 Aug 2026 at 10:12:03
# flags=0x10000(runtime)
```

## Step 4 — Notarize and staple

Notarization is Apple scanning the binary and returning a ticket; stapling attaches that ticket to the app so Gatekeeper does not need to phone home on first launch. Only bundles, disk images and installer packages can be stapled — a zip cannot — so the order is: zip → submit → staple the `.app` → re-zip.

```bash
# Submit (the script does this; shown here so the manual path is complete)
ditto -c -k --keepParent build/export/Backglance.app build/notary-upload.zip
xcrun notarytool submit build/notary-upload.zip \
  --keychain-profile backglance-notary \
  --wait --timeout 30m --output-format json | tee build/notary-result.json
# {"status":"Accepted","id":"1a2b3c4d-...","message":"Processing complete"}

# Staple the .app on disk, then validate
xcrun stapler staple build/export/Backglance.app
xcrun stapler validate build/export/Backglance.app
# The validate action worked!

# Gatekeeper's opinion (this is what a user's Mac evaluates)
spctl --assess --type execute --verbose=4 build/export/Backglance.app
# build/export/Backglance.app: accepted
# source=Notarized Developer ID
```

If `status` is `Invalid`, fetch the log and read the `issues` array — [PACKAGING_NOTARIZATION.md → reading notarytool logs](./PACKAGING_NOTARIZATION.md#reading-notarytool-log-common-errors) lists the usual suspects (missing timestamp, `get-task-allow` in entitlements, an unsigned Sparkle helper).

```bash
xcrun notarytool log "$(jq -r .id build/notary-result.json)" --keychain-profile backglance-notary
```

## Step 5 — Package (zip + dmg)

Two artifacts, two audiences:

| Artifact | Name | Audience | Why |
|---|---|---|---|
| Zip | `Backglance-1.0.0.zip` | Sparkle updater, Homebrew cask | Sparkle wants a plain archive it can extract without mounting anything; Homebrew computes one sha256 |
| DMG | `Backglance-1.0.0.dmg` | Humans downloading from the Releases page | Familiar drag-to-Applications window |

```bash
VERSION=1.0.0
DIST=build/dist
mkdir -p "$DIST"

# Zip — ditto keeps resource forks, extended attributes and the stapled ticket intact.
ditto -c -k --keepParent --sequesterRsrc build/export/Backglance.app "$DIST/Backglance-$VERSION.zip"

# DMG — create-dmg builds a read-only, compressed image with a Finder layout.
rm -rf build/dmg-root && mkdir -p build/dmg-root
cp -R build/export/Backglance.app build/dmg-root/
create-dmg \
  --volname "Backglance $VERSION" \
  --window-pos 200 120 \
  --window-size 560 380 \
  --icon-size 128 \
  --icon "Backglance.app" 140 180 \
  --app-drop-link 420 180 \
  --no-internet-enable \
  "$DIST/Backglance-$VERSION.dmg" \
  build/dmg-root/

# The DMG is its own notarization unit: sign it, notarize it, staple it.
codesign --force --sign "Developer ID Application: Backglance (TEAMID1234)" --timestamp "$DIST/Backglance-$VERSION.dmg"
xcrun notarytool submit "$DIST/Backglance-$VERSION.dmg" --keychain-profile backglance-notary --wait
xcrun stapler staple "$DIST/Backglance-$VERSION.dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DIST/Backglance-$VERSION.dmg"
# accepted, source=Notarized Developer ID

# Checksums (published as a release asset; bump_cask.sh cross-checks against it)
( cd "$DIST" && shasum -a 256 "Backglance-$VERSION.zip" "Backglance-$VERSION.dmg" > SHA256SUMS.txt )
```

> 💡 **Tip:** `Scripts/sign_and_notarize.sh build/export/Backglance.app 1.0.0` runs Steps 3–5 together and leaves the zip, dmg and `SHA256SUMS.txt` in `build/dist/`.

## Step 6 — Sparkle appcast

The appcast is the only thing Backglance ever fetches from the network, and only when the user has left "Check for updates automatically" on (or clicks "Check for Updates…"). `Scripts/make_appcast.sh` runs `generate_appcast`, which:

- signs the zip with the EdDSA private key (from Keychain locally, from `SPARKLE_PRIVATE_KEY` on stdin in CI) and writes `sparkle:edSignature` + `length`,
- sets `sparkle:version` (build number, `20`) and `sparkle:shortVersionString` (`1.0.0`) from the app's `Info.plist`,
- sets `sparkle:minimumSystemVersion` from `LSMinimumSystemVersion` (`14.0`),
- embeds the release notes HTML (rendered from the CHANGELOG section),
- creates binary **delta** updates from the previous releases' zips (downloaded from GitHub Releases into the work dir), named `Backglance21-20.delta` and so on,
- merges the new `<item>` into the existing `appcast.xml` fetched from `gh-pages` (older items keep their URLs).

```bash
Scripts/make_appcast.sh 1.0.0 build/dist
# → build/dist/appcast.xml
# → build/dist/Backglance20-19.delta  (only if a previous release exists)
```

Sanity-check the item before publishing anything:

```bash
xmllint --noout build/dist/appcast.xml && echo "well-formed"
grep -E 'sparkle:(version|shortVersionString|minimumSystemVersion|edSignature)|enclosure url' build/dist/appcast.xml | head
```

Do **not** push the appcast yet — the enclosure URLs point at release assets that do not exist until Step 7.

Full details (script source, key management, appcast anatomy, hosting): [PACKAGING_NOTARIZATION.md → Sparkle 2 setup](./PACKAGING_NOTARIZATION.md#sparkle-2-setup).

## Step 7 — GitHub Release

Create the release as a **draft**, attach every asset, publish, and only then push the appcast. Release notes come from the CHANGELOG section (the same text Sparkle shows).

```bash
VERSION=1.0.0
DIST=build/dist

# 1. Extract this version's CHANGELOG section into a notes file
awk -v ver="$VERSION" '
  $0 ~ "^## \\[" ver "\\]" { grab = 1; next }
  grab && /^## \[/       { exit }
  grab                   { print }
' CHANGELOG.md > "$DIST/RELEASE_NOTES.md"
test -s "$DIST/RELEASE_NOTES.md" || { echo "no CHANGELOG section for $VERSION"; exit 1; }

# 2. Draft release with all assets
gh release create "v$VERSION" \
  --repo backglance/backglance \
  --draft \
  --title "Backglance $VERSION" \
  --notes-file "$DIST/RELEASE_NOTES.md" \
  "$DIST/Backglance-$VERSION.zip" \
  "$DIST/Backglance-$VERSION.dmg" \
  "$DIST/SHA256SUMS.txt" \
  "$DIST/appcast.xml"                      # a copy, for auditability; Sparkle reads gh-pages
ls "$DIST"/*.delta >/dev/null 2>&1 && gh release upload "v$VERSION" "$DIST"/*.delta --repo backglance/backglance

# 3. Look at it in the browser once, then publish
gh release view "v$VERSION" --repo backglance/backglance --web
gh release edit "v$VERSION" --repo backglance/backglance --draft=false --latest

# 4. Confirm the asset URLs the appcast points to are reachable
curl -fsIL "https://github.com/backglance/backglance/releases/download/v$VERSION/Backglance-$VERSION.zip" | grep -i '^content-length'

# 5. NOW publish the appcast (point of no return)
git worktree add build/gh-pages gh-pages
cp "$DIST/appcast.xml" build/gh-pages/appcast.xml
( cd build/gh-pages && git add appcast.xml && git commit -m "appcast: $VERSION" && git push origin gh-pages )
git worktree remove build/gh-pages

# 6. Mirror the served appcast into the main branch (kept for reference)
git checkout gh-pages -- appcast.xml
git commit -m "chore: mirror appcast for $VERSION" && git push origin main

# 7. Verify GitHub Pages picked it up (can take a minute)
curl -fsSL https://backglance.github.io/backglance/appcast.xml | grep -c "$VERSION"
```

> ⚠️ **Warning:** Publish the release before pushing the appcast, never the other way round. An appcast pointing at a 404 makes Sparkle show "An error occurred while downloading the update" to every user who checks in that window.

## Step 8 — Homebrew cask bump

The cask lives in `backglance/homebrew-tap` (`Casks/backglance.rb`) and points at the release zip. `Scripts/bump_cask.sh` downloads the zip, computes the sha256, cross-checks it against `SHA256SUMS.txt`, edits `version` and `sha256`, and opens a PR.

```bash
Scripts/bump_cask.sh 1.0.0
# cloning backglance/homebrew-tap ...
# sha256 3f0c...e91a matches SHA256SUMS.txt
# https://github.com/backglance/homebrew-tap/pull/12
```

Review and merge the PR (the tap has no CI beyond `brew style`, so read the diff). Then confirm from a Mac that has the tap:

```bash
brew update
brew info --cask backglance/tap/backglance | head -3      # backglance: 1.0.0
brew upgrade --cask backglance                              # or install --cask backglance/tap/backglance
```

The cask sets `auto_updates true`, so Homebrew users who already run the app get the Sparkle update anyway; the bump keeps `brew install` and `brew upgrade` truthful. Cask authoring and the future `brew bump-cask-pr` flow for homebrew-cask core: [PACKAGING_NOTARIZATION.md → Homebrew cask](./PACKAGING_NOTARIZATION.md#homebrew-cask).

## Step 9 — Announce

Announcing is deliberately small. Backglance is free and open source with no metrics to move; the goal is that people who look for it can find the current state.

1. **README compatibility table** — already updated in pre-flight; if the release added an OS row, double-check the rendered README on GitHub.
2. **GitHub Discussions → Announcements**: one post titled `Backglance 1.0.0`, containing the CHANGELOG section, the two download links (dmg for humans, `brew install --cask backglance/tap/backglance`), and any known issues (especially degraded-mode notes for a macOS beta). Pin it, unpin the previous one.
3. **Pin/unpin issues**: close the release tracking issue; if a schema-break issue was fixed by this release, close it with a link to the release.

That is all. No mailing list, no "share on social" prompt in the app, no changelog nag on launch. Sparkle's own update dialog shows the release notes to people who already run the app.

## Step 10 — Post-release verification

Do these on the day of release. Each is a real user path.

### Fresh Mac install (Gatekeeper path)

On a Mac (or a clean VM / a second user account) that never had Backglance:

```bash
curl -fsSL -o ~/Downloads/Backglance-1.0.0.dmg \
  https://github.com/backglance/backglance/releases/download/v1.0.0/Backglance-1.0.0.dmg
open ~/Downloads/Backglance-1.0.0.dmg
# Drag to /Applications, eject, launch from Finder (double-click — not `open`, so quarantine applies)
xattr -p com.apple.quarantine /Applications/Backglance.app     # attribute present = Gatekeeper evaluated it
spctl --assess --type execute --verbose=4 /Applications/Backglance.app
# /Applications/Backglance.app: accepted
# source=Notarized Developer ID
```

Expected UX: no "unidentified developer" dialog, only the standard "downloaded from the Internet" prompt; onboarding appears; the FDA step deep-links to System Settings; after granting FDA the archive fills. Then the Homebrew path on the same machine after `sudo rm -rf /Applications/Backglance.app`: `brew install --cask backglance/tap/backglance`.

### Sparkle update from the previous version

On a Mac that runs the **previous** release (keep one around — a second user account with the old build is enough):

1. Backglance ▸ Check for Updates… → the dialog offers 1.0.0 with the release notes rendered.
2. Install → the app relaunches on 1.0.0 (About window shows `1.0.0 (20)`).
3. `~/Library/Logs/Backglance/backglance.log` shows the `updates` category lines and no errors; the archive is intact (`sqlite3 ~/Library/Application\ Support/Backglance/archive.sqlite "select count(*) from notifications;"` unchanged).
4. If a delta was published, the log line from Sparkle names the `.delta`; if the delta failed to apply, Sparkle silently falls back to the full zip — check that the fallback did not happen every time (a broken delta wastes bandwidth but is not a user-visible failure).

### Automated checks

- `fixtures.yml` nightly stays green after release (the release did not change adapters unexpectedly).
- `curl -fsSL https://backglance.github.io/backglance/appcast.xml | xmllint --noout -` succeeds.
- The GitHub Release page shows the zip download counter increasing over the next days — that is the only "analytics" there is, and it lives on GitHub, not in the app.

## The automated path

Pushing an annotated tag `vX.Y.Z` runs `.github/workflows/release.yml`, which executes Steps 2–8 on a `macos-26` runner using the same scripts (`Scripts/build.sh`, `Scripts/sign_and_notarize.sh`, `Scripts/make_appcast.sh`) and finally dispatches `cask-bump.yml`. Steps 1, 9 and 10 stay human. The full YAML, the secrets it needs (`DEVELOPER_ID_CERT_P12_BASE64`, `DEVELOPER_ID_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD`, `SPARKLE_PRIVATE_KEY`, `HOMEBREW_TAP_TOKEN`) and how each secret is created are in [CI_CD.md → release.yml](./CI_CD.md#releaseyml--tag-to-published-release).

```bash
# The entire automated release, from a green main:
agvtool new-marketing-version 1.0.0 && agvtool next-version -all
"${EDITOR:-vim}" CHANGELOG.md
git commit -am "release: 1.0.0 (build 20)"
git tag -a v1.0.0 -m "Backglance 1.0.0"
git push origin main v1.0.0
gh run watch --repo backglance/backglance      # ~25–35 minutes, most of it notarization
```

What the workflow does that you would otherwise do by hand:

| Step | Manual | Automated (`release.yml`) |
|---|---|---|
| Certificate | login keychain | temp keychain from `DEVELOPER_ID_CERT_P12_BASE64`, deleted at the end |
| Notary credentials | keychain profile | `--apple-id/--team-id/--password` from `NOTARY_*` secrets |
| Sparkle key | Keychain | `SPARKLE_PRIVATE_KEY` piped to `generate_appcast --ed-key-file -` |
| Release | draft → publish | draft → publish (same `gh` commands) |
| Appcast | push from worktree | push from worktree with `GITHUB_TOKEN` |
| Cask | `Scripts/bump_cask.sh` | `repository_dispatch` → `cask-bump.yml` → same script |

If the workflow fails **before** the appcast push, delete the draft release (`gh release delete v1.0.0 --yes`), fix, and either re-run the job or delete and re-push the tag (`git tag -d v1.0.0; git push origin :v1.0.0` then re-tag). If it fails **after** the appcast push (only the cask dispatch is after it), run `Scripts/bump_cask.sh` by hand.

## Rollback and hotfixes

### What "rollback" means for a Sparkle-distributed app

There is no remote kill switch. Backglance has **no remote configuration, no feature flags, no server it consults** — the only remotely controlled thing is `appcast.xml`, and all it controls is which version Sparkle offers. State this plainly to yourself before an incident: you cannot disable capture, change a setting, or make an installed build do anything from the outside. You can only offer (or stop offering) a new build.

Two consequences:

1. **Sparkle never downgrades automatically.** Removing 1.0.1 from the appcast stops *new* people from getting it; users who already installed 1.0.1 stay on 1.0.1 (Sparkle only offers items whose `sparkle:version` is greater than the installed build). The way to "roll back" for them is to publish a **higher** build that contains the older code — that is a hotfix, not a rollback.
2. **Homebrew and the Releases page are separate channels.** Pulling an appcast item does not touch the cask or the download page.

### Pull an appcast entry (stop offering a bad build)

```bash
git worktree add build/gh-pages gh-pages
cd build/gh-pages
# Remove the <item> for 1.0.1 (build 21). Keep the older items so 1.0.0 remains offered to <1.0.0 users.
python3 - <<'PY'
import re, pathlib
p = pathlib.Path("appcast.xml")
xml = p.read_text()
xml, n = re.subn(r"\s*<item>(?:(?!</item>).)*?<sparkle:version>21</sparkle:version>(?:(?!</item>).)*?</item>", "", xml, flags=re.S)
assert n == 1, f"expected exactly one item for build 21, removed {n}"
p.write_text(xml)
PY
xmllint --noout appcast.xml
git commit -am "appcast: pull 1.0.1 (build 21) — see issue #NNN" && git push origin gh-pages
cd - && git worktree remove build/gh-pages
```

Within 24 hours no automatic check offers 1.0.1 anymore. Then decide about the other channels:

- **GitHub Release:** mark it as pre-release or edit the notes with a warning; deleting assets is a last resort because the cask URL and any pasted links break. `gh release edit v1.0.1 --prerelease --notes "Withdrawn: see #NNN. Use 1.0.2."`. To actually yank an asset: `gh release delete-asset v1.0.1 Backglance-1.0.1.zip --yes` (only after the cask has been moved off it).
- **Homebrew cask:** either leave it (the zip is still there) or open a tap PR reverting `version`/`sha256` to 1.0.0 — `Scripts/bump_cask.sh 1.0.0` works in reverse because it only rewrites the two fields.

### Publish a hotfix instead of a downgrade

The normal move. Branch from the tag, cherry-pick or revert, bump the build number, release through the same path.

```bash
git checkout -b hotfix/1.0.2 v1.0.1
BAD_COMMIT=$(git rev-parse v1.0.1)          # whichever commit introduced the problem
git revert "$BAD_COMMIT"                    # or fix forward
agvtool new-marketing-version 1.0.2 && agvtool next-version -all      # build 22
"${EDITOR:-vim}" CHANGELOG.md               # ## [1.0.2] - 2026-08-19  Fixed: ...
git commit -am "release: 1.0.2 (build 22)"
git tag -a v1.0.2 -m "Backglance 1.0.2"
git push origin hotfix/1.0.2 v1.0.2         # release.yml runs from the tag
# afterwards: merge hotfix/1.0.2 back into main
```

Because `sparkle:version` 22 > 21, every 1.0.1 user is offered 1.0.2, and every 1.0.0 user skips straight to 1.0.2. If the appcast still contains the 1.0.1 item at that point it does no harm — Sparkle offers the highest applicable item — but pull it anyway so nobody installing "the previous version" by hand from an old link is nudged toward it.

### Emergency: a release that damages the archive

If a release corrupts `archive.sqlite` or its migration fails, the priority order is: (1) pull the appcast item, (2) post an Announcement with the manual workaround (quit Backglance, restore `~/Library/Application Support/Backglance/archive.sqlite.bak-<version>` which every migration writes before running — see [MAINTENANCE.md](../operations/MAINTENANCE.md)), (3) hotfix. There is still no remote flag; the app on the user's Mac will keep doing what its code says until they update.

## Release cadence and hotfix policy

| Kind | When | Version | Notes |
|---|---|---|---|
| Minor (`1.x.0`) | Roughly every 6–8 weeks while there is a v1.x roadmap item ready ([ROADMAP.md](../reference/ROADMAP.md)) | bump Y | Features, archive migrations (`v2_saved_searches` …) |
| Patch (`1.0.x`) | When a fix is worth shipping; batch small ones for up to two weeks | bump Z | No archive migrations |
| Schema hotfix | As soon as an adapter can be verified against a fixture for the new macOS build | bump Z | See below |
| Beta-OS release | At each macOS developer beta that changes the store, and at GM | bump Z (or Y at GM) | Adapter row in the compat table moves from 🧪 to ✅ at GM |

### macOS schema breaks

⚠️ Capture reads an undocumented system store, and Apple can change it in any release, including point releases. The playbook ([OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md)) covers detection and adapter work; the release-side policy is:

1. **Detection is not a release event.** When the nightly fixture/live-probe run or a user report shows an unknown fingerprint, the app is already in degraded mode on that macOS (`CaptureStatus.degraded(.unknownSchema(fp))`, timeline still works, capture pauses). No release is needed to be "safe" — the adapter refused to guess.
2. **Hotfix target: within 7 days** of a confirmed break on a *released* macOS version, sooner if the fix is a fingerprint-only re-registration (same layout, new hash). For a *beta* macOS, the fix ships with the next regular release unless the beta is at RC.
3. **A schema hotfix contains only** the adapter/fingerprint change, the new fixture, the compat table row, and the CHANGELOG entry. Nothing else rides along, so it can be reviewed in minutes and pulled without collateral damage.
4. **Communicate in the same place every time:** the auto-opened issue gets the status, and the Announcements post for the hotfix links it.

## Release checklist (copy into the tracking issue)

```markdown
## Release 1.0.0 (build 20)

Pre-flight
- [ ] CHANGELOG section written and moved out of [Unreleased]
- [ ] ci / build-test + ci / lint green on main
- [ ] fixtures.yml green on macos-14, macos-15, macos-26 (last nightly)
- [ ] Compatibility table identical in README + playbook
- [ ] Manual smoke test on macOS 26 (fresh clone)
- [ ] SUPublicEDKey matches signing key (`generate_keys -p`)
- [ ] No get-task-allow / debug leftovers

Release
- [ ] agvtool bump, commit "release: 1.0.0 (build 20)", tag v1.0.0, push
- [ ] release.yml green (or manual Steps 2–7 done)
- [ ] GitHub Release published, assets: zip, dmg, SHA256SUMS.txt, appcast.xml, deltas
- [ ] appcast.xml on gh-pages serves the new item
- [ ] Cask PR merged in backglance/homebrew-tap

Announce
- [ ] Discussions ▸ Announcements post pinned
- [ ] Tracking issue closed

Verify
- [ ] Fresh Mac: dmg install, spctl accepted, onboarding + FDA + capture OK
- [ ] Fresh Mac: brew install --cask backglance/tap/backglance
- [ ] Previous version: Sparkle update to 1.0.0, archive intact
- [ ] Next nightly fixtures run green
```

## Next Steps

- Never released before? Read [PACKAGING_NOTARIZATION.md](./PACKAGING_NOTARIZATION.md) once end-to-end and do the manual path for `0.1.0` on your own machine before enabling `release.yml`.
- Setting up the repository secrets and branch protection: [CI_CD.md](./CI_CD.md).
- Understanding what a schema break looks like before you get one: [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md).

## Related Documentation

- [PACKAGING_NOTARIZATION.md](./PACKAGING_NOTARIZATION.md) — signing, notarization, Sparkle, DMG, Homebrew cask, the scripts
- [CI_CD.md](./CI_CD.md) — `ci.yml`, `fixtures.yml`, `release.yml`, `cask-bump.yml`, secrets
- [PERFORMANCE_GUIDE.md](./PERFORMANCE_GUIDE.md) — budgets to re-check before a release
- [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md) — adapters, fingerprints, schema breaks
- [TESTING.md](../testing/TESTING.md) — fixture suite, `make_fixture.sh`, `verify_fixture.sh`
- [MAINTENANCE.md](../operations/MAINTENANCE.md) — archive backups and migrations
- [TROUBLESHOOTING.md](../operations/TROUBLESHOOTING.md) — user-facing symptoms after a bad release
- [PERMISSIONS_PRIVACY.md](../features/PERMISSIONS_PRIVACY.md) — the "Sparkle is the only network access" guarantee
- [SECURITY.md](../security/SECURITY.md) — signing key custody, incident handling
- [COST_ESTIMATION.md](../reference/COST_ESTIMATION.md) — Developer Program fee, CI minutes
- [ROADMAP.md](../reference/ROADMAP.md) — what goes into which minor release
- [CHANGELOG.md](../../CHANGELOG.md) · [README.md](../../README.md)
