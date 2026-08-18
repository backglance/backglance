# Security

Last Updated: 2026-08-18

Backglance keeps a local archive of every notification macOS delivers to you — which means it keeps private messages, calendar details, mail subjects, and (unless redacted) one-time codes. That is highly sensitive data, and the security story has to be honest about what a menu bar utility running as your user can and cannot protect. This document is the threat model, the mitigations Backglance ships, the residual risks it does not remove, the secure-coding rules for contributors, and the responsible-disclosure policy. The root `SECURITY.md` is a symlink to this file so GitHub surfaces it in the repository's Security tab.

> 🔒 **Security:** Short version — Backglance is local-only, has zero telemetry, makes exactly one kind of network request (the Sparkle updater, which you can turn off), reads exactly two system paths, and stores its archive in a `0700` directory as `0600` files. It cannot protect the archive from malware running as your user; nothing on macOS outside the App Sandbox can. FileVault, short retention, OTP redaction, exclusions, and (v1.x) SQLCipher are the levers you have.

## Table of Contents

- [Security posture in one table](#security-posture-in-one-table)
- [What Backglance touches](#what-backglance-touches)
- [Threat model](#threat-model)
- [Threats in detail](#threats-in-detail)
  - [Device theft](#device-theft)
  - [Shared Macs and other local users](#shared-macs-and-other-local-users)
  - [Malware or another app reading the archive](#malware-or-another-app-reading-the-archive)
  - [A malicious or compromised Backglance build](#a-malicious-or-compromised-backglance-build)
  - [Supply chain](#supply-chain)
  - [The updater](#the-updater)
  - [CloudKit sync (v1.x)](#cloudkit-sync-v1x)
  - [Full Disk Access scope creep](#full-disk-access-scope-creep)
  - [Focus and away detection](#focus-and-away-detection)
  - [Logs and diagnostics](#logs-and-diagnostics)
  - [Exports](#exports)
  - [Clipboard](#clipboard)
  - [Process memory](#process-memory)
  - [Backups](#backups)
  - [Spotlight](#spotlight)
- [Why OTP redaction is on by default](#why-otp-redaction-is-on-by-default)
- [At-rest encryption options](#at-rest-encryption-options)
- [Why local-only is the default posture](#why-local-only-is-the-default-posture)
- [Secure coding practices](#secure-coding-practices)
  - [Parameterized SQL only](#parameterized-sql-only)
  - [Hostile store content: the plist guard](#hostile-store-content-the-plist-guard)
  - [Regex rules and pathological patterns](#regex-rules-and-pathological-patterns)
  - [Concealed pasteboard copies](#concealed-pasteboard-copies)
  - [Hardened runtime and entitlements](#hardened-runtime-and-entitlements)
- [Verifying an official build](#verifying-an-official-build)
- [Responsible disclosure policy](#responsible-disclosure-policy)
- [Supported versions](#supported-versions)
- [Release security checklist](#release-security-checklist)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Security posture in one table

| Property | v1.0 | v1.x |
|---|---|---|
| Network access | Sparkle updater only; user can disable → zero network | + opt-in CloudKit sync (off by default) |
| Telemetry / crash reporting / analytics services | None | None |
| Accounts | None | iCloud account used only if sync is enabled |
| Archive location | `~/Library/Application Support/Backglance/archive.sqlite` | Same |
| Archive permissions | Directory `0700`, files `0600` | Same |
| At-rest encryption | FileVault (OS) + permissions | + optional SQLCipher, key in Keychain |
| System paths read | Notification Center store, `~/Library/DoNotDisturb/DB/` | Same |
| TCC permissions requested | Full Disk Access (required), Notifications (optional, for local reminders) | + none new |
| Accessibility / Screen Recording / Input Monitoring | Never | Never |
| Sandbox | No (FDA is incompatible with App Sandbox; not on the Mac App Store) | No |
| Hardened runtime | Yes, no exceptions | Yes |
| Code signing | Developer ID + notarized + stapled | Same |
| Update integrity | Sparkle 2 EdDSA + HTTPS + Apple signature check | Same |
| Source | Fully open, GPL-3.0, single repo | Same |

## What Backglance touches

The whole point of a threat model for a tool like this is to be able to say exactly what the process reads and writes. This is the complete list.

```
Reads (system, requires FDA)
  ~/Library/Group Containers/group.com.apple.usernoted/db2/db      ⚠️ undocumented system store
  ~/Library/Group Containers/group.com.apple.usernoted/db2/db-wal
  ~/Library/Group Containers/group.com.apple.usernoted/db2/db-shm
  ~/Library/DoNotDisturb/DB/Assertions.json                       ⚠️ Focus detection (optional)
  ~/Library/DoNotDisturb/DB/ModeConfigurations.json               ⚠️ Focus detection (optional)

Reads (public API, no special permission)
  App bundles for icons via NSWorkspace          (urlForApplication(withBundleIdentifier:))
  NSWorkspace frontmost app                       (presenting heuristic)

Writes (own directory, 0700)
  ~/Library/Application Support/Backglance/archive.sqlite  (+ -wal, -shm)   0600
  ~/Library/Application Support/Backglance/icons/                          icon cache
  ~/Library/Application Support/Backglance/tmp/                            store snapshots, deleted after each read
  ~/Library/Application Support/Backglance/.metadata_never_index           Spotlight marker
  ~/Library/Logs/Backglance/backglance.log                                 no content, 5 × 2 MB
  ~/Library/Preferences/app.backglance.Backglance.plist                    settings
  Keychain (v1.x): archive key, kSecAttrAccessibleWhenUnlockedThisDeviceOnly

Network
  GET https://backglance.github.io/backglance/appcast.xml   (Sparkle, disable-able)
  GET <release asset URL from appcast>                       (Sparkle, only when installing an update)
  CloudKit (v1.x, opt-in)                                    Apple's servers, user's own iCloud account
```

> ⚠️ **Warning:** The system store path and its layout are what we have observed, not an API. Column names may change in any macOS release; the fingerprint + adapter + fixture strategy exists for that reason. See [`../architecture/OS_COMPATIBILITY_PLAYBOOK.md`](../architecture/OS_COMPATIBILITY_PLAYBOOK.md).

## Threat model

Likelihood and impact are relative judgements for a typical single-user Mac. "Residual risk" is what remains after everything Backglance does; it is deliberately not rounded down.

| Asset | Threat | Likelihood | Impact | Mitigation | Residual risk |
|---|---|---|---|---|---|
| Archive on disk | Device theft, disk removed or booted elsewhere | Low | High | FileVault (recommended in onboarding); v1.x SQLCipher with Keychain-held key; retention limits (default 30 days); panic wipe | Without FileVault the archive is plaintext SQLite. With FileVault but an unlocked session, see next row |
| Archive on disk | Thief or bystander with the user's unlocked session | Low–Medium | High | Screen lock timeout (OS); v1.x Touch ID lock on the timeline window; panic wipe hotkey; short retention | Anyone with the unlocked session can read the archive, same as Messages itself |
| Archive on disk | Other local user accounts on a shared Mac | Medium on shared machines | High | Per-user home directory; `0700` directory, `0600` files; no shared location; no App Group container for the archive | An admin user can `sudo`; that is macOS's model, not ours to fix |
| Archive on disk | Malware or another app running as the user | Medium (any unsandboxed app) | High | SQLCipher option (v1.x); short retention; exclusion list; OTP redaction; no secondary copies except user exports | Any process running as the user without a sandbox can read `archive.sqlite`, exactly as it can read Messages' own `chat.db`. TCC does not protect `~/Library/Application Support`. Honest answer: not mitigable at the app layer |
| Archive contents | 2FA codes archived and later exfiltrated | Medium | High (account takeover) | OTP redaction ON by default for Messages and Mail; user-added apps; original digits never written; per-app opt-out shows a warning | Codes from apps the user has not added to redaction; codes in unusual formats or languages the patterns miss |
| Archive contents | Password manager / banking notifications archived | Medium | High | Default exclusion list (password managers, `com.apple.Passwords`, Backglance itself); user-added exclusions; `is_excluded` apps are never inserted | Only as good as the list; new password managers must be added |
| Users' trust | Malicious or compromised Backglance build distributed | Low | Critical | Open source; official binary Developer ID signed + notarized; verify Team ID with `codesign`; Sparkle updates signed with EdDSA and must also pass Apple signature check; Homebrew cask pins SHA-256 | A user who downloads from a non-official mirror and skips verification |
| Build pipeline | Compromised dependency (supply chain) | Low | Critical | Only two dependencies (GRDB, Sparkle) pinned by `Package.resolved`; Dependabot; manual review of every dependency bump diff; SQLCipher (v1.x) via GRDB's SQLCipher build only | Upstream compromise that survives review; GitHub Actions runner compromise |
| Update channel | MITM, rogue appcast, downgrade | Low | Critical | Sparkle 2: HTTPS appcast, EdDSA signature over the update, Apple code signature must match, no downgrades; user can disable updates entirely | GitHub Pages hosting compromise could serve a wrong appcast; the EdDSA signature still fails without our private key |
| Synced archive (v1.x) | iCloud account compromise | Low | High | Content fields in CloudKit `encryptedValues` (end-to-end, keys in iCloud Keychain); sync off by default; per-app sync exclusions | Attacker with the account **and** a trusted device gets content; attacker with the account only gets metadata (see detail) |
| System | FDA used for more than notifications ("scope creep") | — (it is us) | High | Exactly two read paths; code is auditable; no Accessibility, Screen Recording, Input Monitoring or network beyond the updater | The FDA grant technically permits more; only the code and its review prevent it |
| Focus state | Reading `~/Library/DoNotDisturb` reveals Focus schedule | Low | Low | Read only, only when Focus detection is on; only mode name and on/off are used, nothing stored except `away_sessions.reason = 'focus'` | Mode names may hint at habits ("Sleep", "Work") — stored only as reason category |
| Logs | Notification content leaks into logs | Low | Medium | `os.Logger` interpolations default to `.private`; content is never interpolated; file log carries counts, IDs, error kinds only; review rule in CI (grep for `title`/`body` in log calls) | A contributor bypasses the rule and it slips through review |
| Exports | User-initiated CSV/JSON is plaintext | Medium (user action) | High | Warning sheet before export; files written `0600`; redacted items stay redacted; default target `~/Downloads` is TCC-protected against other apps | The user shares or syncs the file; we cannot follow it |
| Clipboard | Copy action puts content on the pasteboard | Medium (user action) | Medium | Every copy sets `org.nspasteboard.ConcealedType`; clipboard managers that honor the convention skip it | Managers that ignore the marker; the pasteboard is readable by any app until replaced |
| Process memory | Recent notifications live in RAM | Low | Medium | No content in crash logs (no crash reporter); macOS encrypted swap; hardened runtime blocks unsigned debuggers | Root or a same-user process with `task_for_pid` and the right entitlements can read memory; kernel-level attackers can read anything |
| Backups | Time Machine copies the archive | Medium | High | Recommend encrypted Time Machine; Settings ▸ Privacy ▸ "Exclude archive from Time Machine" (`CSBackupSetItemExcluded`) | Unencrypted backups made before the toggle; other backup tools |
| Search index | Spotlight indexes the archive | Low | Low | `.metadata_never_index` marker in the archive directory; SQLite content isn't indexed by Spotlight anyway | Marker is advisory on internal volumes; belt-and-braces only |
| Deleted data | "Deleted" rows recoverable from disk | Low | Medium | Soft delete then hard prune by retention job; panic wipe uses `PRAGMA secure_delete = ON` and removes WAL/SHM/tmp/icons/embeddings | On APFS/SSD, overwrite is not a physical erasure guarantee; FileVault is the real answer |

## Threats in detail

### Device theft

If someone takes the Mac, the question is whether the disk is encrypted and whether the session is unlocked.

- **FileVault** is the primary control. Onboarding checks `fdesetup status` equivalent (via `FileVault` state in `NSFileManager`-adjacent APIs is not exposed; we shell out to `/usr/bin/fdesetup status` read-only) and shows a one-line recommendation if it is off. We do not nag after that.
- **Unlocked session.** With the session unlocked, the archive is readable by anyone at the keyboard — exactly as Messages, Mail, and Notification Center itself are. Backglance adds a v1.x **Touch ID lock** for the timeline window and the panic wipe hotkey; it cannot add more than the OS gives.
- **At-rest encryption (v1.x).** SQLCipher with a key stored in the Keychain as `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` means the archive is unreadable when the device is locked or the disk is imaged, independent of FileVault. See [At-rest encryption options](#at-rest-encryption-options).
- **Retention limits** cap what a thief gets. Default 30 days; per-app `24h`/`7d`/`never`.
- **Panic wipe** (Settings ▸ Privacy ▸ "Wipe archive…", optional global hotkey) closes the pool, turns on `secure_delete`, deletes archive + WAL + SHM + icons cache + tmp snapshots + embeddings, and recreates an empty archive. Typed confirmation "wipe" and Touch ID via `LAContext` when available.

### Shared Macs and other local users

The archive lives in the user's own home directory. The directory is created `0700` and every file `0600`; there is no shared location, no `/Users/Shared`, no App Group container for the archive (App Groups exist so multiple *processes* can share; we have one process). Another standard user cannot read it. An administrator can, with `sudo` — that is macOS's permission model and we do not pretend otherwise.

The `tmp/` snapshot directory (copies of the system store made for reading) inherits `0700` and every snapshot is deleted at the end of the read, even on error paths (`defer`).

### Malware or another app reading the archive

> ⚠️ **Warning:** This is the honest, uncomfortable row of the table. Any process running as your user without an App Sandbox can open `~/Library/Application Support/Backglance/archive.sqlite` and read everything in it. That is the same status as Messages' own `chat.db`, Mail's `Envelope Index`, and Safari's history. TCC protects `~/Documents`, `~/Desktop`, `~/Downloads`, and a handful of system stores; it does **not** protect `~/Library/Application Support`.

Backglance cannot change this at the application layer. What it can do:

| Lever | Effect |
|---|---|
| SQLCipher (v1.x) | The file is ciphertext; an attacker also needs the key from the Keychain, which requires the user's session to be unlocked and — for the ACL we use — the calling app to be Backglance or the user to approve access |
| Short retention | Less to steal |
| Exclusion list | Password managers, `com.apple.Passwords`, Backglance itself, plus user-added apps (banking) are never written |
| OTP redaction | A stolen archive does not contain a credential store of one-time codes |
| No secondary copies | Icons cache holds icons; tmp snapshots are deleted; embeddings are float vectors, not text; only user exports create plaintext copies |

### A malicious or compromised Backglance build

The mitigations for "what if the binary you downloaded isn't what's in the repo" are:

1. **Open source, single repo.** Every release is a tag; anyone can build the same tag with `Scripts/build.sh` and compare behaviour. We do not claim bit-for-bit reproducible builds (Xcode toolchains and signing make that unrealistic).
2. **Developer ID + notarization.** The official DMG is signed with `"Developer ID Application: Backglance (TEAMID1234)"` and notarized by Apple. Gatekeeper refuses tampered copies.
3. **Verify it yourself.** See [Verifying an official build](#verifying-an-official-build). Check the Team ID, not just "it's signed".
4. **Sparkle EdDSA.** Updates are signed with our EdDSA key; the public key is baked into `Info.plist` (`SUPublicEDKey`). Sparkle additionally verifies the Apple code signature of the downloaded update matches the running app's, so a compromised private key alone is not enough to ship an update.
5. **Homebrew cask** pins the SHA-256 of the DMG in `backglance/homebrew-tap`; `cask-bump.yml` writes it from the release artifact.

### Supply chain

- Two dependencies in v1.0: **GRDB.swift 7.x** and **Sparkle 2.7.x**, both via SPM, both pinned by a committed `Package.resolved`. v1.x adds the GRDB SQLCipher build (`GRDB.swift/SQLCipher`) when at-rest encryption ships.
- **Dependabot** (`package-ecosystem: swift`) opens bump PRs; every bump PR is reviewed by reading the upstream diff, not just the version number.
- CI (`ci.yml`) builds from a clean checkout on `macos-14`, `macos-15`, `macos-26`; release builds come from `release.yml` on a tagged commit and the DMG SHA-256 is published in the GitHub Release body.
- No binary frameworks, no CocoaPods, no downloaded scripts in the build phases. `Scripts/bootstrap.sh` installs nothing from the network except Xcode command line tools prompts.

### The updater

Sparkle is the only network client in v1.0.

| Control | Setting |
|---|---|
| Appcast | `https://backglance.github.io/backglance/appcast.xml` over HTTPS (later `https://backglance.app/appcast.xml`) |
| Signature | EdDSA (Ed25519) over each enclosure; `SUPublicEDKey` in `Info.plist`; private key only in the `SPARKLE_PRIVATE_KEY` GitHub secret |
| Apple signature | Sparkle refuses updates whose Developer ID does not match the running app |
| Downgrades | Refused by Sparkle |
| System profiling | `SUEnableSystemProfiling = NO`; nothing beyond a normal HTTP request |
| Disable | Settings ▸ Updates ▸ "Check for updates automatically" off. With that off Backglance opens no sockets at all — this is a guarantee, and it is testable: `lsof -i -p $(pgrep -x Backglance)` prints nothing |

What the appcast host sees when updates are on: the request's IP address, a `User-Agent` of the form `Backglance/1.0.0 Sparkle/2.7.0`, and standard HTTP headers from which the OS version can be inferred. GitHub Pages may log requests; we do not receive or read such logs. This is stated in the privacy policy in [`./LEGAL_COMPLIANCE.md`](./LEGAL_COMPLIANCE.md).

### CloudKit sync (v1.x)

> ℹ️ **Status:** Planned for v1.x — not in v1.0. Off by default.

Sync uses the user's own iCloud account and the private CloudKit database; nothing goes through a server we operate. Every content **and metadata** field — `title`, `subtitle`, `body`, `sender`, `thread_id`, `deep_link`, `bundle_id`, `app_name`, and the `is_read` / `is_pinned` / `is_deleted` flags — is written through `CKRecord.encryptedValues`, which CloudKit encrypts end-to-end with keys held in the user's iCloud Keychain. Only three things stay in clear: the record name (the notification `uuid`, an opaque identifier), `delivered_at`, and `modified_at`. Those two timestamps are in clear because the conflict policy and the "sync only after the opt-in date" rule need to order records without decrypting them.

> ℹ️ **Info:** Encrypting `bundle_id` costs a little — the sync engine cannot filter server-side by app — but it means a plain-field leak does not reveal which apps notify you. [`../features/CLOUDKIT_SYNC.md`](../features/CLOUDKIT_SYNC.md#end-to-end-encryption) carries the field-by-field table.

What an attacker gets:

| Attacker has | Gets |
|---|---|
| iCloud credentials only (no trusted device, no device passcode) | Only the shape of the traffic: how many notifications exist and when each arrived. Not the content, not the sender, not even which apps notified you |
| iCloud credentials + a trusted device or the device passcode (iCloud Keychain recovery) | Everything, same as your Mac |
| A subpoena to Apple | Record counts and timestamps; Apple states it cannot decrypt `encryptedValues` |

Redacted notifications stay redacted in sync because the originals never existed. Excluded apps are never synced because they were never archived. Details and the per-app sync switch live in [`../features/CLOUDKIT_SYNC.md`](../features/CLOUDKIT_SYNC.md).

### Full Disk Access scope creep

FDA is a blunt permission: once granted, a process can read almost anything in the home directory. Users are right to ask what we do with it. The answer is checkable in `Packages/BackglanceCapture/`:

- `StoreLocation.current()` returns exactly one path (`…/group.com.apple.usernoted/db2/db`) and the reader opens that plus its `-wal`/`-shm` siblings, copied to `tmp/` and opened read-only with `?immutable=1`.
- `AwaySessionTracker` reads two JSON files under `~/Library/DoNotDisturb/DB/` when Focus detection is enabled.
- There is no other file read outside our own directory. There is no Accessibility, Screen Recording, Input Monitoring, Contacts, Calendar, or Location request. Attachments are recorded as metadata (`attachments_json`: type, name, size), never bytes.
- A CI job (`fixtures.yml`) runs the capture package against synthetic fixtures under a `TMPDIR`-scoped home and asserts that no path outside the fixture root and the archive root is opened (`fs_usage`-style hook via `DYLD_INSERT_LIBRARIES` is not used; we use an `FSEvents`-free approach: `StoreLocation` is injectable, and tests pass a sandboxed root).

### Focus and away detection

Focus detection reads `Assertions.json` and `ModeConfigurations.json` under `~/Library/DoNotDisturb/DB/` (⚠️ undocumented; format observed, not an API). Only "is a Focus active" and the mode's identifier are used, to open or close an away session with `reason = 'focus'`. The mode name is not persisted. If you would rather Backglance not read that directory, turn off Settings ▸ Digest ▸ "Detect Focus"; the digest then relies on lock/sleep events and the store's own `presented == false` flag.

### Logs and diagnostics

- `os.Logger(subsystem: "app.backglance.Backglance", category: ...)` — string interpolations are `.private` by default; we never interpolate `title`, `subtitle`, `body`, `sender`, or `userInfo`. IDs, counts, durations, and error kinds are `.public`.
- The rotating file log at `~/Library/Logs/Backglance/backglance.log` (max 5 × 2 MB) uses the same rule. Settings ▸ Advanced ▸ "Reveal log" opens it so users can check for themselves.
- There is no crash reporter, no analytics SDK, no diagnostics upload. If you send us a log for a bug report, you are choosing to; it will contain no notification content.
- CI has a lint step: `grep -rnE 'logger\.[a-z]+\(.*(\.title|\.body|\.subtitle|\.sender)' Packages/ Backglance/` must return nothing.

See [`../operations/MONITORING_LOGGING.md`](../operations/MONITORING_LOGGING.md).

### Exports

Exports (CSV, JSON; date range; selection) are user-initiated plaintext files. Before writing, Backglance shows a sheet: "This file will contain notification text in plain form. Anyone who can read the file can read the notifications." Files are created `0600`. Redacted OTPs export as `[code redacted]` because the digits do not exist anywhere. `backglance://export?…` (v1.x) asks the same confirmation and writes to `~/Downloads`.

### Clipboard

The copy action places text on `NSPasteboard.general`. Anything on the general pasteboard is readable by any app until it is replaced, and clipboard managers keep history. Backglance marks every copy it makes with `org.nspasteboard.ConcealedType` (the nspasteboard.org convention) so managers that honor it — PasteShelf's clipboard monitor is one such implementation — skip the item. Managers that ignore the marker will still see it. Code in [Concealed pasteboard copies](#concealed-pasteboard-copies).

### Process memory

Recent notifications, the current search results, and the digest are in the process's memory in plain form. Backglance does not `mlock` or zero buffers; Swift strings do not offer that control and the benefit would be marginal. macOS encrypts swap by default. Release builds have the hardened runtime and no `get-task-allow`, so an unsigned debugger cannot attach. Root, or the kernel, can read anything — outside our threat model.

### Backups

Time Machine copies `~/Library/Application Support/Backglance/` like any other user data. Two things follow:

1. Turn on **encrypted** Time Machine backups. Onboarding mentions it once.
2. Settings ▸ Privacy ▸ "Exclude archive from Time Machine" calls `CSBackupSetItemExcluded` on the archive directory. Default is off (the archive is backed up) so users do not silently lose their history with a disk; the toggle is one click. Excluding after the fact does not remove copies already in old snapshots.

Third-party backup tools (Backblaze, Arq, rsync scripts) will copy the archive unless configured not to.

### Spotlight

The archive directory contains an empty `.metadata_never_index` file. Spotlight does not extract text from SQLite files anyway, so this is belt-and-braces; on modern macOS the marker is advisory for internal volumes. Nothing in the archive is exposed to Spotlight search or Siri suggestions, and Backglance does not donate `NSUserActivity` or Core Spotlight items.

## Why OTP redaction is on by default

A searchable archive of every SMS and email you received is, among other things, a **credential store**: it would contain every 2FA code, login link, and password-reset PIN of the last 30 days. Even though most codes expire in minutes, an archive of them tells an attacker which services you use, when you log in, and occasionally still-valid codes and reset links. Backglance refuses to persist them by default.

- `OTPRedactor.default` is applied to `com.apple.MobileSMS` and `com.apple.mail` (`apps.redact_otp = 1`) plus any app the user adds.
- Detection: 4–8 digit codes (optionally split by hyphen or space) within 40 characters of a keyword (EN: code, verification, passcode, OTP, one-time, PIN, login; TR: kod, doğrulama, şifre; DE: Code, Bestätigungscode, Einmalpasswort), or a whole-body short message that is only a code.
- The match is replaced with `[code redacted]` **in memory, before insert**. The original digits are never written to the archive, the FTS index, the embeddings, the logs, or the digest. A `RedactionEvent` (`kind = 'otp'`, `pattern_id`, timestamp) is recorded — never the original.
- Turning redaction off for an app shows a warning: "Backglance will keep one-time codes from this app in the archive. Anyone who can read the archive can read them."
- False positives (an order number redacted) are the accepted cost; the timeline shows a small "redacted" badge and the deep link still opens the original in Messages or Mail.

See [`../features/PRIVACY_CONTROLS.md`](../features/PRIVACY_CONTROLS.md).

## At-rest encryption options

| | v1.0 | v1.x (opt-in) |
|---|---|---|
| Mechanism | FileVault (whole-disk) + `0700`/`0600` + own directory | SQLCipher via `GRDB.swift/SQLCipher`, AES-256-CBC pages, key in Keychain |
| Key | Your login password (FileVault) | 32 random bytes from `SecRandomCopyBytes`, stored as `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| Locked device / imaged disk | Protected by FileVault only | Protected even without FileVault |
| Unlocked session, same user | Readable | Readable by Backglance; other apps must get the key from the Keychain (ACL prompts unless the item's access group matches) |
| Full-text search | Yes | Yes — FTS5 runs inside SQLCipher unchanged |
| Semantic search | Yes | Yes — embeddings table is inside the same encrypted file |
| Performance | Baseline | Roughly 10 % slower on write-heavy paths; FTS p95 stays under budget in our measurements |
| Key loss | n/a | **Key loss = archive loss.** The key is `ThisDeviceOnly` and not in iCloud Keychain; a wiped Keychain or a migration to a new Mac without the key leaves an unreadable file. Export before migrating |
| Touch ID lock | v1.x, independent of encryption | Combines: opening the timeline requires `LAContext` and the key read happens after |
| Migration | — | Settings ▸ Privacy ▸ "Encrypt archive…" runs `sqlcipher_export()` into a new file, verifies row counts, then replaces and secure-deletes the plaintext one |

Why not encrypt in v1.0? Because encryption that shares a session with the reader mostly protects against the disk-image case that FileVault already covers, and shipping key management wrong (lost keys, Keychain prompts, migration bugs) is worse than shipping later. v1.0 is honest about relying on FileVault; v1.x adds SQLCipher for people who want defense in depth.

## Why local-only is the default posture

- The data is yours and never needed to leave the machine to be useful; every feature (timeline, digest, search, rules, analytics) runs on-device.
- No server means no server breach, no account database, no subpoena target we control, and nothing to shut down.
- Zero telemetry means the developer never receives notification content, app lists, or usage counts. It also means bug reports must come from users — the file log exists for that.
- Sync (v1.x) is opt-in, uses the user's own iCloud, and encrypts content end-to-end. Even then, we do not operate anything.
- Free and GPL-3.0 removes the incentive to change this later. See [`./LEGAL_COMPLIANCE.md`](./LEGAL_COMPLIANCE.md).

## Secure coding practices

These rules apply to every contribution. See [`../contributing/CONTRIBUTING.md`](../contributing/CONTRIBUTING.md) for the review checklist.

### Parameterized SQL only

Never interpolate values into SQL strings. GRDB makes the safe path the short path.

```swift
import GRDB

extension Archive {
    /// Marks notifications from one app as read. `bundleID` comes from UI state
    /// and is passed as an argument, never spliced into the SQL text.
    func markRead(bundleID: String, since: Date) throws -> Int {
        try pool.write { db in
            try db.execute(
                sql: """
                UPDATE notifications
                   SET is_read = 1
                 WHERE app_id = (SELECT id FROM apps WHERE bundle_id = ?)
                   AND delivered_at >= ?
                   AND is_read = 0
                """,
                arguments: [bundleID, since.timeIntervalSince1970]
            )
            return db.changesCount
        }
    }

    /// Full-text search: user input is turned into an FTS5 pattern by GRDB,
    /// which escapes it. A query that produces no valid tokens returns nil,
    /// so we return an empty result instead of running `MATCH ''`.
    func searchIDs(_ userQuery: String, limit: Int = 200) throws -> [Int64] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: userQuery) else {
            return []
        }
        return try pool.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                SELECT rowid FROM notifications_fts
                 WHERE notifications_fts MATCH ?
                 ORDER BY bm25(notifications_fts)
                 LIMIT ?
                """,
                arguments: [pattern, limit]
            )
        }
    }
}
```

> ❌ **Don't:** `try db.execute(sql: "DELETE FROM notifications WHERE uuid = '\(uuid)'")`. Review rejects any `sql:` string containing `\(`.

The `QueryParser` (`from:slack before:2026-08-01 invoice`) produces a struct of typed filters plus a free-text remainder; only the remainder reaches `FTS5Pattern`, and filters become bound arguments.

### Hostile store content: the plist guard

⚠️ Every `record.data` blob in the system store was produced from a payload that some other app posted. A malicious or buggy app can post a notification with an enormous `userInfo`, deeply nested arrays, or unusual object types. Backglance treats the blob as hostile input.

Rules:

- Size cap **64 KB per record**; larger blobs are skipped and counted, not parsed.
- Depth cap 8, collection cap 512 entries, string cap 16 K characters.
- `PropertyListSerialization` with immutable containers only. **Never** `NSKeyedUnarchiver` with `requiresSecureCoding = false`; we do not unarchive `NSKeyedArchiver` payloads inside `userInfo` at all — they are recorded as opaque and dropped.
- Failures are logged by shape (`tooLarge(bytes:)`, `tooDeep(depth:)`), never by content.

```swift
import Foundation
import os

/// Limits applied to every record read from the system store before decoding.
public struct PlistGuardLimits: Sendable {
    public var maxBytes: Int = 64 * 1024        // 64 KB per record
    public var maxDepth: Int = 8                // nesting of dict/array
    public var maxCollectionCount: Int = 512    // entries per dict/array
    public var maxStringLength: Int = 16 * 1024 // characters per string
    public init() {}
}

public enum PlistGuardError: Error, Equatable {
    case tooLarge(bytes: Int)
    case notADictionary
    case tooDeep(depth: Int)
    case collectionTooLarge(count: Int)
    case stringTooLong(length: Int)
    case unsupportedType(String)
}

public struct PlistGuard: Sendable {
    public let limits: PlistGuardLimits

    public init(limits: PlistGuardLimits = PlistGuardLimits()) {
        self.limits = limits
    }

    /// Decodes a binary plist into a plain dictionary, rejecting anything
    /// that exceeds the limits. Only Foundation plist types survive.
    public func decode(_ data: Data) throws -> [String: Any] {
        guard data.count <= limits.maxBytes else {
            throw PlistGuardError.tooLarge(bytes: data.count)
        }
        var format = PropertyListSerialization.PropertyListFormat.binary
        let object = try PropertyListSerialization.propertyList(
            from: data,
            options: [],          // immutable containers, no mutable leaves
            format: &format
        )
        guard let dict = object as? [String: Any] else {
            throw PlistGuardError.notADictionary
        }
        try validate(dict, depth: 1)
        return dict
    }

    private func validate(_ value: Any, depth: Int) throws {
        guard depth <= limits.maxDepth else {
            throw PlistGuardError.tooDeep(depth: depth)
        }
        switch value {
        case let dict as [String: Any]:
            guard dict.count <= limits.maxCollectionCount else {
                throw PlistGuardError.collectionTooLarge(count: dict.count)
            }
            for (key, inner) in dict {
                guard key.count <= limits.maxStringLength else {
                    throw PlistGuardError.stringTooLong(length: key.count)
                }
                try validate(inner, depth: depth + 1)
            }
        case let array as [Any]:
            guard array.count <= limits.maxCollectionCount else {
                throw PlistGuardError.collectionTooLarge(count: array.count)
            }
            for inner in array {
                try validate(inner, depth: depth + 1)
            }
        case let string as String:
            guard string.count <= limits.maxStringLength else {
                throw PlistGuardError.stringTooLong(length: string.count)
            }
        case is NSNumber, is Date, is Data:
            return                 // scalars are bounded by maxBytes already
        default:
            throw PlistGuardError.unsupportedType(String(describing: type(of: value)))
        }
    }
}

// Usage inside RecordParser: the guard runs first; a rejected record is
// skipped and counted, and the cursor still advances past it.
extension RecordParser {
    private static let logger = Logger(subsystem: "app.backglance.Backglance",
                                       category: "capture.parse")

    func guardedDictionary(for raw: RawStoreRecord) -> [String: Any]? {
        do {
            return try PlistGuard().decode(raw.plistData)
        } catch let error as PlistGuardError {
            // Shape of the failure only; never the payload.
            Self.logger.warning(
                "Rejected store record \(raw.recID, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return nil
        } catch {
            Self.logger.error(
                "Undecodable store record \(raw.recID, privacy: .public)"
            )
            return nil
        }
    }
}
```

The fixture set includes a `hostile/` case per macOS version: a 2 MB blob, a 40-level nested array, a 100 000-entry dictionary, and a `userInfo` containing an `NSKeyedArchiver` payload. `BackglanceCaptureTests` asserts all four are rejected with the expected error and that the following record is still imported.

### Regex rules and pathological patterns

Rules of kind `regex` compile user-supplied patterns with Swift `Regex`. Swift `Regex` has no timeout parameter, so Backglance bounds the *work* rather than the *time*:

- Pattern length ≤ 256 characters; input truncated to 4 096 characters per field.
- `firstMatch(in:)` only; never `matches(of:)` over the whole body.
- Evaluation runs on a background actor (`RulesEngine` is not on the main actor), so a slow pattern degrades triage latency, not the UI.
- Each evaluation is timed with `ContinuousClock`; a rule that exceeds 50 ms three times is disabled (`is_enabled = 0`) and the timeline shows "Rule disabled: too slow" with a fix-it link.

```swift
import Foundation

struct RegexRuleEvaluator {
    static let maxPatternLength = 256
    static let maxInputLength = 4_096
    static let budget: Duration = .milliseconds(50)

    let regex: Regex<AnyRegexOutput>

    /// Throws if the pattern is invalid or too long. Called once when the
    /// rule is saved, and again on load.
    init(pattern: String) throws {
        guard pattern.count <= Self.maxPatternLength else {
            throw RuleError.patternTooLong(pattern.count)
        }
        self.regex = try Regex(pattern).ignoresCase()
    }

    /// Returns (matched, elapsed) so the caller can count budget violations.
    func evaluate(_ input: String) -> (matched: Bool, elapsed: Duration) {
        let bounded = String(input.prefix(Self.maxInputLength))
        let clock = ContinuousClock()
        var matched = false
        let elapsed = clock.measure {
            matched = (try? regex.firstMatch(in: bounded)) != nil
        }
        return (matched, elapsed)
    }
}

enum RuleError: Error {
    case patternTooLong(Int)
}
```

### Concealed pasteboard copies

Every copy Backglance performs goes through one function so the concealed marker cannot be forgotten.

```swift
import AppKit

enum PasteboardCopier {
    /// nspasteboard.org convention: clipboard managers that honor this type
    /// do not record the item. The value is irrelevant; presence is the signal.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Copies notification text to the general pasteboard as concealed.
    /// Returns false if the pasteboard refused the write (rare; e.g. another
    /// process holds a promise), so the UI can show "Copy failed".
    @discardableResult
    static func copyConcealed(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealedType], owner: nil)
        let wroteText = pasteboard.setString(text, forType: .string)
        let wroteMarker = pasteboard.setString("", forType: concealedType)
        return wroteText && wroteMarker
    }
}
```

The "Copy" row action, the ⌘C shortcut in the timeline, and the digest's copy button all call `PasteboardCopier.copyConcealed(_:)`. `BackglanceUITests` asserts the marker type is present after a copy.

### Hardened runtime and entitlements

`Backglance.entitlements` contains no `com.apple.security.cs.*` exception. In particular:

| Entitlement | Value | Why |
|---|---|---|
| Hardened Runtime (build setting `ENABLE_HARDENED_RUNTIME`) | YES | Required for notarization; blocks unsigned code injection and debugger attach |
| `com.apple.security.cs.disable-library-validation` | **absent** | We load no third-party plug-ins; disabling library validation would let any signed dylib load into our FDA-holding process |
| `com.apple.security.cs.allow-unsigned-executable-memory` | absent | No JIT |
| `com.apple.security.cs.allow-dyld-environment-variables` | absent | No `DYLD_INSERT_LIBRARIES` |
| `com.apple.security.get-task-allow` | absent in Release | No debugger attach |
| `com.apple.security.app-sandbox` | absent | FDA is incompatible with the sandbox; this is why Backglance is not on the Mac App Store |
| CloudKit entitlements (v1.x) | added only when sync ships | `com.apple.developer.icloud-services = CloudKit`, container `iCloud.app.backglance.Backglance` |

CI fails if `codesign -d --entitlements :- Backglance.app` prints any `com.apple.security.cs.` key.

## Verifying an official build

```bash
#!/bin/bash
# Verify a downloaded Backglance.app. Every check must pass.
set -euo pipefail
APP="${1:-/Applications/Backglance.app}"

# 1. Signature is valid and chains to Developer ID; note the Team ID.
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E '^(Identifier|TeamIdentifier|Authority|flags)='
# Expected lines:
#   Identifier=app.backglance.Backglance
#   TeamIdentifier=TEAMID1234
#   Authority=Developer ID Application: Backglance (TEAMID1234)
#   Authority=Developer ID Certification Authority
#   Authority=Apple Root CA
#   flags=0x10000(runtime)          <- hardened runtime

# 2. Deep verification of every nested binary (Sparkle XPC services, frameworks).
codesign --verify --deep --strict --verbose=2 "$APP"

# 3. Gatekeeper accepts it (notarized).
spctl --assess --type exec --verbose=2 "$APP"
# Expected: "/Applications/Backglance.app: accepted" and "source=Notarized Developer ID"

# 4. Notarization ticket is stapled (works offline).
xcrun stapler validate "$APP"

# 5. No dangerous entitlements.
if codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q 'com.apple.security.cs.'; then
  echo "FAIL: hardened-runtime exception found" >&2
  exit 1
fi
echo "OK"
```

If the Team ID does not read `TEAMID1234` (the placeholder in these docs; the real value is printed in the README and in every GitHub Release), you do not have an official build. Building from source is fully supported — your own build will carry your signing identity or an ad-hoc signature, which is fine, and Sparkle will be disabled for unsigned builds by default.

## Responsible disclosure policy

Please do not open a public issue for a security bug.

| | |
|---|---|
| Primary channel | GitHub private vulnerability reporting: `https://github.com/backglance/backglance/security/advisories/new` |
| Email | `security@backglance.app` — once the domain is live (domain registration is an open pre-launch check; until then use GitHub) |
| Acknowledgement | Within **72 hours** |
| Fix target | **30 days** for confirmed issues; faster for anything that leaks archive content |
| Disclosure | Coordinated: we publish a GitHub Security Advisory and a CHANGELOG entry when the fix ships; you may publish after that or after 90 days from report, whichever comes first |
| Credit | Named in the advisory and CHANGELOG unless you prefer not to be |
| Bounty | None — this is a free, unpaid project. Sincere thanks and credit are what we have |
| Safe harbour | Good-faith research on your own installation is welcome. Do not access other people's archives |

**In scope:** anything in this repository — the app, packages, scripts, CI workflows, the appcast, the Homebrew cask. Especially: content leaking to logs, exports, pasteboard, or network; SQL injection; unsafe plist/keyed-archive decoding; update verification bypass; permission escalation via the URL scheme.

**Out of scope:** the macOS notification store's own permission model; malware running as the user reading the archive (documented above); issues that require root; Sparkle or GRDB bugs — report those upstream, but tell us too so we can bump.

## Supported versions

Only the latest minor release line receives security fixes.

| Version | Supported |
|---|---|
| Latest 1.x minor (e.g. 1.2.x when 1.2 is current) | ✅ Security fixes |
| Older 1.x minors | ❌ Update via Sparkle or Homebrew |
| 0.x pre-releases | ❌ Not supported after 1.0.0 |

Sparkle checks daily by default; a security release is pushed to the appcast the same day it is tagged.

## Release security checklist

Run before tagging (`Scripts/sign_and_notarize.sh` enforces the mechanical ones).

```bash
#!/bin/bash
# Release security gate — exits non-zero on the first failure.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
APP="$ROOT/build/Backglance.app"

echo "· dependencies pinned and unchanged since review"
git diff --quiet HEAD -- "$ROOT/Package.resolved" "$ROOT/Backglance.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

echo "· no content in log calls"
! grep -rnE 'logger\.[a-z]+\(.*(\.title|\.body|\.subtitle|\.sender|userInfo)' "$ROOT/Packages" "$ROOT/Backglance"

echo "· no string-interpolated SQL"
! grep -rnE 'sql:\s*"[^"]*\\\(' "$ROOT/Packages" "$ROOT/Backglance"

echo "· no insecure keyed unarchiving"
! grep -rn 'requiresSecureCoding = false' "$ROOT/Packages" "$ROOT/Backglance"

echo "· hardened runtime, no exceptions, correct identity"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -q 'flags=0x10000(runtime)'
! codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q 'com.apple.security.cs.'
codesign -dv "$APP" 2>&1 | grep -q 'TeamIdentifier=TEAMID1234'

echo "· notarized and stapled"
xcrun stapler validate "$APP"

echo "· appcast signature verifies with the public key in Info.plist"
"$ROOT/Scripts/make_appcast.sh" --verify-only

echo "· hostile fixtures pass"
xcodebuild test -scheme Backglance -testPlan Backglance -only-testing:BackglanceCaptureTests/HostilePlistTests -quiet

echo "OK — release gate passed"
```

Manual items:

- [ ] CHANGELOG lists any security fix with a CVE/GHSA ID if one exists.
- [ ] Sparkle private key never left the `SPARKLE_PRIVATE_KEY` secret; no local copies.
- [ ] Onboarding still says: FDA required, what is read, how to disable updates.
- [ ] Privacy policy in [`./LEGAL_COMPLIANCE.md`](./LEGAL_COMPLIANCE.md) matches actual network behaviour.
- [ ] Verified on a clean macOS 14 VM that `lsof -i -p <pid>` is empty with updates disabled.

## Next Steps

- Read [`../features/PERMISSIONS_PRIVACY.md`](../features/PERMISSIONS_PRIVACY.md) for the user-facing explanation of Full Disk Access.
- Read [`../features/PRIVACY_CONTROLS.md`](../features/PRIVACY_CONTROLS.md) for redaction, exclusions, retention, panic wipe.
- Read [`../deployment/PACKAGING_NOTARIZATION.md`](../deployment/PACKAGING_NOTARIZATION.md) for the signing pipeline this checklist gates.
- Read [`./LEGAL_COMPLIANCE.md`](./LEGAL_COMPLIANCE.md) for the privacy policy and GPL obligations.

## Related Documentation

- [`./LEGAL_COMPLIANCE.md`](./LEGAL_COMPLIANCE.md)
- [`../features/PERMISSIONS_PRIVACY.md`](../features/PERMISSIONS_PRIVACY.md)
- [`../features/PRIVACY_CONTROLS.md`](../features/PRIVACY_CONTROLS.md)
- [`../features/CAPTURE.md`](../features/CAPTURE.md)
- [`../features/ACTIONS.md`](../features/ACTIONS.md)
- [`../features/MISSED_DIGEST.md`](../features/MISSED_DIGEST.md)
- [`../features/CLOUDKIT_SYNC.md`](../features/CLOUDKIT_SYNC.md)
- [`../features/EXPORT_AUTOMATION.md`](../features/EXPORT_AUTOMATION.md)
- [`../architecture/ARCHITECTURE.md`](../architecture/ARCHITECTURE.md)
- [`../architecture/DATABASE_SCHEMA.md`](../architecture/DATABASE_SCHEMA.md)
- [`../architecture/OS_COMPATIBILITY_PLAYBOOK.md`](../architecture/OS_COMPATIBILITY_PLAYBOOK.md)
- [`../deployment/PACKAGING_NOTARIZATION.md`](../deployment/PACKAGING_NOTARIZATION.md)
- [`../deployment/CI_CD.md`](../deployment/CI_CD.md)
- [`../operations/MONITORING_LOGGING.md`](../operations/MONITORING_LOGGING.md)
- [`../testing/TESTING.md`](../testing/TESTING.md)
- [`../contributing/CONTRIBUTING.md`](../contributing/CONTRIBUTING.md)
- [`../reference/FAQ.md`](../reference/FAQ.md)
- [`../../README.md`](../../README.md)
- [`../../CHANGELOG.md`](../../CHANGELOG.md)
