# Frequently Asked Questions

Last Updated: 2026-08-18

This page collects the questions people ask about Backglance before installing it, right after installing it, and after something on their Mac changed. Answers are complete and honest, including the parts that are uncertain. Where a topic has a dedicated document, the answer links to it rather than duplicating it.

## Table of Contents

- [General](#general)
  - [What is Backglance?](#what-is-backglance)
  - [Is it really completely free? What's the catch?](#is-it-really-completely-free-whats-the-catch)
  - [Why isn't it on the Mac App Store?](#why-isnt-it-on-the-mac-app-store)
  - [How is this different from PasteShelf?](#how-is-this-different-from-pasteshelf)
  - [Will you add feature X / sell it / shut it down?](#will-you-add-feature-x--sell-it--shut-it-down)
- [Privacy & Permissions](#privacy--permissions)
  - [Why does it need Full Disk Access?](#why-does-it-need-full-disk-access)
  - [Is anything sent anywhere?](#is-anything-sent-anywhere)
  - [Where is my data stored and how do I back it up or delete everything?](#where-is-my-data-stored-and-how-do-i-back-it-up-or-delete-everything)
  - [Why are my 2FA codes shown as \[code redacted\]?](#why-are-my-2fa-codes-shown-as-code-redacted)
  - [Which apps are never archived?](#which-apps-are-never-archived)
- [Features](#features)
  - [Can it recover notifications from before I installed it?](#can-it-recover-notifications-from-before-i-installed-it)
  - [Does it capture notifications while it's not running?](#does-it-capture-notifications-while-its-not-running)
  - [Does muting an app here stop the notification from appearing?](#does-muting-an-app-here-stop-the-notification-from-appearing)
  - [What is the digest, and why didn't I get one?](#what-is-the-digest-and-why-didnt-i-get-one)
  - [Does it work with iPhone Mirroring / iOS app notifications?](#does-it-work-with-iphone-mirroring--ios-app-notifications)
  - [Can I search inside images or attachments?](#can-i-search-inside-images-or-attachments)
  - [Can I sync between two Macs?](#can-i-sync-between-two-macs)
- [Technical](#technical)
  - [What happens when Apple changes the store format?](#what-happens-when-apple-changes-the-store-format)
  - [Does it slow down my Mac or drain the battery?](#does-it-slow-down-my-mac-or-drain-the-battery)
  - [Does it run on an Intel Mac?](#does-it-run-on-an-intel-mac)
  - [Does it run on the macOS 27 beta?](#does-it-run-on-the-macos-27-beta)
  - [Can I build it myself?](#can-i-build-it-myself)
  - [How do I verify the binary is the official one?](#how-do-i-verify-the-binary-is-the-official-one)
  - [How do updates work?](#how-do-updates-work)
- [Project](#project)
  - [Why GPL and not MIT?](#why-gpl-and-not-mit)
  - [How do I report a bug or a security issue?](#how-do-i-report-a-bug-or-a-security-issue)
  - [Can I contribute?](#can-i-contribute)
- [Related Documentation](#related-documentation)

---

## General

### What is Backglance?

Backglance is a native macOS menu bar utility that keeps a private, searchable, local archive of every notification your Mac receives. macOS discards a notification the moment you dismiss it; Backglance keeps it. It also shows a digest of what you missed while you were away, locked, asleep, presenting, or in a Focus, and lets you set per-app retention, visual rules, and (in v1.x) analytics.

It runs entirely on your Mac. There is no account, no server, and no telemetry.

Tagline, for the curious: *"The notification history macOS never had."*

### Is it really completely free? What's the catch?

There is no catch, and here is the full model so you can judge for yourself:

- **License:** GPL-3.0. The whole app, not a "core" with a paid shell. One repository, `https://github.com/backglance/backglance`.
- **No paid tier.** There is no Pro version, no feature gating, no trial period.
- **No license keys.** Nothing to activate, nothing to expire.
- **No donation asks.** No banner, no "buy me a coffee" nag, no sponsor prompt in the app.
- **No upsell.** Backglance does not advertise other apps.
- **Official binary** is Developer ID signed and notarized and published for free on GitHub Releases and via a Homebrew cask. Building it yourself from source is equally supported.

Why free-forever? Partly because it is a small tool that should just exist, and partly because it answers the biggest risk this category has: Apple could ship native notification history in any macOS release. A paid app in that position has an incentive problem (keep charging for something the OS now does) and eventually a sunset. Backglance has none of that. If Apple ships history, Backglance still keeps its depth (digest, rules, analytics, search) and nothing has to be shut down, sold, or migrated. There is no company to acquire and no revenue to protect, which is precisely what makes "free forever" believable.

The developer's honest cost is time plus about $120–130 per year in fixed fees; see [Cost Estimation](./COST_ESTIMATION.md).

### Why isn't it on the Mac App Store?

Because it cannot be. Backglance reads Apple's Notification Center database (the system store), which lives at `~/Library/Group Containers/group.com.apple.usernoted/db2/db`. Reading that file requires **Full Disk Access (FDA)**, and FDA is incompatible with the App Sandbox that the Mac App Store requires. There is no entitlement or exception that gets around it.

So the distribution is: Developer ID signed + notarized `.dmg` on GitHub Releases, plus `brew install --cask backglance/tap/backglance`. Gatekeeper treats it as a normal notarized app; you will not see an "unidentified developer" warning.

### How is this different from PasteShelf?

They are different products for different problems, from the same developer. PasteShelf is a clipboard manager. Backglance is a notification archive. They share some **technical** patterns only: the hybrid search engine (FTS + on-device semantic embeddings + fuzzy matching) in Backglance is ported from PasteShelf's `EmbeddingManager` / `SemanticSearchEngine` / `HybridSearchEngine` / `FuzzyMatcher`, adapted to a GRDB store instead of Core Data. That is the extent of the relationship. Backglance is a standalone brand.

### Will you add feature X / sell it / shut it down?

- **Feature X:** Look at the [Roadmap](./ROADMAP.md) first. If it is not there, open a GitHub Discussion. Painkillers first, then depth, and privacy defaults are not negotiable, so features that need a server or an account will be declined.
- **Sell it:** There is nothing to sell. GPL-3.0 code, no user base to monetize, no accounts, no data. Anyone can fork it today.
- **Shut it down:** There is nothing to shut down. There is no server that could go dark. If the developer stopped working on it tomorrow, the last release would keep working until Apple changes the store format, and the repository would still be there for anyone to update the adapter.

---

## Privacy & Permissions

### Why does it need Full Disk Access?

Because the only source of notification history on macOS is Apple's own database, and that database is protected by FDA.

> ⚠️ **Warning:** This is an undocumented system database. There is no public API for notification history. Backglance reads the file directly, read-only, from a copied snapshot. This is what we have observed, not an API; column names may change in any macOS release, and the fingerprint + adapter + fixture strategy exists for that reason.

What Backglance does with FDA:

- Reads `~/Library/Group Containers/group.com.apple.usernoted/db2/db` (and its `-wal` / `-shm` files).
- Copies them to a temporary snapshot under `~/Library/Application Support/Backglance/tmp/` and opens the copy read-only (`?immutable=1`). It never opens Apple's live file for writing.
- Optionally reads two Focus-related files under `~/Library/DoNotDisturb/DB/` to detect Focus sessions for the digest.

What it does not do with FDA: it does not scan your disk, index files, read other apps' containers, or touch anything outside the paths above. You can verify this in the source: the `BackglanceCapture` package contains every filesystem path the app opens.

Without FDA, Backglance launches into degraded mode (`CaptureStatus.degraded(.noFullDiskAccess)`), explains what is missing, and offers a button to open System Settings ▸ Privacy & Security ▸ Full Disk Access. See [Permissions & Privacy](../features/PERMISSIONS_PRIVACY.md).

### Is anything sent anywhere?

No, with exactly one exception, and one opt-in.

**The exception: the Sparkle updater.** When "Automatically check for updates" is enabled, Backglance fetches the appcast (`https://backglance.github.io/backglance/appcast.xml`, moving to `https://backglance.app/appcast.xml` once the domain is confirmed) and, if you accept an update, downloads the new `.dmg` from GitHub Releases. Sparkle sends the standard HTTP request; that means the server sees your IP address, the `User-Agent` string (which includes the app name and version), and the request time. Backglance does **not** enable Sparkle's optional system-profile reporting, so no hardware model, OS version, or locale is transmitted. You can turn update checks off entirely in Settings ▸ Updates, and then Backglance makes zero network connections. This is documented as a guarantee, and you can confirm it with Little Snitch, LuLu, or `nettop`.

**The opt-in: CloudKit sync (v1.x, planned).** If you turn it on, your archive is synced through your own iCloud private database, which is end-to-end within your Apple ID and never visible to the developer. It is off by default and does not exist in v1.0.

There is no telemetry, no analytics, no crash reporter, no "anonymous usage statistics", no phone-home on launch, no license check. The app has no account system.

> 🔒 **Security:** The Info.plist declares no `NSAppTransportSecurity` exceptions and the app links no networking library beyond what Sparkle needs. See [Security](../security/SECURITY.md).

### Where is my data stored and how do I back it up or delete everything?

Everything is under your home directory:

| Path | What |
|---|---|
| `~/Library/Application Support/Backglance/archive.sqlite` (+ `-wal`, `-shm`) | The archive: every captured notification, rules, digests, settings stored in tables. File mode `0600`, directory `0700`. |
| `~/Library/Application Support/Backglance/icons/` | Cached app icons |
| `~/Library/Application Support/Backglance/tmp/` | Temporary snapshots of the system store, deleted after each read |
| `~/Library/Logs/Backglance/backglance.log` | Local rotating log (max 5 × 2 MB), never contains notification content |
| `~/Library/Preferences/app.backglance.Backglance.plist` | Settings (`UserDefaults`) |

**Back up:** Quit Backglance, then copy the `Backglance` folder in Application Support. Time Machine already includes it. Or use Export (CSV/JSON) from the timeline for a portable copy.

**Delete everything:** Settings ▸ Privacy ▸ "Wipe archive…" performs a panic wipe: it closes the database, enables SQLite secure delete, removes the archive, WAL, SHM, icons cache, temporary snapshots and embeddings, and recreates an empty archive. It asks you to type `wipe` and, where available, confirms with Touch ID. To remove the app itself, drag it to the Trash and delete the paths above; there are no other traces.

See [Privacy Controls](../features/PRIVACY_CONTROLS.md).

### Why are my 2FA codes shown as [code redacted]?

Because OTP redaction is on by default for Messages (`com.apple.MobileSMS`) and Mail (`com.apple.mail`). A notification archive is a place a one-time code should not sit for 30 days. The redactor looks for 4–8 digit codes near keywords like "code", "verification", "passcode", "OTP", "kod", "doğrulama", "Bestätigungscode", or whole-body messages that are only a code, and replaces the digits with `[code redacted]` **before** the notification is written to the archive. The original digits are never stored anywhere and never logged.

To change it: Settings ▸ Privacy ▸ Redaction. You can turn it off per app or add more apps (banking apps are a good candidate).

> ⚠️ **Warning:** Redaction is irreversible. Turning it off only affects notifications captured from that point on; anything already redacted stays redacted, because the original was never saved.

### Which apps are never archived?

By default: password managers (1Password, Bitwarden, Dashlane, LastPass), Apple Passwords, and Backglance itself. This is the exclusion list; excluded apps are never written to the archive at all. You can add any app to it (banking apps are a common addition) in Settings ▸ Privacy ▸ Excluded apps.

---

## Features

### Can it recover notifications from before I installed it?

Only what Apple's store still has. When Backglance first launches with FDA, it imports every record still present in the system store. macOS prunes that store when you clear notifications and on its own schedule (roughly a week, though this is not documented and varies). So a first import typically recovers the last few days, not months. From that point on, Backglance archives continuously.

Imported items are marked with `source = 'import'` in the archive and appear in the timeline like anything else.

### Does it capture notifications while it's not running?

There is no live capture while Backglance is quit, but you usually do not lose anything short-term. On the next launch, Backglance runs a late import: it reads the system store from its last cursor and picks up every record that arrived while it was closed and that macOS has not yet pruned. If you were away for a weekend, you will most likely get everything; if you were away for a month, only what the store still holds.

This is why "Launch at login" is on by default (via `SMAppService`); the app is meant to be always running and costs almost nothing when idle.

### Does muting an app here stop the notification from appearing?

No. This is a v1 boundary and it is deliberate. Rules and mutes in Backglance are **visual triage inside Backglance only**: a muted app is de-prioritized in the timeline and left out of the digest's top section, a highlight rule colors a row, a VIP rule pins to the top. None of that changes what macOS delivers, shows, or sounds. Backglance has no way to intercept system delivery, and it does not try to.

To actually silence an app: System Settings ▸ Notifications ▸ pick the app ▸ turn off "Allow notifications" or change the alert style. Backglance's per-app view has a "Manage in System Settings" button that opens the right pane using `x-apple.systempreferences:com.apple.Notifications-Settings.extension`. See [Rules](../features/RULES.md).

### What is the digest, and why didn't I get one?

The digest is the "What did I miss" view. When an away session ends (you unlock, wake, leave a Focus, stop presenting), Backglance shows one banner grouping the notifications delivered during that session, VIP apps first, plus anything the system store marked as not presented. It is shown once, it is dismissible, and it never nags.

You will not see one if the away session was shorter than 5 minutes, had zero notifications, or you set "Show digest" to "never" or to a higher threshold. Focus and presenting detection are heuristics (⚠️ they read undocumented Focus files and match frontmost apps against a known-presenter list), so a Focus session might occasionally not be detected; lock/unlock and sleep/wake are reliable. See [Missed Digest](../features/MISSED_DIGEST.md).

### Does it work with iPhone Mirroring / iOS app notifications?

> ⚠️ **Warning:** Uncertain, best-effort.

Notifications forwarded from iPhone Mirroring appear in Notification Center, and in developer testing they do land in the same system store with the mirrored app's identifier. Backglance archives whatever the store contains, so those items generally show up. What is not guaranteed: the bundle identifier and icon of the iOS app may not resolve to anything installed on the Mac (so you may see a generic icon and the raw identifier), deep links usually do not work, and Apple could route mirrored notifications differently in any release. If you rely on this, treat it as a bonus rather than a feature.

### Can I search inside images or attachments?

Not in v1.0. Backglance stores only attachment **metadata** (type, name, size), never the bytes, so there is nothing to OCR. OCR of image attachments into search is a v2.0 roadmap item and would reuse the Vision-based `OCRManager` pattern from PasteShelf. See [Roadmap](./ROADMAP.md).

### Can I sync between two Macs?

Not in v1.0. CloudKit sync via your own iCloud private database is planned for v1.x, opt-in, off by default. Until then, Export/Import (CSV/JSON) is the manual way to move data. See [CloudKit Sync](../features/CLOUDKIT_SYNC.md).

---

## Technical

### What happens when Apple changes the store format?

This is the known fragility of the whole category, so it is planned for rather than hoped against.

1. On every launch and after every OS update, Backglance computes a `StoreFingerprint` (SHA-256 of the store's `sqlite_master` SQL plus the `dbinfo` table plus the OS version).
2. `StoreAdapterRegistry.resolve(fingerprint:)` looks for an adapter that matches exactly (`StoreAdapterV14`, `V15`, `V26`). If none matches, it tries the adapter for the same OS major version and runs `probe()`. If the probe reports missing tables or an unknown schema, capture enters **degraded mode**.
3. In degraded mode: your existing archive is intact and fully searchable; capture is paused; the menu bar icon shows the state; a banner explains it and links to the tracking issue.
4. The developer (or anyone) writes or updates an adapter, adds a synthetic fixture for the new schema, CI verifies it, and a hotfix ships through Sparkle. Because adapters are small and the fixtures make them testable without a Mac on that OS version, the target is days, not weeks.

The full procedure, including how to generate a fixture on a beta and how to submit one, is in the [OS Compatibility Playbook](../architecture/OS_COMPATIBILITY_PLAYBOOK.md).

### Does it slow down my Mac or drain the battery?

It should not, and it is measured. Budgets: idle CPU under 0.1 % on average, under 60 MB memory when idle, under 150 MB with the timeline window open at 100,000 notifications. Capture is event-driven (a `DispatchSource` on the store's WAL file) with a fallback poll every 15 seconds, stretched to 60 seconds in Low Power Mode. Semantic search indexing, if you turn it on, runs in background batches and is the only thing that uses noticeable CPU, and only while it catches up. See [Performance Guide](../deployment/PERFORMANCE_GUIDE.md).

If you see something worse, that is a bug; please report it with an `Activity Monitor` sample.

### Does it run on an Intel Mac?

Yes, best-effort, on macOS 14, 15 and 26. The official binary is Universal 2. Apple silicon is the primary development and test target; Intel gets CI builds and fixture tests but less hands-on testing. macOS 27 is Apple-silicon-only, so Intel support ends with macOS 26 for the OS reasons alone. See the compatibility table in [README](../../README.md).

### Does it run on the macOS 27 beta?

Best-effort during the beta. The fingerprint check runs first: if macOS 27's store matches the macOS 26 layout, `StoreAdapterV26` is used as a fallback after a successful probe; if not, you get degraded mode (archive intact, capture paused) until an adapter lands. The macOS 27 adapter is finalized at GM. Beta users are the most useful fixture contributors; see the [OS Compatibility Playbook](../architecture/OS_COMPATIBILITY_PLAYBOOK.md).

### Can I build it myself?

Yes, and it is a supported path, not a fallback.

```bash
git clone https://github.com/backglance/backglance.git
cd backglance
./Scripts/bootstrap.sh          # checks Xcode 16.2+, resolves SPM packages
./Scripts/build.sh              # Release build to ./build/Backglance.app
```

You need Xcode 16.2 or later (Xcode 26.x recommended). A self-built app is ad-hoc signed unless you set your own signing identity; macOS will still let you grant it FDA. Sparkle updates are disabled for unsigned builds because the appcast signature would not verify. See the [Development Guide](../getting-started/DEVELOPMENT_GUIDE.md).

### How do I verify the binary is the official one?

Three checks, any of which is sufficient:

```bash
# 1. Signature: must be Developer ID, Team ID TEAMID1234, and notarized
codesign -dv --verbose=4 /Applications/Backglance.app 2>&1 | grep -E 'Authority|TeamIdentifier'
spctl --assess --type execute --verbose /Applications/Backglance.app
# expected: accepted, source=Notarized Developer ID

# 2. Checksum: compare with the SHA-256 published in the GitHub Release notes
shasum -a 256 ~/Downloads/Backglance-1.0.0.dmg

# 3. Homebrew: the cask pins the same SHA-256
brew info --cask backglance/tap/backglance
```

The identity is `"Developer ID Application: Backglance (TEAMID1234)"`. Sparkle updates are additionally signed with an EdDSA key whose public half is embedded in the app (`SUPublicEDKey`), so an update that was not signed by the developer's private key is rejected before it is installed. See [Packaging & Notarization](../deployment/PACKAGING_NOTARIZATION.md).

### How do updates work?

Sparkle 2.7 checks the appcast on your schedule (default: daily, can be off), shows release notes, and installs on your confirmation. Updates are EdDSA-signed and the downloaded app is notarized. Homebrew users can also update with `brew upgrade --cask backglance`; both paths deliver the same binary. See [Deployment Guide](../deployment/DEPLOYMENT_GUIDE.md).

---

## Project

### Why GPL and not MIT?

Because the point of Backglance is that it stays open and stays free, including any derived version. GPL-3.0 guarantees that if someone ships a modified Backglance, users of that version get the source too. MIT would allow a closed fork of a privacy tool that reads a sensitive database, which is exactly the outcome the license is meant to prevent. For a small utility with no commercial angle, copyleft costs nothing and protects the one thing that matters. See [Legal & Compliance](../security/LEGAL_COMPLIANCE.md).

### How do I report a bug or a security issue?

- Bugs: GitHub Issues at `https://github.com/backglance/backglance/issues`. Please include macOS version, Backglance version, and the relevant lines from `~/Library/Logs/Backglance/backglance.log` (it never contains notification content). See [Troubleshooting](../operations/TROUBLESHOOTING.md) first.
- Security: do not open a public issue. Follow the private disclosure process in [Security](../security/SECURITY.md).

### Can I contribute?

Yes. Adapters and fixtures for new macOS builds are the most valuable contribution; translations (EN/TR/DE first, via PRs on the String Catalog) come next; then everything else. Read [Contributing](../contributing/CONTRIBUTING.md), and see [Internationalization](./INTERNATIONALIZATION.md) and [Accessibility](./ACCESSIBILITY.md) for the two areas that have their own checklists.

## Related Documentation

- [README](../../README.md)
- [Quick Start](../getting-started/QUICK_START.md)
- [Permissions & Privacy](../features/PERMISSIONS_PRIVACY.md)
- [Privacy Controls](../features/PRIVACY_CONTROLS.md)
- [Capture](../features/CAPTURE.md)
- [Missed Digest](../features/MISSED_DIGEST.md)
- [Rules](../features/RULES.md)
- [OS Compatibility Playbook](../architecture/OS_COMPATIBILITY_PLAYBOOK.md)
- [Security](../security/SECURITY.md)
- [Roadmap](./ROADMAP.md)
- [Cost Estimation](./COST_ESTIMATION.md)
- [Internationalization](./INTERNATIONALIZATION.md)
- [Accessibility](./ACCESSIBILITY.md)
- [Troubleshooting](../operations/TROUBLESHOOTING.md)
