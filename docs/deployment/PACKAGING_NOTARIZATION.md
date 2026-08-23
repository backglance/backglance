# Packaging & Notarization

Last Updated: 2026-08-18

This document is the reference for everything that turns a built `Backglance.app` into something a stranger's Mac will launch without complaint and keep up to date: the Developer ID certificate, hardened runtime and entitlements, the `Info.plist` keys that matter for distribution, the exact `codesign` order for a bundle that embeds Sparkle, notarization and stapling with `notarytool`, the Sparkle 2 updater (keys, appcast, hosting, the in-app toggle and the "no network when off" guarantee), the two release scripts (`Scripts/sign_and_notarize.sh`, `Scripts/make_appcast.sh`), the DMG, and the Homebrew cask. The step-by-step release choreography that *uses* all of this lives in [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md); the workflow YAML that automates it lives in [CI_CD.md](./CI_CD.md). Backglance is not sandboxed and not on the Mac App Store — Full Disk Access is incompatible with App Sandbox — so everything here is the Developer ID path, not the App Store path.

## Table of Contents

- [Overview](#overview)
- [Developer ID codesigning](#developer-id-codesigning)
  - [Certificate types](#certificate-types)
  - [Creating the certificate](#creating-the-certificate)
  - [Exporting a .p12 for CI](#exporting-a-p12-for-ci)
  - [Checking what the keychain has](#checking-what-the-keychain-has)
- [Hardened runtime and entitlements](#hardened-runtime-and-entitlements)
- [Info.plist keys](#infoplist-keys)
- [codesign commands and the `--deep` caveat](#codesign-commands-and-the---deep-caveat)
- [Notarization with notarytool](#notarization-with-notarytool)
  - [Storing credentials](#storing-credentials)
  - [Submitting](#submitting)
  - [Reading notarytool log: common errors](#reading-notarytool-log-common-errors)
- [Stapling and Gatekeeper checks](#stapling-and-gatekeeper-checks)
- [Sparkle 2 setup](#sparkle-2-setup)
  - [SPM dependency](#spm-dependency)
  - [EdDSA keys](#eddsa-keys)
  - [SparkleUpdaterController and the "off means off" guarantee](#sparkleupdatercontroller-and-the-off-means-off-guarantee)
  - [generate_appcast and the appcast anatomy](#generate_appcast-and-the-appcast-anatomy)
  - [Hosting on gh-pages](#hosting-on-gh-pages)
- [Scripts/sign_and_notarize.sh](#scriptssign_and_notarizesh)
- [Scripts/make_appcast.sh](#scriptsmake_appcastsh)
- [DMG creation with create-dmg](#dmg-creation-with-create-dmg)
- [Homebrew cask](#homebrew-cask)
  - [Casks/backglance.rb](#casksbackglancerb)
  - [Bump flow: Scripts/bump_cask.sh](#bump-flow-scriptsbump_casksh)
  - [homebrew-cask core, later](#homebrew-cask-core-later)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Overview

```
 Backglance.app (from Scripts/build.sh, universal, exported with method developer-id)
        │
        ▼
 codesign (inside-out)          Sparkle XPCs → Autoupdate → Updater.app → Sparkle.framework → Backglance.app
   --options runtime            hardened runtime, no exceptions
   --timestamp                  secure timestamp (notarization requires it)
   --entitlements               Backglance/Backglance.entitlements (effectively empty: no sandbox)
        │
        ▼
 notarytool submit --wait       Apple scans the zip, returns a ticket
 stapler staple                 ticket attached to the .app (and later to the .dmg)
        │
        ├──▶ Backglance-X.Y.Z.zip   (ditto)         → Sparkle enclosure + Homebrew cask url
        └──▶ Backglance-X.Y.Z.dmg   (create-dmg)    → humans, GitHub Releases page
        │
        ▼
 generate_appcast               EdDSA-signs the zip, writes appcast.xml (+ .delta files)
        │
        ▼
 gh-pages: appcast.xml          https://backglance.github.io/backglance/appcast.xml
 homebrew-tap: Casks/backglance.rb   brew install --cask backglance/tap/backglance
```

Three independent trust systems are involved, and it helps to keep them apart in your head:

| System | Who checks | What it proves | Key |
|---|---|---|---|
| Developer ID signature + notarization | Gatekeeper on the user's Mac, once at first launch | The bundle is from a known Apple developer and Apple scanned it | Developer ID certificate (Apple-issued, in your keychain) |
| Sparkle EdDSA signature | Sparkle inside the running app, at every update | The update archive was produced by whoever holds the Backglance private key | Ed25519 key pair you generate (`generate_keys`) |
| Homebrew `sha256` | `brew` at install time | The download is the exact bytes the cask author saw | none (a hash pinned in the cask) |

Losing the Developer ID key is an inconvenience (revoke, reissue, resign). Losing the Sparkle private key is worse: every installed copy trusts only that key, and there is no remote way to rotate it. Custody rules are in [SECURITY.md](../security/SECURITY.md).

## Developer ID codesigning

### Certificate types

Apple's developer portal offers several certificate types. Only two matter for an app distributed outside the App Store, and Backglance uses exactly one of them.

| Certificate | Signs | Used by Backglance |
|---|---|---|
| Apple Development | Debug builds on your own Macs | Yes, implicitly (Xcode automatic signing for local Debug builds) |
| Apple Distribution / Mac App Distribution | App Store submissions | No — Backglance is not on the App Store |
| Mac Installer Distribution | App Store `.pkg` | No |
| **Developer ID Application** | Apps, frameworks, XPC services, `.dmg` distributed outside the App Store | **Yes** — the release identity `"Developer ID Application: Backglance (TEAMID1234)"` |
| Developer ID Installer | `.pkg` installers distributed outside the App Store | No — Backglance ships a `.dmg` and a zip, no installer package |

Facts worth knowing before you create one:

- Developer ID Application certificates are valid for **five years**. Signatures with a secure timestamp remain valid after the certificate expires; only *new* signing needs a fresh certificate.
- An Apple Developer account can hold a limited number of Developer ID Application certificates (five, at the time of writing). Do not create one per machine — export and import instead ([Exporting a .p12 for CI](#exporting-a-p12-for-ci)).
- The private key is generated on the Mac that makes the request and never leaves it unless you export it. If the `.cer` is imported on a Mac without that private key, `security find-identity` will not list it and `codesign` will say the identity is not found.
- The intermediate "Developer ID Certification Authority" (G2) must be present. Xcode installs it; on a bare machine, download it from https://www.apple.com/certificateauthority/ and double-click it.

### Creating the certificate

**Via Xcode (simplest):** Xcode ▸ Settings ▸ Accounts ▸ select the team ▸ Manage Certificates… ▸ `+` ▸ Developer ID Application. Xcode generates the key pair, sends the CSR, and installs the certificate in the login keychain. Only the Account Holder of the team can create Developer ID certificates.

**Via the developer portal (when you want to control the CSR):**

```bash
# 1. Generate a private key + certificate signing request with Keychain Access:
#    Keychain Access ▸ Certificate Assistant ▸ Request a Certificate From a Certificate Authority…
#    ("Saved to disk", leave CA email empty). Or from the command line:
openssl genrsa -out ~/Desktop/developerid.key 2048
openssl req -new -key ~/Desktop/developerid.key \
  -subj "/emailAddress=dev@example.com/CN=Backglance/C=XX" \
  -out ~/Desktop/developerid.certSigningRequest

# 2. developer.apple.com ▸ Certificates ▸ + ▸ Developer ID Application ▸ upload the CSR ▸ download developerID_application.cer

# 3. Import the certificate; the matching private key must be in the same keychain
security import ~/Desktop/developerid.key -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
security import ~/Downloads/developerID_application.cer -k ~/Library/Keychains/login.keychain-db
```

Xcode's route is recommended for a solo developer: fewer places for the private key to be.

### Exporting a .p12 for CI

`release.yml` needs the identity as a base64-encoded PKCS#12 blob (`DEVELOPER_ID_CERT_P12_BASE64`) plus its password (`DEVELOPER_ID_CERT_PASSWORD`).

1. Keychain Access ▸ login ▸ My Certificates ▸ expand "Developer ID Application: Backglance (TEAMID1234)" so both the certificate and its private key are visible ▸ select the certificate row ▸ File ▸ Export Items… ▸ format "Personal Information Exchange (.p12)" ▸ set a strong password.
2. Encode and store it as a repository secret:

```bash
# base64 without line breaks (macOS `base64` wraps at 76 chars only with -b; -i is the input file)
base64 -i ~/Desktop/DeveloperID.p12 | tr -d '\n' > ~/Desktop/DeveloperID.p12.b64
gh secret set DEVELOPER_ID_CERT_P12_BASE64 --repo backglance/backglance < ~/Desktop/DeveloperID.p12.b64
gh secret set DEVELOPER_ID_CERT_PASSWORD  --repo backglance/backglance      # prompts for the value

# Then get the plaintext off your disk
rm -P ~/Desktop/DeveloperID.p12 ~/Desktop/DeveloperID.p12.b64
```

Test that the blob round-trips before you rely on it:

```bash
base64 --decode < ~/Desktop/DeveloperID.p12.b64 > /tmp/roundtrip.p12
openssl pkcs12 -in /tmp/roundtrip.p12 -nokeys -info -passin pass:"$DEVELOPER_ID_CERT_PASSWORD" 2>/dev/null | grep -E 'subject=|notAfter'
# subject=UID=TEAMID1234, CN=Developer ID Application: Backglance (TEAMID1234), OU=TEAMID1234, O=Backglance, C=XX
rm -P /tmp/roundtrip.p12
```

> 🔒 **Security:** The `.p12` is the whole identity. Store it only in the GitHub secret and in a password manager; never commit it, never paste it into an issue. If it leaks, revoke the certificate in the portal — existing notarized builds keep working because their timestamps predate the revocation.

### Checking what the keychain has

```bash
security find-identity -v -p codesigning
#   1) 1F2E3D4C5B6A79880123456789ABCDEF01234567 "Apple Development: you@example.com (ABCDE12345)"
#   2) 0A1B2C3D4E5F60718293A4B5C6D7E8F901234567 "Developer ID Application: Backglance (TEAMID1234)"
#      2 valid identities found
```

Only entries marked *valid* (listed under `-v`) can sign. If the Developer ID line is missing:

| Symptom | Cause | Fix |
|---|---|---|
| Not listed at all | Certificate not imported, or imported into a different keychain | Import the `.p12`; check `security list-keychains` |
| Listed by `security find-certificate` but not by `find-identity` | Private key missing | Import the `.p12` (contains the key), not the `.cer` |
| Listed, but `codesign` says "no identity found" in CI | Key partition list not set for `codesign` | `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN"` |
| "CSSMERR_TP_CERT_REVOKED" | Certificate revoked in the portal | Create a new one; re-export the `.p12` secret |

## Hardened runtime and entitlements

Notarization requires the hardened runtime (`codesign --options runtime`). The hardened runtime enables library validation (the process may load only frameworks signed by Apple or by the same Team ID), disallows debugging and DYLD environment overrides, and gates a handful of capabilities behind entitlements. Backglance needs **none** of the exception entitlements:

| Hardened-runtime exception | Needed by Backglance? | Why not |
|---|---|---|
| `com.apple.security.cs.disable-library-validation` | No | The only embedded framework is `Sparkle.framework`, re-signed with the same Developer ID identity, so library validation passes. GRDB is linked statically through SPM. |
| `com.apple.security.cs.allow-jit` / `allow-unsigned-executable-memory` | No | No JIT, no scripting runtime |
| `com.apple.security.cs.allow-dyld-environment-variables` | No | Nothing is injected |
| `com.apple.security.cs.debugger` | No | Not a debugger |
| `com.apple.security.automation.apple-events` | No | Backglance does not script other apps (deep links use `NSWorkspace.open`, which needs nothing) |
| `com.apple.security.device.*` / `personal-information.*` | No for v1.0 | v1.x Reminders export uses `NSRemindersFullAccessUsageDescription`, a usage string, not an entitlement (outside the sandbox) |

So `Backglance/Backglance.entitlements` is a valid, deliberately empty entitlements plist:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!--
      Deliberately empty.

      No com.apple.security.app-sandbox: Backglance reads Apple's Notification Center
      store (~/Library/Group Containers/group.com.apple.usernoted/db2/db), which is
      only reachable with Full Disk Access. FDA is a TCC grant to the app's code
      signature and is incompatible with App Sandbox. That is also why Backglance
      is not on the Mac App Store.

      No com.apple.security.cs.disable-library-validation: Sparkle.framework is
      re-signed with the same Developer ID identity as the app, so library
      validation (part of the hardened runtime) already accepts it.

      No com.apple.security.get-task-allow: Xcode injects it for Debug builds via
      CODE_SIGN_INJECT_BASE_ENTITLEMENTS; a Release archive must not carry it, or
      notarization is refused.
    -->
</dict>
</plist>
```

Why there is no sandbox, stated plainly for anyone auditing the app: TCC grants Full Disk Access to a code-signing identity; a sandboxed process is confined to its container and cannot use that grant to read another app's group container. There is no entitlement that lets a sandboxed app read `group.com.apple.usernoted` (it belongs to Apple's `usernoted`), so the sandbox is off, and the app makes up for it by being open source, by opening the store read-only on a copied snapshot, and by keeping its own archive under `0600`/`0700` permissions ([PERMISSIONS_PRIVACY.md](../features/PERMISSIONS_PRIVACY.md)).

Verify a signed build's entitlements are what you think they are:

```bash
codesign -d --entitlements - --xml build/export/Backglance.app 2>/dev/null | plutil -p -
# { }        <- empty dict: exactly what we want for the app

codesign -d --entitlements - --xml \
  build/export/Backglance.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc | plutil -p -
# {
#   "com.apple.security.app-sandbox" => 1
#   "com.apple.security.network.client" => 1
# }          <- Sparkle's Downloader XPC keeps its own entitlements (see --preserve-metadata below)
```

> ⚠️ **Warning:** A Release build that was signed by Xcode's automatic signing in a *Debug* configuration will contain `com.apple.security.get-task-allow`. `Scripts/build.sh` archives with `-configuration Release`, and `Scripts/sign_and_notarize.sh` refuses to continue if the entitlement is present.

## Info.plist keys

`Backglance/Info.plist` keys that affect distribution, updates, or the app's identity. Build settings fill in `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)` (bumped with `agvtool`, see [DEPLOYMENT_GUIDE.md → Step 1](./DEPLOYMENT_GUIDE.md#step-1--version-bump-and-tag)).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>app.backglance.Backglance</string>
    <key>CFBundleName</key>
    <string>Backglance</string>
    <key>CFBundleDisplayName</key>
    <string>Backglance</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>

    <!-- Menu bar app: no Dock icon, no app menu when it is frontmost. Onboarding and the
         timeline window still work; they are ordinary windows opened by the status item. -->
    <key>LSUIElement</key>
    <true/>

    <key>NSHumanReadableCopyright</key>
    <string>Copyright (C) 2026 the Backglance authors. GPL-3.0.</string>

    <!-- Sparkle 2. SUFeedURL moves to https://backglance.app/appcast.xml once the domain is confirmed;
         that is an app update, not a server-side switch, so old builds keep reading GitHub Pages. -->
    <key>SUFeedURL</key>
    <string>https://backglance.github.io/backglance/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>$(SU_PUBLIC_ED_KEY)</string>
    <!-- Sparkle would otherwise show its own "check automatically?" prompt on second launch.
         Backglance owns that decision (onboarding + Settings ▸ Updates); default is on. -->
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <!-- Never download silently; the user sees release notes and confirms. -->
    <key>SUAutomaticallyUpdate</key>
    <false/>
    <!-- Sparkle's optional anonymous system profile is off and stays off. -->
    <key>SUEnableSystemProfiling</key>
    <false/>

    <!-- backglance://search?q=… · open?id=… · digest · pause?minutes=… · resume (URLSchemeHandler.swift) -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>CFBundleURLName</key>
            <string>app.backglance.Backglance.url</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>backglance</string>
            </array>
        </dict>
    </array>

    <!-- v1.x, only when the Reminders export ships -->
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>Backglance can create a Reminder from a notification you snooze. Nothing else is read or written.</string>
</dict>
</plist>
```

Notes:

- `SUPublicEDKey` is a build-setting substitution, and only `Config/Release.xcconfig` defines `SU_PUBLIC_ED_KEY` (with the output of `generate_keys -p`). A Debug build resolves it to the empty string, which `SparkleUpdaterController` treats exactly like a missing key: it skips startup, so a debug build never contacts the network by accident ([SETUP_GUIDE.md](../getting-started/SETUP_GUIDE.md)). The substitution is what makes this per-configuration — `INFOPLIST_KEY_*` overrides only apply to a *generated* Info.plist, and Backglance authors its own.
- No `NSAppTransportSecurity` dictionary: the appcast and release assets are `https`, so no exception is needed, and its absence is part of the "only Sparkle talks to the network" story ([FAQ.md](../reference/FAQ.md)).
- `LSMinimumSystemVersion` is what `generate_appcast` copies into `sparkle:minimumSystemVersion`; keep it equal to the deployment target.

## codesign commands and the `--deep` caveat

Xcode's `-exportArchive` already produces a signed bundle. `Scripts/sign_and_notarize.sh` signs again with explicit flags so that a laptop build and a CI build carry byte-identical signing options, and so that the Sparkle pieces are signed in the right order. The rules:

1. **Sign inside-out.** Nested code first, then its container. Every signature covers the code below it, so signing the app first and a nested XPC afterwards invalidates the app's seal.
2. **Same identity everywhere.** Sparkle's XPC services, helper and framework are re-signed with `"Developer ID Application: Backglance (TEAMID1234)"`, which is what makes library validation under the hardened runtime accept the framework with no exception entitlement.
3. **Hardened runtime and timestamp on every executable.** `--options runtime --timestamp` on each `codesign` call; notarization checks nested executables individually.
4. **Preserve Sparkle's own entitlements** on `Downloader.xpc` (`--preserve-metadata=entitlements`); it is sandboxed with `network.client` and must stay that way.

```bash
IDENTITY="Developer ID Application: Backglance (TEAMID1234)"
APP=build/export/Backglance.app
FW="$APP/Contents/Frameworks/Sparkle.framework"

# 1. Sparkle 2 internals (paths are fixed by the Sparkle SPM artifact, Versions/B)
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$FW/Versions/B/XPCServices/Installer.xpc"
codesign --force --sign "$IDENTITY" --options runtime --timestamp --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$FW/Versions/B/Autoupdate"
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$FW/Versions/B/Updater.app"

# 2. The framework itself (signs Versions/Current)
codesign --force --sign "$IDENTITY" --options runtime --timestamp "$FW"

# 3. The app, last, with its (empty) entitlements
codesign --force --sign "$IDENTITY" --options runtime --timestamp \
  --entitlements Backglance/Backglance.entitlements "$APP"

# 4. Verify — --deep is fine (and useful) for VERIFICATION
codesign --verify --deep --strict --verbose=2 "$APP"
# build/export/Backglance.app: valid on disk
# build/export/Backglance.app: satisfies its Designated Requirement

codesign -dvv "$APP" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Timestamp|CodeDirectory|Sealed)|flags='
# Identifier=app.backglance.Backglance
# CodeDirectory v=20500 size=... flags=0x10000(runtime) hashes=...
# Authority=Developer ID Application: Backglance (TEAMID1234)
# Authority=Developer ID Certification Authority
# Authority=Apple Root CA
# Timestamp=17 Aug 2026 at 10:12:03
# TeamIdentifier=TEAMID1234
# Sealed Resources version=2 rules=13 files=...
```

### Why not `codesign --deep`?

`--deep` recursively signs nested code, which sounds like exactly what we want. It is not, for three reasons:

- **It applies your flags to everything.** `man codesign`: "all signing options you specify will apply, in turn, to such nested content." That means the app's `--entitlements` file would replace `Downloader.xpc`'s sandbox entitlements with Backglance's empty ones, and Sparkle's downloader would then run unsandboxed and, worse, fail notarization's consistency checks.
- **Ordering and discovery are heuristic.** `--deep` finds nested code by directory conventions and can miss or mis-order helpers inside a framework's `Versions/B`. Sign the pieces you know about, explicitly.
- **Apple says not to.** Technical Note TN2206 and the notarization documentation both restrict `--deep` to verification. Xcode itself never uses `--deep` when signing.

`codesign --verify --deep --strict` on the other hand walks every nested item and is the right check before notarizing.

> ❌ **Don't:** `codesign --deep --force --sign "$IDENTITY" --options runtime --entitlements Backglance.entitlements Backglance.app`. It "works" on your machine and then notarization returns "The signature of the binary is invalid" for `Downloader.xpc`.

> ✅ **Do:** sign the Sparkle XPCs, helper, and `Updater.app`, then the framework, then the app, each with `--options runtime --timestamp` — which is what `Scripts/sign_and_notarize.sh` does.

## Notarization with notarytool

Notarization uploads the signed bundle (as a zip, dmg, or pkg — never a bare `.app`) to Apple, which scans it for malware and signing problems and, if accepted, records a "ticket" for that bundle's code-directory hash. Gatekeeper on the user's Mac either finds the ticket online or, if you stapled it, inside the bundle. Requirements checked by the service: Developer ID signature, hardened runtime, secure timestamp, no `get-task-allow`, every nested executable signed, SDK not ancient.

### Storing credentials

Locally, `notarytool` reads credentials from a keychain profile so no password lives in shell history. You need an Apple ID that is a member of the team, the Team ID, and an **app-specific password** (appleid.apple.com ▸ Sign-In and Security ▸ App-Specific Passwords ▸ generate; the value looks like `abcd-efgh-ijkl-mnop`).

```bash
export AC_APPLE_ID="you@example.com"
export AC_TEAM_ID="TEAMID1234"
export AC_PASSWORD="abcd-efgh-ijkl-mnop"      # app-specific password, NOT your Apple ID password

xcrun notarytool store-credentials backglance-notary \
  --apple-id "$AC_APPLE_ID" \
  --team-id "$AC_TEAM_ID" \
  --password "$AC_PASSWORD"
# This process stores your credentials securely in the Keychain. ...
# Validating your credentials...
# Success. Credentials validated.
# Credentials saved to Keychain.
# To use them, specify `--keychain-profile "backglance-notary"`

# Prove it works (also useful weeks later when you wonder if the password was rotated)
xcrun notarytool history --keychain-profile backglance-notary | head -5
```

In CI there is no interactive keychain profile; `release.yml` passes `--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD"` from repository secrets ([CI_CD.md → secrets](./CI_CD.md#secrets)). `Scripts/sign_and_notarize.sh` picks whichever is available.

An App Store Connect API key (`--key`, `--key-id`, `--issuer`) also works and does not depend on an Apple ID; Backglance uses the app-specific password because a solo developer's Apple ID is not going anywhere and the secret is one string instead of a `.p8` file plus two IDs.

### Submitting

```bash
APP=build/export/Backglance.app
ditto -c -k --keepParent "$APP" build/notary-upload.zip     # ditto keeps the bundle structure Apple expects

xcrun notarytool submit build/notary-upload.zip \
  --keychain-profile backglance-notary \
  --wait --timeout 30m \
  --output-format json | tee build/notary-result.json
# {"status":"Accepted","id":"1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d","message":"Processing complete"}
```

Typical durations: 2–10 minutes for a 20 MB app; occasionally longer on Apple's side. `--wait` blocks; without it, `notarytool info <id>` polls. `--timeout` makes an unattended run fail instead of hanging forever.

If you did not use `--wait`, or want the record later:

```bash
xcrun notarytool info 1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d --keychain-profile backglance-notary
xcrun notarytool history --keychain-profile backglance-notary       # last submissions with status
```

### Reading notarytool log: common errors

When `status` is `Invalid`, the reasons are in the log, not in the submit output:

```bash
xcrun notarytool log 1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d --keychain-profile backglance-notary build/notary-log.json
plutil -p build/notary-log.json | grep -E '"(status|message|path|severity)"'
```

The log is JSON with an `issues` array; each issue has `severity` (`error` or `warning`), `path` (which nested file), `message`, and sometimes `docUrl`. Warnings do not fail notarization; errors do. The ones that come up in practice:

| Message in `issues[].message` | Path it points at | Cause | Fix |
|---|---|---|---|
| `The signature of the binary is invalid.` | any nested item, often `Downloader.xpc` or `Autoupdate` | Signed with `--deep` (entitlements clobbered) or modified after signing | Re-sign inside-out; do not touch the bundle after signing |
| `The executable does not have the hardened runtime enabled.` | an executable | Missing `--options runtime` on that item | Add the flag to every `codesign` call |
| `The signature does not include a secure timestamp.` | an executable | Missing `--timestamp`, or the timestamp server was unreachable | Add `--timestamp`; retry if you were offline |
| `The binary is not signed with a valid Developer ID certificate.` | app or nested item | Signed with Apple Development / ad-hoc (`-`) | Sign with the Developer ID identity; check `security find-identity` |
| `The executable requests the com.apple.security.get-task-allow entitlement.` | `Contents/MacOS/Backglance` | Debug configuration or Xcode-injected base entitlements | Archive with `-configuration Release`; check with `codesign -d --entitlements -` |
| `The binary uses an SDK older than the 10.9 SDK.` | usually a third-party binary | Prebuilt dependency from a very old toolchain | Rebuild it; Backglance has no such binary today |
| `Package Invalid` / `The software asset has an unexpected format.` | — | Uploaded a bare `.app` directory or a zip made with Finder's "Compress" | Zip with `ditto -c -k --keepParent` |
| HTTP `401`/`403` from `submit` (`Invalid credentials` / `Not authorized`) | — | Wrong app-specific password, wrong Team ID, or the Apple ID is not on the team | Recreate the profile; in CI, re-set `NOTARY_PASSWORD` |
| `Team is not yet configured for notarization` | — | Newest developer agreements not accepted | Account Holder accepts them at developer.apple.com |
| `Submission was rejected` with a `warning` only, e.g. `The signature algorithm used is too weak.` | old `.pkg`/dmg | Older toolchain | Not seen with Xcode 16+; upgrade |

> 💡 **Tip:** After fixing, you do **not** need a new build number; notarization has no notion of versions. Re-sign, re-zip, re-submit the same bundle.

## Stapling and Gatekeeper checks

Stapling attaches the ticket to the bundle so first launch works offline. Only bundles (`.app`), disk images and installer packages can be stapled; a zip cannot. So the app is stapled on disk *and then* zipped, and the DMG is separately signed, notarized and stapled.

```bash
xcrun stapler staple build/export/Backglance.app
# Processing: /…/build/export/Backglance.app
# The staple and validate action worked!

xcrun stapler validate build/export/Backglance.app
# Processing: /…/build/export/Backglance.app
# The validate action worked!

# What Gatekeeper on a user's Mac will conclude
spctl --assess --type execute --verbose=4 build/export/Backglance.app
# build/export/Backglance.app: accepted
# source=Notarized Developer ID
# origin=Developer ID Application: Backglance (TEAMID1234)

# For the DMG the assessment type is "open" with the primary-signature context
spctl --assess --type open --context context:primary-signature --verbose=4 build/dist/Backglance-1.0.0.dmg
# build/dist/Backglance-1.0.0.dmg: accepted
# source=Notarized Developer ID
```

Failure modes and what they mean:

| `spctl` output | Meaning |
|---|---|
| `rejected` / `source=no usable signature` | Not signed, or ad-hoc |
| `rejected` / `source=Unnotarized Developer ID` | Signed correctly, not notarized (or ticket not yet propagated and no staple, offline) |
| `accepted` / `source=Developer ID` (without "Notarized") | Older macOS assessing an unnotarized but signed app; on macOS 14+ you should always see "Notarized" |
| `stapler validate` says `The validate action failed! Error 65` | Bundle modified after stapling, or never stapled |

## Sparkle 2 setup

Sparkle is the only network client in Backglance. This section covers the dependency, the keys, the in-app controller (including the toggle that guarantees "no network when off"), appcast generation, and hosting.

### SPM dependency

In Xcode: File ▸ Add Package Dependencies… ▸ `https://github.com/sparkle-project/Sparkle` ▸ Dependency Rule "Up to Next Major Version" from `2.7.0` ▸ add the `Sparkle` product to the `Backglance` app target. That embeds `Sparkle.framework` in `Contents/Frameworks/` (Embed & Sign) and resolves the binary artifact that also contains the command-line tools:

```bash
# After Scripts/build.sh (or xcodebuild -resolvePackageDependencies -clonedSourcePackagesDirPath build/SourcePackages)
ls build/SourcePackages/artifacts/sparkle/Sparkle/bin/
# BinaryDelta  generate_appcast  generate_keys  sign_update
```

The Sparkle 2 XPC services (`Installer.xpc`, `Downloader.xpc`) are required only for sandboxed apps. Backglance is not sandboxed and does not enable `SUEnableInstallerLauncherService`/`SUEnableDownloaderService`; the services still ship inside the framework (they are part of the artifact) and are signed like everything else so notarization is happy.

### EdDSA keys

Sparkle 2 verifies each downloaded archive with an Ed25519 signature. The private key signs at release time; the public key is baked into the app as `SUPublicEDKey`.

```bash
SPARKLE_BIN=build/SourcePackages/artifacts/sparkle/Sparkle/bin

# One time, on the release Mac. Generates the key pair and stores the PRIVATE key in the login Keychain
# (item "Private key for signing Sparkle updates"). Prints the PUBLIC key.
"$SPARKLE_BIN/generate_keys"
# A key has been generated and saved in your keychain. Add the `SUPublicEDKey` key to
# the Info.plist of each app for which you intend to use Sparkle for distributing
# updates. It should appear like this:
#
#     <key>SUPublicEDKey</key>
#     <string>pfl6C3v3lD0S1G8lTF+HcRJz2XowH+E9YbmZWjplPBg=</string>

# Later: print the public key again (pre-flight check against Info.plist)
"$SPARKLE_BIN/generate_keys" -p

# Export the private key for CI (the SPARKLE_PRIVATE_KEY secret). Treat this file like the .p12.
"$SPARKLE_BIN/generate_keys" -x ~/Desktop/sparkle_private_key.txt
gh secret set SPARKLE_PRIVATE_KEY --repo backglance/backglance < ~/Desktop/sparkle_private_key.txt
rm -P ~/Desktop/sparkle_private_key.txt

# Import a previously exported key on a new Mac
"$SPARKLE_BIN/generate_keys" -f ~/Desktop/sparkle_private_key.txt
```

`generate_appcast` and `sign_update` look the key up in the Keychain by default; with `--ed-key-file <path>` (or `-` for stdin) they read the exported form, which is what `release.yml` does with the secret. Sign a single file by hand when debugging:

```bash
"$SPARKLE_BIN/sign_update" build/dist/Backglance-1.0.0.zip
# sparkle:edSignature="Nz2M…==" length="18234567"
```

> 🔒 **Security:** There is exactly one Sparkle key pair for Backglance and no rotation mechanism short of shipping a new public key inside an update signed by the old private key. Back the private key up (password manager, offline). Never regenerate "to be safe" — a new pair silently orphans every installed copy.

### SparkleUpdaterController and the "off means off" guarantee

`Backglance/App/SparkleUpdaterController.swift` owns the `SPUStandardUpdaterController`. Design goals, in order: (1) with the toggle off, no network request is ever made; (2) the toggle is Backglance's own setting, not Sparkle's dialog; (3) manual "Check for Updates…" always works because the user asked for it explicitly.

```swift
import AppKit
import Combine
import Sparkle
import os

/// Owns the Sparkle updater. Every network request Backglance ever makes starts here,
/// and every one of them stops when `automaticChecksEnabled` is false.
@MainActor
final class SparkleUpdaterController: NSObject, ObservableObject {

    /// UserDefaults key (suite app.backglance.Backglance). Registered default: true.
    static let automaticChecksDefaultsKey = "updates.checkAutomatically"

    private static let logger = Logger(subsystem: "app.backglance.Backglance", category: "updates")

    private let controller: SPUStandardUpdaterController
    private let defaults: UserDefaults
    private var started = false

    /// Mirrors Sparkle's KVO-compliant `canCheckForUpdates` for the menu item / button state.
    @Published private(set) var canCheckForUpdates = false

    /// The user-facing "Check for updates automatically" toggle.
    @Published var automaticChecksEnabled: Bool {
        didSet { apply(automaticChecks: automaticChecksEnabled) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Self.automaticChecksDefaultsKey: true])
        automaticChecksEnabled = defaults.bool(forKey: Self.automaticChecksDefaultsKey)
        // startingUpdater: false — nothing is scheduled and nothing touches the network
        // until start() decides to, based on the setting.
        controller = SPUStandardUpdaterController(startingUpdater: false,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        super.init()
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Called once from `AppDelegate.applicationDidFinishLaunching(_:)`.
    func start() {
        guard ProcessInfo.processInfo.environment["BACKGLANCE_DISABLE_UPDATER"] != "1" else {
            Self.logger.notice("updater disabled by BACKGLANCE_DISABLE_UPDATER")
            return
        }
        guard Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String else {
            // Debug builds do not embed the public key on purpose.
            Self.logger.notice("SUPublicEDKey missing — updater not started (debug build)")
            return
        }
        guard automaticChecksEnabled else {
            // Guarantee, part 1: with the toggle off at launch, Sparkle is never started,
            // so it never schedules a check and never opens a connection.
            Self.logger.notice("automatic update checks are off — updater not started")
            return
        }
        startUpdaterIfNeeded()
    }

    /// Backglance ▸ Check for Updates… — user-initiated, works even when automatic checks are off.
    func checkForUpdates() {
        startUpdaterIfNeeded()
        controller.checkForUpdates(nil)
    }

    // MARK: - Private

    private func startUpdaterIfNeeded() {
        guard !started else { return }
        let updater = controller.updater
        updater.automaticallyChecksForUpdates = automaticChecksEnabled   // also suppresses Sparkle's own permission prompt
        updater.automaticallyDownloadsUpdates = false                     // always show release notes and ask
        updater.sendsSystemProfile = false                                // no anonymous system profile, ever
        updater.updateCheckInterval = 86_400                              // once a day when enabled
        do {
            try updater.start()
            started = true
            Self.logger.info("updater started; automatic checks = \(self.automaticChecksEnabled)")
        } catch {
            // Typical causes: SUFeedURL missing or not https, SUPublicEDKey malformed.
            Self.logger.error("updater failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func apply(automaticChecks enabled: Bool) {
        defaults.set(enabled, forKey: Self.automaticChecksDefaultsKey)
        if enabled {
            startUpdaterIfNeeded()
            controller.updater.automaticallyChecksForUpdates = true
        } else {
            // Guarantee, part 2: Sparkle cancels its scheduled check the moment this becomes false.
            // Nothing else in Backglance owns a URLSession, so from here on the process makes no
            // network requests until the user clicks "Check for Updates…" themselves.
            controller.updater.automaticallyChecksForUpdates = false
        }
        Self.logger.notice("automatic update checks \(enabled ? "enabled" : "disabled", privacy: .public)")
    }
}
```

The Settings ▸ Updates pane and the status-item menu are the only two entry points:

```swift
import SwiftUI

struct UpdatesSettingsView: View {
    @EnvironmentObject private var updater: SparkleUpdaterController

    var body: some View {
        Form {
            Toggle("Check for updates automatically", isOn: $updater.automaticChecksEnabled)
            Text("When this is off, Backglance makes no network connections at all. Updates are the only thing it ever fetches; there is no telemetry and no crash reporting.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        .formStyle(.grouped)
    }
}
```

```swift
// StatusItemController.swift — menu item wiring (AppKit side)
let checkItem = NSMenuItem(title: "Check for Updates…",
                           action: #selector(checkForUpdates(_:)),
                           keyEquivalent: "")
checkItem.target = self
menu.addItem(checkItem)

@objc private func checkForUpdates(_ sender: Any?) {
    updaterController.checkForUpdates()
}
```

What the guarantee rests on, so it can be audited rather than believed:

1. `SPUStandardUpdaterController(startingUpdater: false, …)` creates the updater without starting it; Sparkle performs no network I/O before `start()`.
2. `start()` is only called when the toggle is on (or on an explicit manual check).
3. `automaticallyChecksForUpdates = false` resets Sparkle's update cycle; no timer, no background check. Sparkle 2's own documentation describes this property as the switch for scheduled checks.
4. `automaticallyDownloadsUpdates = false` and `sendsSystemProfile = false` are set in code and in `Info.plist`, so neither a silent download nor a profile ping can happen even during a user-initiated check beyond fetching the appcast and, on confirmation, the archive.
5. Nothing else in the app links a networking API. `git grep -n "URLSession\|NWConnection\|CFStream" Backglance/ Packages/` returns only Sparkle-adjacent code, and the SwiftLint rule `no_network_outside_updater` keeps it that way ([DEVELOPMENT_GUIDE.md](../getting-started/DEVELOPMENT_GUIDE.md)).
6. You can watch it: `nettop -p "$(pgrep -x Backglance)"` with the toggle off shows no connections; with it on, one connection to `backglance.github.io` per day.

> ℹ️ **Info:** "Off" removes Sparkle's scheduled checks. It does not remove the *ability* to check: clicking "Check for Updates…" is a deliberate, one-off network request and Backglance treats it as consent for that request only.

### generate_appcast and the appcast anatomy

`generate_appcast` takes a directory of update archives, signs each with EdDSA, reads version and minimum-OS from the archived app's `Info.plist`, generates binary deltas between the newest archive and the older ones present, embeds release notes if an `.html` file with the archive's basename exists, and writes/updates `appcast.xml` in that directory. Items already in an existing `appcast.xml` whose archives are not present are left untouched, which is how older releases keep their URLs and signatures.

```bash
SPARKLE_BIN=build/SourcePackages/artifacts/sparkle/Sparkle/bin
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/backglance/backglance/releases/download/v1.0.0/" \
  --link "https://github.com/backglance/backglance/releases/tag/v1.0.0" \
  --embed-release-notes \
  --maximum-deltas 2 \
  build/appcast-work/
```

`Scripts/make_appcast.sh` wraps this with the CHANGELOG-to-HTML step, the previous-release downloads and the gh-pages fetch ([below](#scriptsmake_appcastsh)). The result for the second release looks like this:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Backglance</title>
    <link>https://github.com/backglance/backglance</link>
    <description>Backglance updates</description>
    <language>en</language>
    <item>
      <title>1.0.1</title>
      <link>https://github.com/backglance/backglance/releases/tag/v1.0.1</link>
      <sparkle:version>21</sparkle:version>
      <sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>Wed, 02 Sep 2026 09:00:00 +0000</pubDate>
      <description><![CDATA[
        <h3>Fixed</h3>
        <ul>
          <li>macOS 26.6 store fingerprint re-registered for StoreAdapterV26; capture no longer enters degraded mode after the point update.</li>
          <li>Digest banner respected the "only after 10 min" threshold once, then reverted to 5 min.</li>
        </ul>
      ]]></description>
      <enclosure url="https://github.com/backglance/backglance/releases/download/v1.0.1/Backglance-1.0.1.zip"
                 length="18234567"
                 type="application/octet-stream"
                 sparkle:edSignature="Nz2MHK6i0Yz3fJ0v6a…==" />
      <sparkle:deltas>
        <enclosure url="https://github.com/backglance/backglance/releases/download/v1.0.1/Backglance21-20.delta"
                   sparkle:deltaFrom="20"
                   length="412300"
                   type="application/octet-stream"
                   sparkle:edSignature="Qm5nZ2xhbmNlIGRl…==" />
      </sparkle:deltas>
    </item>
    <item>
      <title>1.0.0</title>
      <link>https://github.com/backglance/backglance/releases/tag/v1.0.0</link>
      <sparkle:version>20</sparkle:version>
      <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>Mon, 17 Aug 2026 12:00:00 +0000</pubDate>
      <description><![CDATA[
        <h3>Added</h3>
        <ul><li>First release: capture, timeline, search, digest, rules, per-app retention.</li></ul>
      ]]></description>
      <enclosure url="https://github.com/backglance/backglance/releases/download/v1.0.0/Backglance-1.0.0.zip"
                 length="18190001"
                 type="application/octet-stream"
                 sparkle:edSignature="c2lnbmF0dXJlIGZvciAx…==" />
    </item>
  </channel>
</rss>
```

Field by field:

| Element / attribute | Source | Meaning |
|---|---|---|
| `sparkle:version` | `CFBundleVersion` (`CURRENT_PROJECT_VERSION`) | The number Sparkle **compares**. Must strictly increase; `21 > 20` is what makes 1.0.1 an update for 1.0.0 users. Never reuse. |
| `sparkle:shortVersionString` | `CFBundleShortVersionString` (`MARKETING_VERSION`) | The number Sparkle **shows** ("Backglance 1.0.1 is now available — you have 1.0.0"). Cosmetic for comparison purposes. |
| `sparkle:minimumSystemVersion` | `LSMinimumSystemVersion` | Sparkle hides the item from Macs below it. When macOS 27 drops Intel and a future release raises the deployment target, users on older macOS simply stop seeing new items — no error, no nag. |
| `enclosure url`, `length`, `sparkle:edSignature` | `--download-url-prefix` + file name, file size, Ed25519 signature | Sparkle downloads, checks size, verifies the signature before extracting anything. |
| `sparkle:deltas` | `--maximum-deltas` and older archives in the work dir | Optional binary patches; a failed delta falls back to the full zip silently. |
| `description` (CDATA HTML) | `Backglance-1.0.1.html` next to the zip, from `--embed-release-notes` | Release notes rendered in the update dialog (WebKit, JavaScript off). Keep to headings, paragraphs, lists. |
| `pubDate` | generation time | Informational. |

Release notes come from the CHANGELOG section (`## [1.0.1] - 2026-09-02`) converted with `pandoc -f gfm -t html`; the same text is used for the GitHub Release. Nothing is written twice.

> ⚠️ **Warning:** `sparkle:version` is compared as a version string, component-wise. `20 < 21 < 100` behaves as integers, so keep it a plain integer forever; a `1.0.0` in that field would compare lower than `20` and never be offered.

### Hosting on gh-pages

The appcast is a static file served by GitHub Pages from the `gh-pages` branch of `backglance/backglance`, at `https://backglance.github.io/backglance/appcast.xml`. Setup, once:

```bash
# Create the orphan branch with an empty appcast placeholder and a .nojekyll (so nothing is preprocessed)
git checkout --orphan gh-pages
git rm -rf . >/dev/null 2>&1 || true
touch .nojekyll
cat > appcast.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Backglance</title>
    <link>https://github.com/backglance/backglance</link>
    <description>Backglance updates</description>
    <language>en</language>
  </channel>
</rss>
XML
git add .nojekyll appcast.xml
git commit -m "gh-pages: empty appcast"
git push -u origin gh-pages
git checkout main

# Repository ▸ Settings ▸ Pages ▸ Source: Deploy from a branch ▸ gh-pages / (root). Or:
gh api -X POST repos/backglance/backglance/pages -f 'source[branch]=gh-pages' -f 'source[path]=/'
```

Publishing a new item is a commit to that branch ([DEPLOYMENT_GUIDE.md → Step 7](./DEPLOYMENT_GUIDE.md#step-7--github-release)). GitHub Pages serves it over HTTPS with `Content-Type: application/xml`, which Sparkle accepts. Propagation is usually under a minute; `curl -fsSL https://backglance.github.io/backglance/appcast.xml | xmllint --noout -` is the check.

Moving to `https://backglance.app/appcast.xml` later means: add a `CNAME` file to `gh-pages`, point DNS at GitHub Pages, ship an update whose `SUFeedURL` is the new URL, and keep the old URL serving the same file for as long as pre-move builds might still be running (indefinitely is fine; it costs nothing).

## Scripts/sign_and_notarize.sh

The complete script. It is what both the manual path and `release.yml` run; the only differences are which notary credentials it finds and where the certificate lives.

```bash
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
```

Run it and what to expect:

```bash
Scripts/sign_and_notarize.sh build/export/Backglance.app 1.0.0
# ==> Backglance 1.0.0 (build 20) — build/export/Backglance.app
# ==> notary credentials: keychain profile backglance-notary
# ==> Signing (inside-out)
# ==> Verifying signature
# build/export/Backglance.app: valid on disk
# build/export/Backglance.app: satisfies its Designated Requirement
# ==> Submitting app for notarization (this takes a few minutes)
# ==> Notarization of app: Accepted (submission 1a2b3c4d-…)
# ==> Stapling app
# The staple and validate action worked!
# The validate action worked!
# build/export/Backglance.app: accepted
# source=Notarized Developer ID
# ==> Wrote build/dist/Backglance-1.0.0.zip (18M)
# ==> Submitting dmg for notarization (this takes a few minutes)
# ==> Notarization of dmg: Accepted (submission 9f8e7d6c-…)
# ==> Wrote build/dist/Backglance-1.0.0.dmg (19M)
# ==> Checksums:
# 3f0c…e91a  Backglance-1.0.0.zip
# 77ab…0c42  Backglance-1.0.0.dmg
# ==> Done. Next: Scripts/make_appcast.sh 1.0.0 build/dist
```

And a failure, with the log excerpt the script prints:

```
==> Submitting app for notarization (this takes a few minutes)
==> Notarization of app: Invalid (submission 5b6c7d8e-…)
  "severity" => "error"
  "path" => "Backglance-notary.zip/Backglance.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
  "message" => "The executable does not have the hardened runtime enabled."
error: notarization failed for app — see docs/deployment/PACKAGING_NOTARIZATION.md#reading-notarytool-log-common-errors
```

## Scripts/make_appcast.sh

Builds `appcast.xml` (and delta files) for one version into the dist directory. Locally it signs with the Keychain key; when `SPARKLE_PRIVATE_KEY` is set (CI) it feeds the exported key on stdin.

```bash
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
```

## DMG creation with create-dmg

The DMG exists for humans who download from the Releases page and expect a window with an Applications shortcut. Sparkle and Homebrew use the zip. `create-dmg` (Homebrew, `brew install create-dmg`) builds a compressed, read-only image with a Finder layout in one command; the flags below are what `Scripts/sign_and_notarize.sh` uses.

```bash
VERSION=1.0.0
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
  build/dist/Backglance-$VERSION.dmg \
  build/dmg-root/
# Creating disk image...
# created: /…/build/dist/Backglance-1.0.0.dmg
```

Optional polish, when there is an asset for it: `--background Backglance/Resources/dmg-background.png` (560×380 pt, provide `@2x` too) and `--volicon Backglance/Resources/dmg-volume.icns`. `--no-internet-enable` keeps the image from auto-extracting on download in Safari, which would skip the drag-to-Applications step some people rely on.

Then the DMG is signed, notarized and stapled as its own unit (Gatekeeper evaluates the image when it is opened, and the app inside when it is launched):

```bash
codesign --force --sign "Developer ID Application: Backglance (TEAMID1234)" --timestamp build/dist/Backglance-$VERSION.dmg
xcrun notarytool submit build/dist/Backglance-$VERSION.dmg --keychain-profile backglance-notary --wait
xcrun stapler staple build/dist/Backglance-$VERSION.dmg
spctl --assess --type open --context context:primary-signature --verbose=4 build/dist/Backglance-$VERSION.dmg
# accepted, source=Notarized Developer ID
```

Checking the image by hand: `hdiutil attach build/dist/Backglance-1.0.0.dmg -readonly`, look at the window, `spctl --assess --type execute /Volumes/Backglance\ 1.0.0/Backglance.app`, `hdiutil detach /Volumes/Backglance\ 1.0.0`.

## Homebrew cask

The cask lives in the tap `backglance/homebrew-tap` as `Casks/backglance.rb`; users install with `brew install --cask backglance/tap/backglance`. It points at the release zip on GitHub Releases and pins its sha256. Until the tap exists, the checked-in seed at `Scripts/tap/Casks/backglance.rb` carries this exact content (kept `brew style`-clean); `Scripts/tap/README.md` is the one-time tap creation procedure, after which the tap's copy is canonical.

### Casks/backglance.rb

```ruby
cask "backglance" do
  version "1.0.0"
  sha256 "3f0c1a9b8e7d6c5b4a39281706f5e4d3c2b1a0998877665544332211aabbccdd"

  url "https://github.com/backglance/backglance/releases/download/v#{version}/Backglance-#{version}.zip"
  name "Backglance"
  desc "Searchable local archive of notifications, in the menu bar"
  homepage "https://github.com/backglance/backglance"

  # `brew livecheck backglance` reads the latest non-prerelease GitHub Release tag (vX.Y.Z)
  livecheck do
    url :url
    strategy :github_latest
  end

  # The app updates itself with Sparkle; brew upgrade is not the only path.
  auto_updates true
  # macos: :version means "this or newer"; brew style rejects the old ">= :sonoma" string form.
  depends_on macos: :sonoma

  app "Backglance.app"

  uninstall quit:       "app.backglance.Backglance",
            login_item: "Backglance"

  # `brew uninstall --zap backglance` also removes user data. Order matters to nobody; the list is
  # everything Backglance writes: archive + icon cache + tmp snapshots, logs, preferences, caches.
  zap trash: [
    "~/Library/Application Support/Backglance",
    "~/Library/Caches/app.backglance.Backglance",
    "~/Library/Logs/Backglance",
    "~/Library/Preferences/app.backglance.Backglance.plist",
  ]
end
```

Notes on the choices:

- `homepage` is the GitHub repository until `backglance.app` is confirmed live; both are on `github.com`, so no `verified:` stanza is needed on the `url`. When the homepage moves, add `verified: "github.com/backglance/backglance/"`.
- `depends_on macos: ">= :sonoma"` mirrors `LSMinimumSystemVersion` 14.0.
- `zap trash` deliberately includes the archive directory. `brew uninstall` alone leaves the archive in place, `--zap` deletes it; that matches the app's own "Wipe archive" being a separate, deliberate action ([PRIVACY_CONTROLS.md](../features/PRIVACY_CONTROLS.md)).
- Login item removal uses the `SMAppService.mainApp` display name (`Backglance`).

Check the file before opening a PR:

```bash
brew style Casks/backglance.rb
brew audit --cask --online Casks/backglance.rb        # from inside the tap checkout; --online fetches the url and checks sha256
brew install --cask ./Casks/backglance.rb              # local install test
brew uninstall --cask --zap backglance
```

### Bump flow: Scripts/bump_cask.sh

`Scripts/bump_cask.sh <version>` (in the main repository) downloads the release zip and `SHA256SUMS.txt`, verifies the hash, rewrites the two lines in the cask, and opens a PR against the tap. In CI it runs from `cask-bump.yml` with `GH_TOKEN=$HOMEBREW_TAP_TOKEN` ([CI_CD.md → cask-bump.yml](./CI_CD.md#cask-bumpyml--tap-pr-after-a-release)).

```bash
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
```

```bash
Scripts/bump_cask.sh 1.0.0
# ==> Downloading Backglance-1.0.0.zip and SHA256SUMS.txt from v1.0.0
# ==> sha256 3f0c…ccdd matches SHA256SUMS.txt
# ==> Cloning backglance/homebrew-tap
# -  version "0.1.0"
# +  version "1.0.0"
# -  sha256 "…"
# +  sha256 "3f0c…ccdd"
# ==> https://github.com/backglance/homebrew-tap/pull/12
```

Merge the PR (read the diff: two lines), then on any Mac with the tap: `brew update && brew upgrade --cask backglance`.

### homebrew-cask core, later

Once the repository meets homebrew-cask's notability requirements (at the time of writing: at least 30 forks, 30 watchers and 75 stars, a stable — not beta — release, and no name clash), the cask can move to `homebrew/cask`, which drops the `backglance/tap/` prefix for users. The file is the same; submission is a PR to `Homebrew/homebrew-cask` created with `brew create --cask` and reviewed by their maintainers. After acceptance, version bumps use Homebrew's own tool instead of `Scripts/bump_cask.sh`:

```bash
brew bump-cask-pr --version 1.0.1 backglance
# forks/clones homebrew/cask, edits version + sha256 (downloads and hashes the url), opens the PR
```

Their CI (`brew audit --cask --online`, `brew style`, an install test) runs on the PR; the `livecheck` block lets their auto-bump bot open future PRs on its own. Until then the tap is authoritative and `Scripts/bump_cask.sh` is the flow.

## Next Steps

- First release ever: create the certificate, `store-credentials`, `generate_keys`, then run the manual path in [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md) for `0.1.0` before wiring up secrets.
- Wire the secrets and read the workflow YAML in [CI_CD.md](./CI_CD.md).
- Key custody and what to do if a key leaks: [SECURITY.md](../security/SECURITY.md).

## Related Documentation

- [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md) — the release choreography that uses these scripts
- [CI_CD.md](./CI_CD.md) — `release.yml`, `cask-bump.yml`, secrets, temp keychain import
- [PERFORMANCE_GUIDE.md](./PERFORMANCE_GUIDE.md) — budgets to re-check before a release
- [PERMISSIONS_PRIVACY.md](../features/PERMISSIONS_PRIVACY.md) — why there is no sandbox; the "only network access is Sparkle" guarantee
- [PRIVACY_CONTROLS.md](../features/PRIVACY_CONTROLS.md) — panic wipe vs `brew uninstall --zap`
- [SECURITY.md](../security/SECURITY.md) — signing key and Sparkle key custody, incident handling
- [SETUP_GUIDE.md](../getting-started/SETUP_GUIDE.md) — Debug vs Release configuration, `BACKGLANCE_DISABLE_UPDATER`
- [DEVELOPMENT_GUIDE.md](../getting-started/DEVELOPMENT_GUIDE.md) — SwiftLint rules including the no-network-outside-updater check
- [TECH_STACK.md](../architecture/TECH_STACK.md) — Sparkle 2.7.x, GRDB 7.x versions
- [FAQ.md](../reference/FAQ.md) — user-facing answers about signing, updates and network access
- [COST_ESTIMATION.md](../reference/COST_ESTIMATION.md) — Developer Program fee, CI minutes
- [CHANGELOG.md](../../CHANGELOG.md) · [README.md](../../README.md)
