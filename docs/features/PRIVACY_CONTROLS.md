# Privacy Controls

Last Updated: 2026-08-18

This document specifies the controls Backglance v1.0 gives the user over *what* gets archived and *for how long*: per-app retention policies and the `RetentionJob` that enforces them, the exclusion list (apps that are never stored), automatic one-time-code redaction (on by default for Messages and Mail), pausing capture, the panic wipe, and the smaller display and lock controls. It covers the settings surface (`PrivacySettingsView`), the archive tables each control touches, the business logic with real Swift, the edge cases, and how every control is tested. Permissions (Full Disk Access) and the "what we read / what we never touch" list live in [PERMISSIONS_PRIVACY.md](./PERMISSIONS_PRIVACY.md); this file is about the knobs the user turns after capture is running.

## Table of Contents

- [Feature Overview](#feature-overview)
- [Architecture](#architecture)
- [Archive Tables Involved](#archive-tables-involved)
- [Retention Policies](#retention-policies)
  - [Policy Values and Inheritance](#policy-values-and-inheritance)
  - [RetentionJob](#retentionjob)
  - [Soft Delete, Hard Delete, and Cascades](#soft-delete-hard-delete-and-cascades)
- [Exclusion List](#exclusion-list)
  - [Defaults](#defaults)
  - [Where Exclusion Happens](#where-exclusion-happens)
- [One-Time-Code Redaction](#one-time-code-redaction)
  - [What Is Redacted and Where](#what-is-redacted-and-where)
  - [Detection Patterns](#detection-patterns)
  - [OTPRedactor](#otpredactor)
  - [Insert Path](#insert-path)
  - [RedactionEvent Audit Rows](#redactionevent-audit-rows)
  - [Per-App Toggle and "Redact Codes in All Apps"](#per-app-toggle-and-redact-codes-in-all-apps)
  - [False Negatives and False Positives](#false-negatives-and-false-positives)
- [Pause Capture](#pause-capture)
- [Panic Wipe](#panic-wipe)
  - [Confirmation](#confirmation)
  - [PanicWipe.execute()](#panicwipeexecute)
  - [What the Wipe Does Not Do](#what-the-wipe-does-not-do)
- [Other Controls](#other-controls)
- [UI Components](#ui-components)
- [Edge Cases and Error Handling](#edge-cases-and-error-handling)
- [Testing Approach](#testing-approach)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Feature Overview

Backglance keeps notifications that macOS would otherwise throw away. That is the point of the app, and it is also why the privacy controls are not an afterthought: the archive is a record of who contacted you, when, and about what. Every control below is local, works without an account, and needs no network.

| Control | Default | Where | Effect on the archive |
|---|---|---|---|
| Global retention | 30 days | Settings ▸ Privacy ▸ Retention | Notifications older than the policy are soft-deleted, then hard-deleted (FTS and embeddings follow) |
| Per-app retention | inherit | Settings ▸ Privacy ▸ Retention ▸ per app, or the app's row menu | Overrides the global policy for one app; `never` also excludes the app |
| Exclusion list | password managers, `com.apple.Passwords`, Backglance itself | Settings ▸ Privacy ▸ Excluded Apps | Records from these apps are skipped before parsing; nothing is stored |
| One-time-code redaction | **on** for Messages (`com.apple.MobileSMS`) and Mail (`com.apple.mail`) | Settings ▸ Privacy ▸ Code Redaction | Digits replaced with `[code redacted]` in memory before insert; original never written anywhere |
| Pause capture | not paused | Menu bar icon menu, Settings, `backglance://pause` | Nothing is read from the system store while paused; notifications delivered during the pause are not imported afterwards (by default) |
| Panic wipe | — | Settings ▸ Privacy ▸ Wipe archive…, optional global hotkey | Archive, WAL/SHM, icon cache, tmp snapshots and embeddings are securely deleted and an empty archive is recreated |
| Show notification bodies in the timeline | on | Settings ▸ Privacy ▸ Display | Off = rows show title and sender only; the body stays archived and searchable |
| Lock popover behind Touch ID after N minutes | off | Settings ▸ Privacy ▸ Display | v1.x — planned, see below |
| Local-only | always | — | No network at all except the Sparkle updater, which has its own toggle |

> 🔒 **Security:** Redaction is the one control that is *on by default* and that removes information rather than hiding it. Codes from Messages and Mail are replaced before they reach the archive, so they are not in the archive file, the FTS index, the embeddings, the exports, or the log. This is deliberate: a notification history is the single most convenient place for a second-factor code to leak from, so Backglance does not keep them unless the user turns redaction off.

## Architecture

```
                 system store (Apple, read-only snapshot)           ⚠️ undocumented
                                  │
                                  ▼
┌──────────────────────────── BackglanceCapture ─────────────────────────────┐
│ StoreWatcher ─► StoreAdapter.records(after:) ─► [RawStoreRecord]           │
│                                                     │                       │
│   CaptureEngine.ingest(batch)                       ▼                       │
│   ├─ paused?  ──── yes ──► do nothing (cursor untouched)                    │
│   ├─ excluded bundle id? ─ yes ──► skip; advance cursor; plist NOT parsed   │
│   ├─ RecordParser.parse(raw) ─► ParsedNotification                          │
│   ├─ redact_otp for this app (or global "all apps")?                        │
│   │      yes ──► OTPRedactor.redact(parsed) ─► (parsed', RedactionEvent?)   │
│   └─ Archive.insert(parsed', event)   ◄── the only place content is written │
└─────────────────────────────────────────────┬───────────────────────────────┘
                                              ▼
┌──────────────────────────── BackglanceCore ────────────────────────────────┐
│ archive.sqlite  ┌────────┐ ┌───────────────┐ ┌────────────┐ ┌───────────┐ │
│ (0600, WAL)     │  apps  │ │ notifications │ │ redactions │ │ embeddings│ │
│                 │retention│ │ is_deleted    │ │ pattern_id │ │ (opt-in)  │ │
│                 │excluded │ │ redaction     │ │ no content │ └───────────┘ │
│                 │redact_otp│└──────┬────────┘ └────────────┘   ▲           │
│                 └────────┘        │ triggers ─► notifications_fts          │
│                                   │                                        │
│  RetentionJob (launch + 6 h) ─────┴─ soft-delete expired ─► hard-delete    │
│  PanicWipe.execute() ─ pause ▸ zero pages ▸ unlink files ▸ recreate ▸ resume│
└────────────────────────────────────────────────────────────────────────────┘
                                              ▲
┌──────────────────────────── BackglanceUI / app ────────────────────────────┐
│ PrivacySettingsView   StatusItemController (pause menu, paused icon)       │
│ WipeConfirmationSheet  HotKeyCenter (optional wipe hotkey)                  │
└────────────────────────────────────────────────────────────────────────────┘
```

Two properties of this layout matter for every section below:

1. **Everything that removes or withholds content runs before or inside `Archive.insert`, or in a job that owns the archive.** There is no second copy of notification text anywhere (the log never contains content; the icon cache holds only app icons; the tmp directory holds the short-lived snapshot copy of the system store, which is deleted after each poll).
2. **The system store is Apple's.** Backglance can exclude, redact, expire and wipe *its own* archive. It cannot change what Notification Center keeps; that is in System Settings ▸ Notifications, and the app links there but does not pretend to control it.

## Archive Tables Involved

| Table | Columns used here | Purpose |
|---|---|---|
| `apps` | `retention`, `is_excluded`, `redact_otp`, `bundle_id`, `display_name` | Per-app privacy settings. `retention` is `'24h' \| '7d' \| '30d' \| 'forever' \| 'never' \| 'inherit'`; `never` implies `is_excluded = 1` |
| `notifications` | `is_deleted`, `redaction`, `delivered_at`, `app_id` | Soft-delete flag consumed by `RetentionJob`; `redaction = 'otp'` marks rows whose text was redacted |
| `notifications_fts` | external content of `notifications` | Updated by the `notifications_ad` trigger on hard delete; never sees redacted digits because the row is inserted already redacted |
| `redactions` | `notification_id`, `kind`, `pattern_id`, `redacted_at` | Audit rows for redaction. Stores *that* something was redacted and by which pattern, never the original |
| `embeddings` (v1.x / opt-in) | `notification_id` | Deleted by `ON DELETE CASCADE` on hard delete |
| `capture_state` | `cursor` | Advanced past excluded records; reset to the store head after a wipe |
| `schema_meta` | `archive_version` | Re-created by migrations after a wipe |

The global default policy, the "redact codes in all apps" switch, the paused-until timestamp and the display toggles live in `UserDefaults` (suite `app.backglance.Backglance`), not in the archive, so they survive a wipe. Keys used in this document:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `privacy.globalRetention` | String (`RetentionPolicy` raw value) | `"30d"` | Global retention |
| `privacy.redactOTPInAllApps` | Bool | `false` | Redact in every app, not only the ones with `apps.redact_otp = 1` |
| `privacy.showBodies` | Bool | `true` | Show bodies in timeline rows |
| `privacy.lockAfterMinutes` | Int | `0` (off) | v1.x popover lock |
| `privacy.wipeHotkeyEnabled` | Bool | `false` | Global hotkey for the wipe confirmation sheet |
| `capture.pausedUntil` | Double | `0` | Unix seconds; `0` = not paused, `-1` = paused indefinitely |
| `capture.importWhilePaused` | Bool | `false` | Import notifications delivered during a pause when resuming |
| `updates.automaticChecks` | Bool | `true` | Mirrors Sparkle's automatic check setting |

The canonical DDL is in [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md). Dates are stored as Unix seconds via the `UnixDate` wrapper.

## Retention Policies

### Policy Values and Inheritance

```swift
public enum RetentionPolicy: String, Codable, Sendable, CaseIterable {
    case hours24 = "24h"
    case days7   = "7d"
    case days30  = "30d"
    case forever
    case never

    /// Rows delivered before this instant are expired. `nil` = nothing expires by age.
    public func cutoff(from now: Date) -> Date? {
        switch self {
        case .hours24: return now.addingTimeInterval(-24 * 3600)
        case .days7:   return now.addingTimeInterval(-7 * 86_400)
        case .days30:  return now.addingTimeInterval(-30 * 86_400)
        case .forever: return nil
        case .never:   return nil          // nothing to expire: the app is excluded and never inserted
        }
    }
}

extension AppRecord {
    /// `apps.retention` also allows 'inherit'; the record exposes it as an optional override.
    /// `retentionOverride == nil` means "use the global policy".
    public func effectiveRetention(global: RetentionPolicy) -> RetentionPolicy {
        retentionOverride ?? global
    }
}
```

| User picks | Stored in `apps.retention` | Effect |
|---|---|---|
| Inherit (default) | `'inherit'` | Global policy applies |
| Keep 24 hours / 7 days / 30 days | `'24h'` / `'7d'` / `'30d'` | Rows older than that are expired by the job |
| Keep forever | `'forever'` | Never expired by age; the user can still delete manually |
| Never store | `'never'` | Same as adding the app to the exclusion list: `is_excluded = 1` is set in the same transaction, capture skips the app, and the settings sheet offers to delete what is already archived |

Global default is 30 days. The choice is meant to match what people expect from a "recent history": long enough to find last week's delivery code or the meeting link from Monday, short enough that the archive does not become a years-long log by accident. `forever` is one click away for people who want a real archive.

> ℹ️ **Info:** Retention is measured from `delivered_at` (when macOS delivered the notification), not from `captured_at`. A late import ([CAPTURE.md](./CAPTURE.md)) that brings in a 6-day-old notification under a 7-day policy will see it expire tomorrow, which is what the policy says.

### RetentionJob

`RetentionJob` is an actor in `BackglanceCore`. It runs once 30 seconds after launch (so the popover and capture come up first) and then every 6 hours while the app is running. It is also invoked directly when the user changes a policy to a shorter value, chooses "Never store" with "also delete existing", or picks "Run cleanup now" in settings.

```swift
import Foundation
import GRDB
import os

public actor RetentionJob {
    public static let interval: TimeInterval = 6 * 60 * 60
    public static let launchDelay: TimeInterval = 30
    public static let batchSize = 500

    public struct Report: Sendable, Equatable {
        public var softDeleted = 0
        public var hardDeleted = 0
        public var appsScanned = 0
    }

    private let archive: Archive
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date            // injectable clock for tests
    private var loop: Task<Void, Never>?
    private let log = Logger(subsystem: "app.backglance.Backglance", category: "retention")

    public init(archive: Archive,
                defaults: UserDefaults = UserDefaults(suiteName: "app.backglance.Backglance") ?? .standard,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.archive = archive
        self.defaults = defaults
        self.now = now
    }

    public func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.launchDelay))
            while !Task.isCancelled {
                await self?.runOnce()
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    public func stop() { loop?.cancel(); loop = nil }

    /// Runs one pass. Never throws: a failed pass is logged (without content) and retried next cycle.
    @discardableResult
    public func runOnce() async -> Report {
        do {
            let report = try await prune()
            log.info("retention pass: soft=\(report.softDeleted) hard=\(report.hardDeleted) apps=\(report.appsScanned)")
            return report
        } catch {
            // The archive may be closed (panic wipe in progress) or the disk may be full.
            log.error("retention pass failed: \(error.localizedDescription, privacy: .public)")
            return Report()
        }
    }

    func prune() async throws -> Report {
        let now = self.now()
        let global = RetentionPolicy(rawValue: defaults.string(forKey: "privacy.globalRetention") ?? "") ?? .days30
        var report = Report()

        // Phase 1 — hard-delete anything that was soft-deleted earlier (by a previous pass or by the user).
        // Rows soft-deleted in the last 60 s are skipped so a pending "Undo" toast can still restore them.
        let guarded = await archive.recentlySoftDeletedIDs(within: 60)
        while true {
            let n = try await archive.write { db in
                try db.execute(sql: """
                    DELETE FROM notifications
                    WHERE id IN (SELECT id FROM notifications
                                 WHERE is_deleted = 1 AND id NOT IN (\(guarded.map(String.init).joined(separator: ",")))
                                 LIMIT ?)
                    """, arguments: [Self.batchSize])
                return db.changesCount
            }
            report.hardDeleted += n
            if n < Self.batchSize { break }
            await Task.yield()                          // let the timeline and capture breathe between batches
        }

        // Phase 2 — soft-delete rows past their app's effective cutoff.
        let apps = try await archive.read { db in try AppRecord.fetchAll(db) }
        for app in apps {
            report.appsScanned += 1
            guard let cutoff = app.effectiveRetention(global: global).cutoff(from: now) else { continue }
            while true {
                let n = try await archive.write { db in
                    try db.execute(sql: """
                        UPDATE notifications SET is_deleted = 1
                        WHERE id IN (SELECT id FROM notifications
                                     WHERE app_id = ? AND is_deleted = 0 AND is_pinned = 0 AND delivered_at < ?
                                     LIMIT ?)
                        """, arguments: [app.id, cutoff.timeIntervalSince1970, Self.batchSize])
                    return db.changesCount
                }
                report.softDeleted += n
                if n < Self.batchSize { break }
                await Task.yield()
            }
        }

        if report.hardDeleted > 0 {
            // The archive is created with auto_vacuum = INCREMENTAL; give some pages back after big prunes.
            try await archive.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA incremental_vacuum(2000)")
            }
        }
        return report
    }
}
```

Behaviour worth stating plainly:

- **Pinned rows are exempt.** `is_pinned = 1` rows are never expired by age. Unpinning them makes them eligible on the next pass.
- **Order of phases.** Hard delete first, then soft delete. A row that expires today is soft-deleted on this pass and hard-deleted on the next one (at most 6 hours later, or on the next launch). During that window it is invisible everywhere (timeline, search, digest, export, analytics all filter `is_deleted = 0`) but still on disk.
- **The job never touches `apps.notification_count`.** That is a lifetime counter for analytics; it is not a "rows currently archived" count.
- **`never` does no work here.** Excluded apps never got rows inserted in the first place; if the app was excluded *after* it had notifications, the settings sheet offers to delete them, which is a soft delete followed by an immediate `runOnce()`.

### Soft Delete, Hard Delete, and Cascades

Why two steps instead of deleting expired rows outright?

- Soft delete is one indexed `UPDATE` per batch and touches no other table, so it is safe to run while the timeline is open. Hard delete fires the FTS `notifications_ad` trigger per row (an FTS5 external-content delete needs the old column values), and cascades into `redactions`, `digest_items`, `snoozes` and `embeddings` through `ON DELETE CASCADE` (`PRAGMA foreign_keys = ON`, which GRDB enables by default). Batching that work in 500-row transactions with a yield in between keeps the pool writer from starving the reader for more than a few milliseconds.
- One door out. Manual delete ([ACTIONS.md](./ACTIONS.md)) and retention use the same `is_deleted` flag and the same hard-delete phase, so there is exactly one query shape every reader has to filter on.

```
expired / user-deleted            RetentionJob (next pass, ≤ 6 h)
notifications.is_deleted = 1 ───► DELETE FROM notifications
                                     ├─ trigger notifications_ad ─► notifications_fts (row removed)
                                     ├─ FK cascade ─► redactions, digest_items, snoozes
                                     └─ FK cascade ─► embeddings (semantic vector gone)
                                  PRAGMA incremental_vacuum(2000)
```

> 🔒 **Security:** The archive connection is opened with `PRAGMA secure_delete = ON` (set in `Archive`'s `Configuration.prepareDatabase`). Freed pages are zeroed when a row is hard-deleted, so deleted text does not linger in the file's free list. Combined with FileVault, `0600` permissions and Backglance's own `0700` directory this is the v1.0 at-rest story; SQLCipher is a v1.x option (see [SECURITY.md](../security/SECURITY.md)).

## Exclusion List

### Defaults

Backglance ships a small exclusion list. It lives in code, as `ExclusionList.shippedDefaults` (`BackglanceCore/Privacy/ExclusionList.swift`), and the user's own decisions are layered over it as `apps.is_excluded`:

| Bundle identifier | Why |
|---|---|
| `com.1password.1password` | Password manager |
| `com.agilebits.onepassword7` | Password manager (1Password 7) |
| `com.bitwarden.desktop` | Password manager |
| `com.dashlane.Dashlane` | Password manager |
| `com.lastpass.LastPass` | Password manager |
| `com.apple.Passwords` | Apple Passwords |
| `app.backglance.Backglance` | Backglance's own local notifications (digest banner, snooze reminders) — archiving them would be noise |

> ℹ️ **Note:** an earlier version of this document had the seven rows seeded into `apps` by the `v1_initial` migration. They are not, and the reason is worth stating: a seeded row is frozen at the moment the archive was created, so a release that added a password manager to the list would only ever protect *new* installs. Held in code, the list is whatever the running build says it is, and every existing archive picks up an addition on the next launch. It also keeps `apps` meaning one thing — apps that have notified, or that the user has configured — rather than filling it with rows carrying `first_seen_at` values that never happened.
>
> The same note applies to the redaction defaults ([above](#per-app-toggle-and-redact-codes-in-all-apps)), for the same reason.

An excluded app is not given `retention = 'never'`. Exclusion governs *capture*; retention governs what is *kept*, and coupling them would make the Excluded Apps toggle silently destructive — someone excluding an app from here on has not thereby asked to lose the last month of it. Deleting what is already archived is the per-app `never` retention policy, which is a separate, explicitly labelled choice ([Retention Policies](#policy-values-and-inheritance)).

The list is deliberately short. Backglance cannot know that an app is a bank, a brokerage, or a health service: bundle identifiers do not say, and a curated list of "sensitive apps" would be wrong for most people. The Excluded Apps pane makes adding an app a two-click job (pick from apps seen in the archive, apps currently installed, or type a bundle identifier), and the onboarding's last screen points at it once.

Users can remove any default, including the password managers: an `apps` row saying `is_excluded = 0` outranks the shipped default, which is what makes that promise true rather than merely stated. "Restore defaults" (`Archive.restoreDefaultExclusions()`) undoes exactly those removals — `ExclusionList.suppressedDefaults` — and leaves an app the user added themselves excluded, because restoring the defaults means restoring the defaults and not un-excluding somebody's bank.

> 💡 **Tip:** If you only want to hide an app's *bodies* but keep the fact that it notified you, use the per-app "Show bodies" override or a rule ([RULES.md](./RULES.md)) rather than exclusion. Exclusion stores nothing, not even the timestamp.

### Where Exclusion Happens

Exclusion is checked in `CaptureEngine.ingest` on the raw record's `appIdentifier`, **before** `RecordParser.parse` decodes the property list. The record's `plistData` bytes exist in memory as part of the batch read from the snapshot copy of the system store, but they are never decoded, never logged, and never handed to any other component; they are released with the batch. The cursor is still advanced past the record so it is not read again on the next poll.

```swift
extension CaptureEngine {
    /// Ingests one batch from the adapter. Called on the capture actor.
    func ingest(_ batch: [RawStoreRecord], adapter: any StoreAdapter) async throws {
        let excluded = try await archive.excludedBundleIDs()          // Set<String>, cached; invalidated on settings change
        let redactAll = defaults.bool(forKey: "privacy.redactOTPInAllApps")
        var skipped = 0

        for raw in batch {
            defer { cursor = adapter.cursor(for: raw) }               // always move on, even for skipped/failed rows

            if excluded.contains(raw.appIdentifier) {
                skipped += 1
                continue                                              // plistData is never parsed for excluded apps
            }

            var parsed: ParsedNotification
            do {
                parsed = try parser.parse(raw)
            } catch {
                // ⚠️ undocumented plist layout: a single odd record must not stop the batch
                log.warning("parse failed for rec \(raw.recID) (\(raw.appIdentifier, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                continue
            }

            // The app row first: it carries `redact_otp`, holds no notification content,
            // and is what `PerAppOTPRedaction` is gated on together with `redactAll`.
            let app = try archive.upsertApp(bundleID: parsed.bundleID, now: Date())
            var event: RedactionEvent?
            (parsed, event) = redactor.redact(parsed, appRedactsOTP: app.redactOtp)   // in memory, before anything is written
            _ = try await archive.insert(parsed, redaction: event, source: .live)
        }
        if skipped > 0 { log.debug("skipped \(skipped) excluded records") }
        try await archive.saveCursor(cursor)
    }
}
```

Two honest caveats:

- The **snapshot copy** of the system store that `StoreWatcher` makes in `~/Library/Application Support/Backglance/tmp/` contains every record Apple's store holds, including excluded apps, for the duration of one poll (typically well under a second). The directory is `0700`, the copy is deleted after each poll, and the panic wipe removes the directory. This is inherent to reading a WAL-mode SQLite database safely without touching Apple's live file ([CAPTURE.md](./CAPTURE.md)).
- **Excluding an app does not remove it from Apple's store.** Notification Center still keeps whatever it keeps. Backglance shows a one-line reminder of this in the Excluded Apps pane with a link to System Settings ▸ Notifications.

## One-Time-Code Redaction

> 🔒 **Security:** On by default for Messages (`com.apple.MobileSMS`) and Mail (`com.apple.mail`). Codes are replaced with `[code redacted]` in memory before the row is inserted. The original digits are never written to the archive, the FTS index, the embeddings, an export, or the log, and no audit row contains them. Turning redaction off only affects notifications captured *after* the change; nothing that was redacted can be recovered, because there is nothing to recover it from.

### What Is Redacted and Where

| Place | Contains the code? | Why |
|---|---|---|
| `notifications.title / subtitle / body` | No | Replaced before `INSERT` |
| `notifications_fts` | No | The FTS trigger indexes the already-redacted row |
| `embeddings.vector` | No | `SemanticIndex` embeds the stored (redacted) text |
| CSV / JSON export | No | Exports read the archive |
| `~/Library/Logs/Backglance/backglance.log` | No | Logging never includes notification content; redaction logs only counts and pattern ids |
| `redactions` audit table | No | `kind`, `pattern_id`, `redacted_at` only |
| Snapshot copy in `tmp/` | Yes, transiently | Byte copy of Apple's store during one poll; deleted afterwards (see above) |
| Apple's system store | Yes | Not Backglance's; the code stays wherever Notification Center keeps it |

### Detection Patterns

The redactor is intentionally rule-based and small. It has three pattern families, each with a stable `pattern_id` that ends up in the audit row so false positives can be discussed by id, not by content:

| `pattern_id` | Rule |
|---|---|
| `otp.keyword.en` | A digit group within 40 characters of an English keyword: `code`, `verification`, `passcode`, `OTP`, `one-time`, `PIN`, `login` |
| `otp.keyword.tr` | Same, Turkish keywords `kod`, `doğrulama`, `şifre` (prefix-matched, because Turkish suffixes: `kodunuz`, `şifreniz`) |
| `otp.keyword.de` | Same, German keywords `Code`, `Bestätigungscode`, `Einmalpasswort` |
| `otp.bare` | The whole field, trimmed, is nothing but a digit group ("`123 456`"-shaped SMS bodies from some senders) |

A *digit group* is 4–8 consecutive digits, or two groups of 3–4 digits separated by one space or hyphen. Keyword matching goes through `String.matchKey` — locale-neutral folding, case- and diacritic-insensitive, shared with the rules engine (see [INTERNATIONALIZATION.md](../reference/INTERNATIONALIZATION.md) for the Turkish dotted/dotless I discussion). It is **tokenised**, not substring: "pin" must not match inside "shipping", nor "code" inside "barcode", or a large share of what online shops send would be redacted. A keyword in the title or subtitle counts as context for digits in the body, because titles are short and senders often put "Verification code" in the title.

Context rules that reject a candidate (false-positive guards):

| Guard | Rejects |
|---|---|
| `OTPPatterns.hasCodeBoundaries` — not glued to a decimal, `,`, `:`, `+`, `(` or a currency symbol before; not followed by `.`, `,`, `:`, `%`, a currency symbol, or a currency word (`USD`, `EUR`, `TRY`, `TL`, `GBP`) | prices (`1.234,56`, `$4999`, `4999 USD`), percentages, times (`12:30`), reference numbers inside longer runs |
| `OTPPatterns.partOfLongerNumber` — extending through digits, spaces, hyphens, parentheses and `+` yields more than 8 digits, or the run starts with `+` | phone numbers (`+1 555 0100`, `(555) 010-0100`) |
| `OTPPatterns.looksLikeDate` — `dd.mm.` / `dd/mm/` before, or `-mm-dd` after | `01.09.2026`, `2026-09-01` |
| `OTPPatterns.isYearLike` — four digits in 1900–2099 need a keyword within 12 characters rather than 40, and may not borrow the header's | "see you in 2027, login at…" |

### OTPRedactor

The type is pure and synchronous. It never logs, never touches the archive, and returns the redacted text plus an audit event with no content in it.

It takes a `Content` triple — title, subtitle, body — rather than a `ParsedNotification`, because that type belongs to `BackglanceCapture`, which depends on `BackglanceCore` and not the other way round ([ARCHITECTURE.md](../architecture/ARCHITECTURE.md#dependency-graph)). `BackglanceCapture` adds the adapter, which is also what keeps the redactor testable against plain strings:

```swift
// Packages/BackglanceCore/Sources/BackglanceCore/Redaction/OTPRedactor.swift
public struct OTPRedactor: Sendable {
    public struct Content: Sendable, Equatable {
        public var title: String?
        public var subtitle: String?
        public var body: String?
    }

    public struct Result: Sendable, Equatable {
        public let content: Content
        public let event: RedactionEvent?      // nil ⇒ content is byte-identical to the input
    }

    public static let `default` = OTPRedactor()

    public func redact(_ content: Content) -> Result
}

// Packages/BackglanceCapture/Sources/BackglanceCapture/Parsing/ParsedNotification+Redaction.swift
public extension ParsedNotification {
    func redactingOTP(with redactor: OTPRedactor = .default) -> (ParsedNotification, RedactionEvent?)
}
```

The walk over a field, in order:

1. **Bare field.** If the whole field trimmed is a digit group, it is the code — some senders' SMS bodies are literally `445 566`, and no keyword can rescue those. A year-like value is exempt: a body of `2026` is a date far more often than a code.
2. **Candidates, back to front.** Each code-shaped group is checked against the boundary, date and phone guards from `OTPPatterns`. Replacing from the end keeps earlier ranges valid — the placeholder is a different length from the digits, so going forwards would invalidate every index after the first substitution.
3. **Context.** A keyword within the window vouches for the group. A year-like group has to find one within 12 characters and may not borrow the header's, because "see you in 2027" inside a notification titled "Login code" is a date, and the year is the part the reader needs.

A keyword in the **title or subtitle is context for digits in the body** — titles are short, and senders routinely put "Verification code" in the title with the digits alone in the body. It does not work the other way round: a long body that mentions "code" somewhere should not license redacting a number in the title.

The pattern that fires first, in title → subtitle → body order, is the one recorded on the audit row.

> ℹ️ **Note:** the shipped matcher does not use the regex lookarounds this document originally sketched. Swift's `Regex` has no lookbehind, and the alternative — `NSRegularExpression` built with `try!` — turns a typo in a pattern into a crash on the first notification. The boundary rules live in `OTPPatterns.hasCodeBoundaries(before:after:)` instead, where each is a named function with its own test, and every pattern is a compile-time-checked literal.

`RedactionEvent` is the GRDB record for the `redactions` table:

```swift
import Foundation
import GRDB

public struct RedactionEvent: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "redactions"

    public enum Kind: String, Codable, Sendable { case otp }

    public var id: Int64?
    public var notificationID: Int64?      // assigned by Archive.insert once the notification row exists
    public var kind: Kind
    public var patternID: String
    public var redactedAt: Date

    public init(kind: Kind, patternID: String, redactedAt: Date) {
        self.kind = kind
        self.patternID = patternID
        self.redactedAt = redactedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, kind
        case notificationID = "notification_id"
        case patternID = "pattern_id"
        case redactedAt = "redacted_at"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
```

### Insert Path

`Archive.insert` writes the notification and its audit row in one transaction. Because the row is already redacted when it reaches this method, the FTS trigger and (later) the semantic indexer only ever see the placeholder.

```swift
extension Archive {
    /// Inserts an already-parsed (and, if applicable, already-redacted) notification.
    /// Returns the new archive id. Throws `ArchiveError.duplicate` if `uuid`/`store_rec_id` already exist.
    func insert(_ parsed: ParsedNotification, redaction event: RedactionEvent?, source: ArchivedNotification.Source) async throws -> Int64 {
        do {
            return try await write { db in
                let app = try AppRecord.upsert(bundleID: parsed.bundleID, seenAt: parsed.deliveredAt, in: db)
                var row = ArchivedNotification(parsed, appID: app.id!, source: source)
                row.redaction = event == nil ? .none : .otp
                try row.insert(db)                       // notifications_ai trigger indexes the redacted text
                if var event {
                    event.notificationID = row.id
                    try event.insert(db)
                }
                return row.id!
            }
        } catch let e as DatabaseError where e.resultCode == .SQLITE_CONSTRAINT {
            throw ArchiveError.duplicate(uuid: parsed.uuid)   // dedup by uuid / store_rec_id; caller logs and moves on
        }
    }
}
```

### RedactionEvent Audit Rows

Every redaction inserts one `redactions` row: which notification, which pattern, when. Nothing else. The Privacy pane shows a small "Redaction activity" table built from this: count per app for the last 30 days and the last pattern id that fired. It exists so a user can see the feature is working (and how often), and so a false positive can be reported by `pattern_id` and app without ever quoting the message.

```sql
-- "Redaction activity" (last 30 days), no content involved
SELECT a.display_name, a.bundle_id, COUNT(*) AS redactions, MAX(r.redacted_at) AS last_at
FROM redactions r
JOIN notifications n ON n.id = r.notification_id
JOIN apps a ON a.id = n.app_id
WHERE r.redacted_at >= strftime('%s', 'now') - 30 * 86400
GROUP BY a.id ORDER BY redactions DESC;
```

### Per-App Toggle and "Redact Codes in All Apps"

- `apps.redact_otp` is `1` for `com.apple.MobileSMS` and `com.apple.mail`, `0` for everything else. The two defaults live in one place, `RedactionPolicy.defaultBundleIDs`, and are applied by `Archive.upsertApp` when a row is first created — *not* seeded as rows by `v1_initial`, which would put two apps that have notified nobody into `apps` and therefore into the timeline's app list, with `first_seen_at` values that mean nothing. `Archive.redactsOTP(bundleID:)` answers with the shipped default for an app that has no row yet, so the first code Messages ever delivers is already covered.
- The Code Redaction pane (`CodeRedactionSettingsView`, whose per-app rows are `RedactionAppList`) lists the apps the archive holds, noisiest first, and appends Messages and Mail if neither has notified yet — otherwise redaction would appear to be off on a Mac where it is simply idle. Adding an app that has not been seen is possible by bundle identifier: `Archive.setRedactsOTP(_:bundleID:)` creates the same row capture would have created later, so the setting is already in place when the app's first notification arrives.
- **"Redact codes in all apps"** (`privacy.redactOTPInAllApps`) applies the redactor to every notification regardless of `apps.redact_otp`. It is off by default because the keyword rules are tuned for SMS/e-mail phrasing, and running them over Slack or a build server produces more false positives (ticket numbers next to the word "login", for instance). The pane says exactly that under the toggle.
- Turning redaction off for Messages or Mail warns that future codes from that app will be archived as they arrive — once, not on every toggle, and not for an app the user switched on themselves. The "shown" flag is a preference (`privacy.redactionPlainTextWarningShown`), because having been told is a fact about the user rather than about this launch.

### False Negatives and False Positives

**False negatives are possible.** The redactor is a small set of patterns; a sender that phrases a code in a novel way, in a language without a keyword set, or with letters mixed into the code (`A7X-42Q`) will slip through and the code will be archived like any other text. Backglance does not claim otherwise. If you see a pattern that slips through, please open an issue with a **synthetic** example: same phrasing, digits replaced by a code you invented on the spot, sender name replaced by `example.com`. Never paste a real message. The issue template for redaction has a checkbox for this.

**False positives cannot be undone.** If the redactor replaces something that was not a code (a 6-digit order number next to the word "login", say), the original digits are gone: they were replaced in memory before the insert, and no copy exists. The row's context menu shows "This wasn't a code…" which opens a small sheet that says exactly that, then offers three things: turn redaction off for this app, add the sender to a per-app allow-list (v1.x, marked planned in the sheet), or open a pre-filled issue with the `pattern_id`, the app's bundle identifier, and nothing else. The wording in the sheet is deliberate: "Backglance cannot restore the original text because it never stored it."

> ⚠️ **Warning:** Do not read this as "redaction is unreliable". Read it as "redaction removes data irreversibly, on purpose, and the patterns are conservative rather than clever". Both directions of error are documented so nobody is surprised.

## Pause Capture

Pausing stops Backglance from reading the system store. It is meant for the moments where you would rather not have a record: a screen-share where a stranger might see the popover, an hour of personal messages, a demo.

| Choice | `capture.pausedUntil` | Resumes |
|---|---|---|
| 15 minutes | now + 900 s | automatically |
| 1 hour | now + 3600 s | automatically |
| Until tomorrow | next local midnight (`Calendar.current.startOfDay(for: tomorrow)`) | automatically |
| Indefinitely | `-1` | only when the user chooses Resume |

Where: the menu bar icon's right-click menu (`Pause Capture ▸ 15 minutes / 1 hour / Until tomorrow / Indefinitely`, then a single `Resume Capture` item while paused), Settings ▸ Privacy, and `backglance://pause?minutes=30` / `backglance://resume` ([EXPORT_AUTOMATION.md](./EXPORT_AUTOMATION.md) covers the URL scheme). The status item draws the icon dimmed with a small pause glyph while paused and its tooltip says until when.

```swift
extension CaptureEngine {
    /// Pauses reading the system store. `until == nil` means indefinitely.
    public func pause(until: Date?) async {
        watcher.suspend()                                     // no DispatchSource events, no polls
        status = .paused(until: until)
        defaults.set(until?.timeIntervalSince1970 ?? -1, forKey: "capture.pausedUntil")   // survives relaunch
        resumeTask?.cancel()
        if let until {
            resumeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                await self?.resume()
            }
        }
        log.notice("capture paused until \(until.map { "\($0)" } ?? "resumed manually", privacy: .public)")
    }

    public func resume() async {
        resumeTask?.cancel()
        defaults.set(0.0, forKey: "capture.pausedUntil")
        if !defaults.bool(forKey: "capture.importWhilePaused") {
            // Default: whatever was delivered while paused is left in Apple's store, not imported.
            do { try await skipToStoreHead() } catch { log.error("could not advance cursor after pause: \(error.localizedDescription, privacy: .public)") }
        }
        watcher.resume()
        status = .running
        await pollNow()                                       // pick up from the (possibly advanced) cursor
    }
}
```

Notifications delivered while paused are **not imported by default**: on resume the cursor is moved to the store's current head, so the pause is a real gap in the archive rather than a delay. The setting "Import notifications received while paused" (`capture.importWhilePaused`) turns this into a delay instead; that is the right choice for "I paused to give a talk and still want the record", and the wrong one for "I paused because I did not want a record". The Privacy pane explains the difference in one sentence next to the toggle.

Pause survives relaunch (`capture.pausedUntil` is read at start; an expired timestamp resumes immediately). Wake from sleep does not resume a pause. The system store keeps whatever it keeps regardless — Backglance is just not looking.

## Panic Wipe

Settings ▸ Privacy ▸ **Wipe archive…** deletes everything Backglance has stored and starts over. It is a single, deliberate, hard-to-trigger-by-accident action.

### Confirmation

1. A sheet explains what will be deleted and what will not (the list in [What the Wipe Does Not Do](#what-the-wipe-does-not-do) is shown verbatim).
2. The user types `wipe` into a text field. The button stays disabled until the field matches (case-insensitive, whitespace trimmed).
3. If Touch ID is available (`LAContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`), the sheet asks for it. If not (a Mac without a Secure Enclave, or a clamshell setup with no Touch ID keyboard), the typed word is the only gate; the sheet says so.
4. Optional checkbox: "Also forget per-app settings (excluded apps, retention overrides, redaction toggles)". Off by default: those rows are bundle identifiers and flags, not content, and most people want their exclusion list back after a wipe. On means the fresh archive gets only the seed defaults.

The optional global hotkey (`privacy.wipeHotkeyEnabled`, registered through `HotKeyCenter`, no default binding) opens the same sheet. It never wipes without the sheet.

```swift
import LocalAuthentication

public enum PanicWipeError: Error, LocalizedError {
    case confirmationMismatch
    case biometricsFailed(underlying: Error?)
    case fileRemovalFailed(URL, underlying: Error)
    case reopenFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .confirmationMismatch:            return "Type “wipe” to confirm."
        case .biometricsFailed:                return "Touch ID did not succeed. Nothing was deleted."
        case .fileRemovalFailed(let url, _):   return "Could not remove \(url.lastPathComponent). The archive was emptied but the file remains; see the log."
        case .reopenFailed:                    return "The archive was wiped but a new one could not be created. Capture is paused; relaunch Backglance."
        }
    }
}

extension PanicWipe {
    /// Both gates. Throws before any file is touched.
    public static func confirm(typed: String) async throws {
        guard typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "wipe" else {
            throw PanicWipeError.confirmationMismatch
        }
        let context = LAContext()
        var probeError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &probeError) else {
            return                                    // no Touch ID here: the typed word is the only gate
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                      localizedReason: "Wipe the Backglance archive")
            guard ok else { throw PanicWipeError.biometricsFailed(underlying: nil) }
        } catch let e as PanicWipeError {
            throw e
        } catch {
            throw PanicWipeError.biometricsFailed(underlying: error)   // user cancelled, lockout, etc.
        }
    }
}
```

### PanicWipe.execute()

```swift
import Foundation
import GRDB
import os

public enum PanicWipe {
    public struct Options: Sendable {
        public var forgetPerAppSettings = false
        public init(forgetPerAppSettings: Bool = false) { self.forgetPerAppSettings = forgetPerAppSettings }
    }

    private static let log = Logger(subsystem: "app.backglance.Backglance", category: "wipe")

    /// Order matters: stop writers → zero pages → unlink → recreate → restart.
    /// Call `confirm(typed:)` first; this method assumes consent.
    public static func execute(archive: Archive,
                               capture: CaptureEngine,
                               semantic: SemanticIndex?,
                               paths: ArchivePaths = .default,
                               options: Options = Options()) async throws {
        log.notice("panic wipe: begin")

        // 1. Stop every writer. Retention job checks `archive.isOpen` and no-ops while closed.
        await capture.pause(until: nil)
        semantic?.dropInMemoryCache()

        // 2. Remember per-app privacy settings (bundle ids + flags only) unless told to forget them.
        let preserved: [AppPrivacySetting] = options.forgetPerAppSettings ? [] : try await archive.perAppPrivacySettings()

        // 3. Zero the pages before unlinking: DELETE with secure_delete overwrites freed content,
        //    the checkpoint folds the WAL back into the main file, VACUUM rewrites it compactly.
        try await archive.write { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
            for table in ["digest_items", "digests", "redactions", "embeddings", "snoozes",
                          "saved_searches", "notifications", "away_sessions", "rules", "apps", "capture_state"] {
                if try db.tableExists(table) { try db.execute(sql: "DELETE FROM \(table)") }
            }
        }
        try await archive.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            try db.execute(sql: "VACUUM")
        }

        // 4. Close the pool and unlink everything Backglance owns.
        await archive.close()
        let victims: [URL] = [
            paths.archive, paths.archive.appendingPathExtension("wal").standardized,
            paths.archiveWAL, paths.archiveSHM,
            paths.icons, paths.tmp
        ]
        for url in victims {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                continue                                          // already gone: fine
            } catch {
                log.error("wipe: could not remove \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw PanicWipeError.fileRemovalFailed(url, underlying: error)
            }
        }

        // 5. Recreate an empty archive (migrations run, seed exclusion list is re-inserted).
        do {
            try await archive.reopen()
            try await archive.restorePerAppPrivacySettings(preserved)
        } catch {
            throw PanicWipeError.reopenFailed(underlying: error)     // capture stays paused; UI tells the user
        }

        // 6. Restart capture from the store's *current* head so the wipe is not undone by a re-import
        //    of whatever Apple's store still holds. "Import existing" in settings is available if wanted.
        try await capture.skipToStoreHead()
        await capture.resume()
        log.notice("panic wipe: done")
    }
}
```

`ArchivePaths.default` resolves to `~/Library/Application Support/Backglance/` with `archive.sqlite`, `archive.sqlite-wal`, `archive.sqlite-shm`, `icons/` and `tmp/`. The `embeddings` table lives inside the archive file, so it goes with it; `SemanticIndex.dropInMemoryCache()` clears the vectors currently held in memory.

Timing: on a 100k-notification archive (~150 MB) the whole sequence takes 2–4 s on Apple silicon; the DELETE + VACUUM is most of it. The sheet shows a progress indicator and disables the window until `execute` returns.

### What the Wipe Does Not Do

The confirmation sheet lists these; they are repeated here because they matter:

| Not affected | Why | What to do instead |
|---|---|---|
| Apple's system store | It is not Backglance's file. Notification Center keeps what it keeps (~7 days, cleared on dismiss) | Clear notifications in Notification Center; there is no supported way to purge the store |
| Time Machine and other backups | Backups made before the wipe still contain the archive file | Exclude `~/Library/Application Support/Backglance` from Time Machine if that matters to you (the Privacy pane has a "Reveal in Finder" button for this) |
| APFS local snapshots | macOS may keep local snapshots for up to 24 h | Wait, or `tmutil deletelocalsnapshots` (advanced) |
| Exports you saved | CSV/JSON files in `~/Downloads` or wherever you put them | Delete them yourself |
| CloudKit private zone (v1.x, only if sync was on) | v1.0 has no sync. In v1.x, `execute` also deletes the private zone when sync is enabled and reports if it could not (offline) | See [CLOUDKIT_SYNC.md](./CLOUDKIT_SYNC.md) |
| `UserDefaults` | Settings are not content | "Reset all settings" is a separate button |
| The log file | It never contains notification content; it does record that a wipe happened | `~/Library/Logs/Backglance/` can be deleted by hand |

> ⚠️ **Warning:** "Wipe" is honest about its scope. It makes Backglance forget. It cannot make macOS, your backups or the sender forget.

## Other Controls

**Show notification bodies in the timeline** (`privacy.showBodies`, default on). When off, timeline rows show app, sender and title only; the body is shown in the detail view when a row is opened, and search snippets fall back to titles. The body is still archived, indexed and exported — this is a *display* control for shared screens, not a storage control. Per-app override lives in the app row's menu.

**Lock the popover behind Touch ID after N minutes** — `> ℹ️ **Status:** Planned for v1.x — not in v1.0.` The setting (`privacy.lockAfterMinutes`, 0 = off) is present in the archive of keys but the pane hides it in v1.0. Design: after N minutes without the popover or window being frontmost, opening either asks `LAContext` `.deviceOwnerAuthentication` (Touch ID or password); capture continues in the background; the unread badge shows a count but no content while locked.

**Local-only by default.** Backglance makes no network requests. The only exception is the Sparkle updater (`SparkleUpdaterController`), and the toggle "Check for updates automatically" (`updates.automaticChecks`) is mirrored into the Privacy pane so the guarantee and the switch sit next to each other. With it off, Backglance opens no sockets. CloudKit sync (v1.x) is opt-in and off by default. There is no telemetry, no crash reporter, no account. See [SECURITY.md](../security/SECURITY.md) for how to verify this with Little Snitch or `nettop`.

**Reveal archive in Finder** — a plain button. People should know where their data is.

## UI Components

`PrivacySettingsView` (SwiftUI, `BackglanceUI`, hosted in the Settings window's "Privacy" tab) is a `Form` with six sections. It reads global settings through `@AppStorage` and per-app rows through a `PrivacySettingsModel` (`@Observable`, main actor) that wraps `Archive`.

```swift
import SwiftUI

struct PrivacySettingsView: View {
    @AppStorage("privacy.globalRetention", store: .backglance) private var globalRetention = RetentionPolicy.days30.rawValue
    @AppStorage("privacy.redactOTPInAllApps", store: .backglance) private var redactAll = false
    @AppStorage("privacy.showBodies", store: .backglance) private var showBodies = true
    @AppStorage("capture.importWhilePaused", store: .backglance) private var importWhilePaused = false
    @AppStorage("updates.automaticChecks", store: .backglance) private var automaticChecks = true

    @State private var model: PrivacySettingsModel
    @State private var showWipeSheet = false
    @State private var showExclusionPicker = false

    init(model: PrivacySettingsModel) { _model = State(initialValue: model) }

    var body: some View {
        Form {
            Section("Retention") {
                Picker("Keep notifications for", selection: $globalRetention) {
                    Text("24 hours").tag(RetentionPolicy.hours24.rawValue)
                    Text("7 days").tag(RetentionPolicy.days7.rawValue)
                    Text("30 days").tag(RetentionPolicy.days30.rawValue)
                    Text("Forever").tag(RetentionPolicy.forever.rawValue)
                }
                .onChange(of: globalRetention) { _, _ in Task { await model.retentionChanged() } }
                PerAppRetentionList(model: model)          // per-app override rows: Inherit / 24h / 7d / 30d / Forever / Never store
                Button("Run cleanup now") { Task { await model.runRetentionNow() } }
                    .disabled(model.isBusy)
            }

            Section {
                ExcludedAppsList(model: model)
                Button("Add app…") { showExclusionPicker = true }
                Button("Restore defaults") { Task { await model.restoreDefaultExclusions() } }
            } header: {
                Text("Excluded apps")
            } footer: {
                Text("Notifications from these apps are never stored. Backglance cannot tell which apps are sensitive — add your bank, brokerage or health apps here.")
            }

            Section {
                CodeRedactionSettingsView(model: model.redaction)   // the all-apps toggle + RedactionAppList
                RedactionActivityTable(model: model)       // counts by app, last 30 days; no content
            } header: {
                Text("One-time code redaction")
            } footer: {
                Text("Verification codes are replaced with “[code redacted]” before they are stored. The original digits are never written to disk. Turning this off cannot restore codes that were already redacted.")
            }

            Section("Pause") {
                PauseStatusRow(model: model)               // "Not paused" / "Paused until 09:00" + Resume button
                Toggle("Import notifications received while paused", isOn: $importWhilePaused)
            }

            Section("Display") {
                Toggle("Show notification bodies in the timeline", isOn: $showBodies)
                Toggle("Check for updates automatically (the only network access)", isOn: $automaticChecks)
                    .onChange(of: automaticChecks) { _, on in model.setAutomaticUpdateChecks(on) }
            }

            Section("Danger zone") {
                Button("Reveal archive in Finder") { model.revealArchive() }
                Button("Wipe archive…", role: .destructive) { showWipeSheet = true }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showWipeSheet) { WipeConfirmationSheet(model: model) }
        .sheet(isPresented: $showExclusionPicker) { ExclusionPickerSheet(model: model) }
        .alert(item: $model.error) { err in
            Alert(title: Text(err.title), message: Text(err.message), dismissButton: .default(Text("OK")))
        }
        .task { await model.load() }
    }
}
```

`WipeConfirmationSheet` is the only view that can call `PanicWipe.execute()`. It calls `PanicWipe.confirm(typed:)` first; a thrown `PanicWipeError` is shown inline and nothing else happens.

```swift
struct WipeConfirmationSheet: View {
    @Bindable var model: PrivacySettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var forgetSettings = false
    @State private var inFlight = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wipe the Backglance archive?").font(.headline)
            Text("This securely deletes every archived notification, the search index, icons and temporary files, and creates an empty archive. It does not touch Apple's Notification Center, your backups, or files you exported.")
            TextField("Type “wipe” to confirm", text: $typed)
            Toggle("Also forget per-app settings (excluded apps, retention, redaction)", isOn: $forgetSettings)
            if let errorText { Text(errorText).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Wipe archive", role: .destructive) { Task { await wipe() } }
                    .disabled(inFlight || typed.trimmingCharacters(in: .whitespaces).lowercased() != "wipe")
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func wipe() async {
        inFlight = true
        defer { inFlight = false }
        do {
            try await PanicWipe.confirm(typed: typed)          // typed word + Touch ID when available
            try await model.wipe(forgetPerAppSettings: forgetSettings)
            dismiss()
        } catch {
            errorText = error.localizedDescription           // e.g. "Touch ID did not succeed. Nothing was deleted."
        }
    }
}
```

Other UI touchpoints:

| Surface | Control |
|---|---|
| Status item right-click menu | Pause Capture ▸ (four choices) / Resume Capture; paused icon state |
| Notification row context menu ([ACTIONS.md](./ACTIONS.md)) | "This wasn't a code…" (only on rows with `redaction = 'otp'`); "Never store notifications from ‹App›" |
| App row in the timeline's app filter | Retention override, Show bodies override, Redact codes toggle |
| Onboarding, last screen | One-line pointer to Excluded Apps and to redaction being on |

## Edge Cases and Error Handling

| Situation | Behaviour |
|---|---|
| Retention pass while the popover is open | Soft delete is invisible to the reader (rows disappear on the next fetch); hard delete runs in 500-row batches with a yield, so the timeline never waits more than a few ms on the writer |
| Retention pass while archive is closed (wipe in progress) | `Archive.write` throws `ArchiveError.closed`; `runOnce` logs and returns an empty report; the next cycle runs normally |
| Disk full during hard delete | SQLite may fail the transaction; batch is rolled back, error logged, retried next cycle. Because soft delete already hid the rows, the user sees no difference |
| Global policy shortened (30d → 24h) | `RetentionJob.runOnce()` is invoked immediately; a sheet says how many notifications will be removed before applying (count via `SELECT COUNT(*)` with the new cutoff) |
| App set to `never` with existing rows | Sheet: "Also delete the N archived notifications from ‹App›?" (default checked). Yes = soft-delete + immediate pass. No = rows stay until they expire under the previous policy, capture stops for the app either way |
| App removed from the exclusion list | Capture starts on the next poll from the current cursor; nothing older is recovered (the store may still have some records: "Import existing" will bring them in) |
| Excluded app's bundle id changes (vendor renames) | Treated as a new app; the pane lists apps *seen* so it is easy to spot; no heuristics |
| Redaction toggled on for an app with existing rows | Only future notifications are affected. Existing rows are not scanned retroactively (a "Redact existing notifications from this app" button is planned for v1.x; it would run the same redactor over stored rows and rewrite them) |
| Redaction pattern matches inside title, not body | Each field is redacted independently; a keyword in the title makes body digits eligible; the event records the first pattern that fired |
| Body is *only* a year-like number (`2026`) | Treated as a bare code and redacted (`otp.bare`). Rare in Messages/Mail; documented as a known trade-off |
| Two codes in one message | Both replaced; one audit row (one row per notification, not per match) |
| Notification captured, then app added to exclusion list | Existing rows stay (unless the sheet's delete option was chosen); the exclusion applies to new records only |
| Pause set, app relaunched | `capture.pausedUntil` is honoured; if it is in the past, capture resumes at launch and (by default) skips to the store head |
| Pause + wake from sleep | Still paused; `didWakeNotification` polls are ignored while paused |
| `backglance://pause?minutes=0` or negative | Treated as invalid; ignored with a log line, no state change |
| Wipe: Touch ID cancelled | `PanicWipeError.biometricsFailed`; nothing deleted; sheet stays open |
| Wipe: file removal fails after tables were emptied | `fileRemovalFailed` is thrown; the archive is already empty and vacuumed (content gone), only the empty file remains; the alert says so and offers "Reveal in Finder" |
| Wipe: reopen fails (permissions, disk) | `reopenFailed`; capture stays paused; alert asks to relaunch. On relaunch `Archive.open` recreates the file |
| Wipe hotkey pressed while sheet is already open | No second sheet; the existing one is brought to front |
| Wipe while a retention pass is mid-batch | The pass's next `write` throws `.closed` and it aborts; the wipe's own `DELETE FROM` handles the rest |
| Wipe with sync on (v1.x) | Private CloudKit zone deletion attempted; if offline, the wipe still completes locally and a persistent banner says the zone will be deleted when online |
| `LAContext` biometrics locked out after failed attempts | Falls into `biometricsFailed`; the sheet suggests unlocking with the password in System Settings first (Backglance does not fall back to `.deviceOwnerAuthentication` here on purpose: the wipe should be *harder*, not easier, when biometrics fail) |

Errors are surfaced as one alert with a plain sentence and no jargon; every error path also writes a `Logger` line at `error` level without content ([MONITORING_LOGGING.md](../operations/MONITORING_LOGGING.md)).

## Testing Approach

All privacy tests are in `Tests/BackglanceCoreTests/Privacy/` and run against `Archive(inMemory: true)` or a temp-directory archive; nothing touches `~/Library`.

> ❌ **Don't:** put a real one-time code, a real phone number, or a real message body in a fixture. Ever. Redaction tests generate synthetic codes with a seeded generator so they are deterministic and obviously fake, and the fixture texts use `example.com` and `+1 555 0100`.

The test helper every redaction test uses:

```swift
/// Deterministic *synthetic* code generator for tests. SplitMix64 keeps it dependency-free.
/// Never paste a real code into a test — generate one.
struct SyntheticOTP {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Zero-padded code with `digits` digits, e.g. 6 → "004217".
    mutating func code(digits: Int = 6) -> String {
        precondition((4...8).contains(digits))
        var bound: UInt64 = 1
        for _ in 0..<digits { bound *= 10 }
        let raw = String(next() % bound)
        return String(repeating: "0", count: digits - raw.count) + raw
    }

    /// Same, split in the middle by `separator` ("123 456" / "1234-5678" shapes).
    mutating func split(digits: Int = 6, separator: Character = " ") -> String {
        let c = code(digits: digits)
        let mid = c.index(c.startIndex, offsetBy: digits / 2)
        return String(c[..<mid]) + String(separator) + String(c[mid...])
    }
}
```

Redaction tests (`OTPRedactorTests`, XCTest; a Swift Testing twin exists for the table-driven part):

```swift
import XCTest
@testable import BackglanceCore

final class OTPRedactorTests: XCTestCase {
    private let redactor = OTPRedactor.default

    func testEnglishKeywordProximity() {
        var rng = SyntheticOTP(seed: 42)
        let code = rng.code()
        let n = ParsedNotification.fixture(bundleID: "com.apple.MobileSMS",
                                           body: "Your verification code is \(code). It expires in 10 minutes.")
        let (out, event) = redactor.redact(n)
        XCTAssertEqual(out.body, "Your verification code is [code redacted]. It expires in 10 minutes.")
        XCTAssertEqual(event?.patternID, "otp.keyword.en")
        XCTAssertFalse(out.body!.contains(code))
    }

    func testTurkishSuffixedKeyword() {
        var rng = SyntheticOTP(seed: 7)
        let code = rng.code()
        let n = ParsedNotification.fixture(bundleID: "com.apple.MobileSMS", body: "Doğrulama kodunuz: \(code)")
        let (out, event) = redactor.redact(n)
        XCTAssertEqual(out.body, "Doğrulama kodunuz: [code redacted]")
        XCTAssertEqual(event?.patternID, "otp.keyword.tr")
    }

    func testGermanSplitCode() {
        var rng = SyntheticOTP(seed: 99)
        let code = rng.split(separator: "-")
        let n = ParsedNotification.fixture(bundleID: "com.apple.mail",
                                           title: "Ihr Bestätigungscode", body: "Ihr Code lautet \(code).")
        let (out, event) = redactor.redact(n)
        XCTAssertEqual(out.body, "Ihr Code lautet [code redacted].")
        XCTAssertNotNil(event)
    }

    func testTitleKeywordMakesBodyDigitsEligible() {
        var rng = SyntheticOTP(seed: 3)
        let code = rng.code(digits: 8)
        let n = ParsedNotification.fixture(bundleID: "com.apple.mail", title: "Verification", body: "\(code) — valid for 5 minutes")
        let (out, _) = redactor.redact(n)
        XCTAssertEqual(out.body, "[code redacted] — valid for 5 minutes")
    }

    func testBareBody() {
        var rng = SyntheticOTP(seed: 1)
        let (out, event) = redactor.redact(.fixture(bundleID: "com.apple.MobileSMS", body: " \(rng.split()) "))
        XCTAssertEqual(out.body, "[code redacted]")
        XCTAssertEqual(event?.patternID, "otp.bare")
    }

    func testFalsePositiveGuards() {
        let untouched = [
            "Your order total is 1.234,56 ₺",
            "Invoice #20481 is due on 2026-09-01",
            "Call +1 555 0100 to confirm your PIN",
            "Meeting moved to 12:30, login link unchanged",
            "Prices up 12% since 2024",
        ]
        for body in untouched {
            let (out, event) = redactor.redact(.fixture(bundleID: "com.apple.MobileSMS", body: body))
            XCTAssertEqual(out.body, body, "should not redact: \(body)")
            XCTAssertNil(event)
        }
    }

    func testNoKeywordNoRedaction() {
        var rng = SyntheticOTP(seed: 11)
        let body = "Order \(rng.code()) has shipped"          // digits without a keyword nearby
        let (out, event) = redactor.redact(.fixture(bundleID: "com.example.shop", body: body))
        XCTAssertEqual(out.body, body)
        XCTAssertNil(event)
    }

    func testRedactedRowNeverReachesFTS() async throws {
        let archive = try Archive(inMemory: true)
        var rng = SyntheticOTP(seed: 5)
        let code = rng.code()
        let (parsed, event) = redactor.redact(.fixture(bundleID: "com.apple.MobileSMS", body: "Your code is \(code)"))
        _ = try await archive.insert(parsed, redaction: event, source: .live)
        let hits = try await archive.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notifications_fts WHERE notifications_fts MATCH ?", arguments: [code])
        }
        XCTAssertEqual(hits, 0)
        let redactions = try await archive.read { db in try RedactionEvent.fetchAll(db) }
        XCTAssertEqual(redactions.count, 1)
        XCTAssertEqual(redactions.first?.patternID, "otp.keyword.en")
    }
}
```

Retention tests use an injected clock:

```swift
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(now: Date) { _now = now }
    var now: Date { lock.withLock { _now } }
    func advance(by seconds: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(seconds) } }
}

final class RetentionJobTests: XCTestCase {
    func testExpiredRowsAreSoftDeletedThenHardDeleted() async throws {
        let archive = try Archive(inMemory: true)
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        defaults.set("30d", forKey: "privacy.globalRetention")
        let job = RetentionJob(archive: archive, defaults: defaults, now: { clock.now })

        let old = try await archive.insertFixtureNotification(bundleID: "com.example.chat", deliveredAt: clock.now.addingTimeInterval(-40 * 86_400))
        let fresh = try await archive.insertFixtureNotification(bundleID: "com.example.chat", deliveredAt: clock.now.addingTimeInterval(-1 * 86_400))

        var report = await job.runOnce()
        XCTAssertEqual(report, RetentionJob.Report(softDeleted: 1, hardDeleted: 0, appsScanned: 1))
        XCTAssertTrue(try await archive.isSoftDeleted(old))

        clock.advance(by: 6 * 3600)                     // next scheduled pass
        report = await job.runOnce()
        XCTAssertEqual(report.hardDeleted, 1)
        XCTAssertNil(try await archive.fetch(old))
        XCTAssertNotNil(try await archive.fetch(fresh))
        XCTAssertEqual(try await archive.ftsRowCount(), 1)  // FTS trigger removed the old row
    }

    func testPerAppOverrideBeatsGlobal() async throws {
        let archive = try Archive(inMemory: true)
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let job = RetentionJob(archive: archive, defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!, now: { clock.now })
        try await archive.setRetention(bundleID: "com.example.chat", .hours24)
        let id = try await archive.insertFixtureNotification(bundleID: "com.example.chat", deliveredAt: clock.now.addingTimeInterval(-2 * 86_400))
        _ = await job.runOnce()
        XCTAssertTrue(try await archive.isSoftDeleted(id))   // 2 days old, 24 h policy
    }

    func testPinnedRowsAreExempt() async throws {
        let archive = try Archive(inMemory: true)
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let job = RetentionJob(archive: archive, defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!, now: { clock.now })
        let id = try await archive.insertFixtureNotification(bundleID: "com.example.chat", deliveredAt: clock.now.addingTimeInterval(-400 * 86_400))
        try await archive.setPinned([id], true)
        _ = await job.runOnce()
        XCTAssertFalse(try await archive.isSoftDeleted(id))
    }

    func testRecentlyDeletedRowsSurviveOnePassForUndo() async throws {
        let archive = try Archive(inMemory: true)
        let clock = TestClock(now: Date())
        let job = RetentionJob(archive: archive, defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!, now: { clock.now })
        let id = try await archive.insertFixtureNotification(bundleID: "com.example.chat", deliveredAt: clock.now)
        _ = try await archive.softDelete([id])          // user pressed Delete a moment ago
        let report = await job.runOnce()
        XCTAssertEqual(report.hardDeleted, 0)            // 60 s undo guard
    }
}
```

Exclusion and wipe tests:

```swift
final class ExclusionTests: XCTestCase {
    func testExcludedRecordsAreNeverParsed() async throws {
        let archive = try Archive(inMemory: true)
        try await archive.setExcluded(bundleID: "com.example.bank", true)
        let parser = CountingParser()                    // test double that counts parse() calls
        let engine = CaptureEngine(archive: archive, parser: parser, defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        let batch = [RawStoreRecord.fixture(recID: 1, appIdentifier: "com.example.bank"),
                     RawStoreRecord.fixture(recID: 2, appIdentifier: "com.example.chat")]
        try await engine.ingest(batch, adapter: FixtureAdapter())
        XCTAssertEqual(parser.parseCalls, 1)             // only the chat record was parsed
        XCTAssertEqual(try await archive.notificationCount(bundleID: "com.example.bank"), 0)
        XCTAssertEqual(try await archive.cursor().lastRecID, 2)   // cursor advanced past the skipped record
    }

    func testDefaultExclusionListIsSeeded() async throws {
        let archive = try Archive(inMemory: true)
        let excluded = try await archive.excludedBundleIDs()
        XCTAssertTrue(excluded.contains("com.1password.1password"))
        XCTAssertTrue(excluded.contains("com.apple.Passwords"))
        XCTAssertTrue(excluded.contains("app.backglance.Backglance"))
        XCTAssertEqual(excluded.count, 7)
    }
}

final class PanicWipeTests: XCTestCase {
    func testWipeRemovesFilesAndRecreatesEmptyArchive() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bg-wipe-\(UUID().uuidString)")
        let paths = ArchivePaths(root: dir)
        let archive = try Archive(paths: paths)
        let capture = CaptureEngine.stub(archive: archive)
        _ = try await archive.insertFixtureNotification(bundleID: "com.example.chat", deliveredAt: Date())
        try "icon".write(to: paths.icons.appendingPathComponent("com.example.chat.png"), atomically: true, encoding: .utf8)
        try await archive.setExcluded(bundleID: "com.example.bank", true)

        try await PanicWipe.execute(archive: archive, capture: capture, semantic: nil, paths: paths)

        XCTAssertEqual(try await archive.totalNotificationCount(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.icons.appendingPathComponent("com.example.chat.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.archive.path))     // recreated
        let excluded = try await archive.excludedBundleIDs()
        XCTAssertTrue(excluded.contains("com.example.bank"))                          // preserved by default
        let status = await capture.status
        XCTAssertEqual(status, .running)
        try? FileManager.default.removeItem(at: dir)
    }

    func testWipeForgettingSettingsLeavesOnlySeeds() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bg-wipe-\(UUID().uuidString)")
        let paths = ArchivePaths(root: dir)
        let archive = try Archive(paths: paths)
        try await archive.setExcluded(bundleID: "com.example.bank", true)
        try await PanicWipe.execute(archive: archive, capture: .stub(archive: archive), semantic: nil, paths: paths,
                                    options: .init(forgetPerAppSettings: true))
        XCTAssertFalse(try await archive.excludedBundleIDs().contains("com.example.bank"))
        try? FileManager.default.removeItem(at: dir)
    }

    func testConfirmRejectsWrongWord() async {
        do {
            try await PanicWipe.confirm(typed: "wpie")
            XCTFail("should throw")
        } catch PanicWipeError.confirmationMismatch {
            // expected: nothing was deleted, no LAContext prompt
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
```

CI runs these on `macos-14`, `macos-15` and `macos-26` runners ([CI_CD.md](../deployment/CI_CD.md)); Touch ID is not available on runners, which is exactly the "typed word only" path, so `confirm` is covered without biometrics. See [TESTING.md](../testing/TESTING.md) for target layout and fixture rules.

## Next Steps

- [PERMISSIONS_PRIVACY.md](./PERMISSIONS_PRIVACY.md) — Full Disk Access, what is read, how to verify the no-network claim.
- [RULES.md](./RULES.md) — muting and highlighting are triage, not privacy; here is where the line is drawn.
- [SECURITY.md](../security/SECURITY.md) — at-rest model, SQLCipher option (v1.x), threat model, reporting.
- v1.x follow-ups: retroactive redaction of existing rows, popover lock, per-app "not a code" allow-list, CloudKit zone deletion on wipe ([CLOUDKIT_SYNC.md](./CLOUDKIT_SYNC.md)).

## Related Documentation

- [PERMISSIONS_PRIVACY.md](./PERMISSIONS_PRIVACY.md) — permissions, what Backglance reads, degraded mode
- [CAPTURE.md](./CAPTURE.md) — `CaptureEngine`, snapshot copy, cursor, adapters
- [ACTIONS.md](./ACTIONS.md) — manual delete/undo that shares the soft-delete path; "This wasn't a code…" and "Never store" row actions
- [RULES.md](./RULES.md) — mute/VIP/highlight (visual triage), how rules see redacted text
- [SEARCH.md](./SEARCH.md) — FTS and semantic index; why redacted digits are never indexed
- [TIMELINE.md](./TIMELINE.md) — "Show bodies" display toggle, unread badge
- [MISSED_DIGEST.md](./MISSED_DIGEST.md) — digest respects `is_deleted` and redaction
- [EXPORT_AUTOMATION.md](./EXPORT_AUTOMATION.md) — `backglance://pause` / `resume`, exports read the archive only
- [CLOUDKIT_SYNC.md](./CLOUDKIT_SYNC.md) — v1.x: what a wipe does to the private zone
- [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md) — canonical DDL for `apps`, `notifications`, `redactions`
- [ARCHITECTURE.md](../architecture/ARCHITECTURE.md) — package layout (`BackglanceCore` owns retention, redaction, wipe)
- [API_DOCUMENTATION.md](../api/API_DOCUMENTATION.md) — `OTPRedactor`, `RetentionJob`, `PanicWipe`, `CaptureEngine.pause(until:)`
- [SECURITY.md](../security/SECURITY.md) — at-rest encryption, secure delete, threat model
- [LEGAL_COMPLIANCE.md](../security/LEGAL_COMPLIANCE.md) — retention and deletion in a data-protection light
- [MONITORING_LOGGING.md](../operations/MONITORING_LOGGING.md) — what the log contains (never content)
- [TROUBLESHOOTING.md](../operations/TROUBLESHOOTING.md) — "my notifications disappeared" (retention) and "wipe failed" entries
- [INTERNATIONALIZATION.md](../reference/INTERNATIONALIZATION.md) — locale-neutral folding, Turkish keywords
- [TESTING.md](../testing/TESTING.md) — test targets, synthetic-only fixture rule
- [FAQ.md](../reference/FAQ.md) — "Does Backglance store my 2FA codes?"
