# CloudKit Sync (Encrypted Multi-Mac)

Last Updated: 2026-08-18

> ℹ️ **Status:** Planned for v1.x — not in v1.0.

Backglance is local-only by design. This document describes the one optional feature that changes that: an **opt-in, off-by-default** sync of the archive between the user's own Macs through their own iCloud private database, with every content field end-to-end encrypted so that Apple's servers hold ciphertext. It explains what is synced, what is never synced, how conflicts are resolved, how the sync engine is built on `CKSyncEngine`, and what the encryption does and does not protect against.

## Table of Contents

- [Feature Overview](#feature-overview)
- [Off by Default — What That Means](#off-by-default--what-that-means)
- [Architecture](#architecture)
- [CloudKit Schema](#cloudkit-schema)
- [End-to-End Encryption](#end-to-end-encryption)
- [Archive Tables Involved](#archive-tables-involved)
- [Sync Engine](#sync-engine)
- [Business Logic](#business-logic)
- [UI Components](#ui-components)
- [Edge Cases and Error Handling](#edge-cases-and-error-handling)
- [Testing Approach](#testing-approach)
- [Related Documentation](#related-documentation)

## Feature Overview

| | |
|---|---|
| Transport | CloudKit **private database**, custom zone `BackglanceArchive` |
| Storage cost | user's own iCloud quota (~1 KB per notification record) |
| Encryption | `CKRecord.encryptedValues` for every content field; keys live in the user's iCloud Keychain |
| Default | **OFF**. Nothing CloudKit-related runs until the user turns it on in Settings ▸ Sync |
| Requires | macOS 14+ (`CKSyncEngine`), signed in to iCloud, iCloud Drive/CloudKit enabled for the account |
| Syncs | notifications captured after opt-in (option: include existing archive), read/pinned/deleted flags, rules |
| Does not sync | retention/exclusion settings (device-specific, toggle), embeddings, logs, capture state, redacted originals (they never existed) |

Sync does not make Backglance a cloud service. There is no Backglance server; the only party involved is the user's iCloud account.

## Off by Default — What That Means

When the toggle is off:

- `SyncCoordinator` is never instantiated. No `CKContainer`, no `CKSyncEngine`, no account-status check, no push registration. Zero CloudKit code paths execute.
- The **entitlement is still in the binary**. `com.apple.developer.icloud-services = CloudKit` and `com.apple.developer.icloud-container-identifiers = [iCloud.app.backglance.Backglance]` must be present at signing time (they cannot be added later without re-signing) and Developer ID apps using iCloud must embed a Developer ID provisioning profile. Having the entitlement grants the *ability* to use CloudKit; nothing is exercised at runtime until opt-in.
- Users building from source without an iCloud-capable signing identity can build with `BACKGLANCE_SYNC=0` (an `xcconfig` flag) that compiles the sync module out entirely and strips the entitlement; the Settings ▸ Sync pane then shows "Not available in this build".

> 🔒 **Security:** the privacy guarantee "the only network access is Sparkle" (see [PERMISSIONS_PRIVACY.md](./PERMISSIONS_PRIVACY.md)) stays true unless the user turns sync on. Turning it on adds exactly one more endpoint: iCloud.

## Architecture

```
  Mac A                                                       Mac B
 ┌───────────────────────────┐                        ┌───────────────────────────┐
 │ CaptureEngine → Archive   │                        │ Archive ← CaptureEngine   │
 │        │  (GRDB, local)   │                        │   (GRDB, local)   │       │
 │        ▼                  │                        │                   ▼       │
 │ SyncCoordinator           │                        │           SyncCoordinator │
 │  ├ RecordMapper           │    iCloud private DB   │           RecordMapper ┤  │
 │  │  (encrypt fields)      │   zone BackglanceArchive│      (decrypt fields)  │  │
 │  └ CKSyncEngine ──────────┼──▶ Notification ◀──────┼──────────── CKSyncEngine  │
 │      (macOS 14+)          │    AppSetting          │                           │
 │                           │    Rule                │                           │
 │                           │    Tombstone           │                           │
 └───────────────────────────┘                        └───────────────────────────┘
        ciphertext for title/subtitle/body/sender/deep_link/bundle_id/flags
        cleartext: record name (uuid), delivered_at, modified_at
```

`SyncCoordinator` (in `BackglanceCore/Sync/`) owns one `CKSyncEngine`, observes archive changes with GRDB `ValueObservation`/`DatabaseRegionObservation`, and applies fetched changes back into the archive inside a single write transaction per batch. It never touches the system store.

## CloudKit Schema

Zone: `CKRecordZone.ID(zoneName: "BackglanceArchive", ownerName: CKCurrentUserDefaultName)`.

| Record type | Record name | Cleartext fields | Encrypted fields (`encryptedValues`) |
|---|---|---|---|
| `Notification` | notification `uuid` | `deliveredAt: Date`, `modifiedAt: Date`, `schema: Int` (=1) | `bundleID`, `appName`, `title`, `subtitle`, `body`, `sender`, `threadID`, `category`, `deepLink`, `attachmentsJSON`, `presented: Int`, `missed: Int`, `redaction`, `isRead: Int`, `isPinned: Int`, `isDeleted: Int` |
| `Rule` | `rule-<uuid>` | `modifiedAt` | `kind`, `pattern`, `matchField`, `appBundleID`, `color`, `priority`, `isEnabled` |
| `AppSetting` | `app-<sha256(bundle_id)>` | `modifiedAt` | `bundleID`, `retention`, `isExcluded`, `isMuted`, `redactOTP` — **only uploaded when "Sync per-app settings" is on** |
| `Tombstone` | `tomb-<uuid>` | `deletedAt`, `reason` (`user`/`retention`/`wipe`) | — (contains no content; the uuid is opaque) |

Why `Tombstone` in addition to native record deletions: CloudKit deletions are only delivered to devices that had already fetched the zone. A Mac that turns sync on later, and that captured the same notification itself, would otherwise re-upload it. Tombstones are kept for 90 days and then pruned by the coordinator.

## End-to-End Encryption

`CKRecord.encryptedValues` (macOS 12+) encrypts field values on-device with keys derived from the user's iCloud Keychain before upload; the server stores ciphertext and cannot read them.

**Decision:** *every* content and metadata field is written through `encryptedValues`, including `bundleID`, `appName`, and the `isRead/isPinned/isDeleted` flags. Only three things stay in clear: the record name (the notification `uuid`, an opaque identifier), `deliveredAt`, and `modifiedAt` — timestamps are needed by the conflict policy and by "sync only after opt-in date" without decrypting.

What this protects against:

- Apple (or anyone with server-side access, or a subpoena to the server) reading notification text, sender, app, or link.
- Anyone who obtains a CloudKit dump without the user's iCloud Keychain.

What it does **not** protect against:

- Traffic analysis on what remains in clear: **record counts, delivery timestamps, modification cadence**. Someone with server access can tell *how many* notifications the user receives and *when*, not what they are or from which app.
- A compromised iCloud account with Keychain access (Advanced Data Protection recommended — Backglance shows a one-line hint pointing to it).
- The Macs themselves. Sync moves the archive to another Mac; the archive there has the same protections as the local one (FileVault, `0600`, optional SQLCipher — see [SECURITY.md](../security/SECURITY.md)).

> ⚠️ **Warning:** `encryptedValues` cannot hold `CKAsset` or `CKRecord.Reference` and encrypted fields are not queryable. Neither matters here: attachments are metadata-only JSON, relations are by uuid inside the encrypted payload, and the sync engine uses change fetching, not queries.

## Archive Tables Involved

Migration `v6_sync_metadata` (in `ArchiveMigrations.swift`) adds:

```sql
ALTER TABLE notifications ADD COLUMN sync_record_name TEXT;      -- NULL until first upload
ALTER TABLE notifications ADD COLUMN sync_modified_at REAL;      -- last local flag change (LWW clock)
CREATE INDEX idx_notifications_sync_dirty ON notifications(sync_modified_at) WHERE sync_record_name IS NULL;
ALTER TABLE rules ADD COLUMN sync_record_name TEXT;
ALTER TABLE rules ADD COLUMN sync_modified_at REAL;
-- capture_state keys added: 'sync_enabled', 'sync_opt_in_at', 'sync_zone_change_token',
-- 'sync_last_success_at', 'sync_include_existing', 'sync_app_settings'
```

`sync_zone_change_token` holds the serialized `CKSyncEngine.State.Serialization` (which encapsulates zone/database change tokens and pending changes) as base64 in `capture_state.value`. Sync-related notifications: `notifications.is_deleted` is reused as the tombstone flag locally; hard pruning by the retention job is unchanged (see [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md)).

## Sync Engine

`CKSyncEngine` (macOS 14+) handles scheduling, batching, retries, push subscriptions and change tokens. Backglance supplies records to send and applies fetched changes.

```swift
// BackglanceCore/Sync/SyncCoordinator.swift
import CloudKit
import GRDB
import os

public final class SyncCoordinator: @unchecked Sendable {
    static let containerID = "iCloud.app.backglance.Backglance"
    static let zoneID = CKRecordZone.ID(zoneName: "BackglanceArchive", ownerName: CKCurrentUserDefaultName)
    private let log = Logger(subsystem: "app.backglance.Backglance", category: "sync")

    private let archive: Archive
    private let mapper: RecordMapper
    private var engine: CKSyncEngine!

    public init(archive: Archive) throws {
        self.archive = archive
        self.mapper = RecordMapper(zoneID: Self.zoneID)

        // Restore engine state (change tokens, pending changes) if we have one.
        let saved: CKSyncEngine.State.Serialization? = try archive.pool.read { db in
            guard let b64 = try String.fetchOne(db, sql: "SELECT value FROM capture_state WHERE key = 'sync_zone_change_token'"),
                  let data = Data(base64Encoded: b64) else { return nil }
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        }

        let container = CKContainer(identifier: Self.containerID)
        var config = CKSyncEngine.Configuration(database: container.privateCloudDatabase,
                                                stateSerialization: saved,
                                                delegate: self)
        config.automaticallySync = true
        engine = CKSyncEngine(config)

        // Make sure the zone exists; the engine coalesces this with the next send.
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
    }

    /// Called from the archive observer whenever notifications/rules change locally.
    public func enqueue(notificationUUIDs: [String], deletedUUIDs: [String]) {
        let saves = notificationUUIDs.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(recordName: $0, zoneID: Self.zoneID)) }
        let tombs = deletedUUIDs.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(recordName: "tomb-\($0)", zoneID: Self.zoneID)) }
        let deletes = deletedUUIDs.map { CKSyncEngine.PendingRecordZoneChange.deleteRecord(CKRecord.ID(recordName: $0, zoneID: Self.zoneID)) }
        engine.state.add(pendingRecordZoneChanges: saves + tombs + deletes)
    }

    /// "Reset sync data" and panic wipe: delete the whole zone. Other Macs receive the zone deletion.
    public func deleteZone() async throws {
        engine.state.add(pendingDatabaseChanges: [.deleteZone(Self.zoneID)])
        try await engine.sendChanges()
    }
}

extension SyncCoordinator: CKSyncEngineDelegate {
    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let e):
            persistState(e.stateSerialization)

        case .accountChange(let e):
            switch e.changeType {
            case .signIn:
                log.info("iCloud sign-in; sync continues")
            case .signOut, .switchAccounts:
                // Keep everything local, stop uploading, forget engine state.
                await SyncSettings.disable(reason: .accountChanged, archive: archive)
            @unknown default: break
            }

        case .fetchedRecordZoneChanges(let e):
            do {
                try await archive.pool.write { db in
                    for mod in e.modifications { try self.mapper.apply(mod.record, in: db) }      // decrypt + LWW merge
                    for del in e.deletions { try self.mapper.applyDeletion(del.recordID, in: db) }
                }
            } catch {
                log.error("apply fetched changes failed: \(error.localizedDescription, privacy: .public)")
            }

        case .fetchedDatabaseChanges(let e):
            if e.deletions.contains(where: { $0.zoneID == Self.zoneID }) {
                // Zone was deleted on another Mac (reset or panic wipe): stop syncing, keep local data.
                await SyncSettings.disable(reason: .zoneDeletedRemotely, archive: archive)
            }

        case .sentRecordZoneChanges(let e):
            for saved in e.savedRecords { try? await mapper.markUploaded(saved, archive: archive) }
            for failure in e.failedRecordSaves {
                switch failure.error.code {
                case .serverRecordChanged:
                    // Same uuid exists (dedupe across Macs, or concurrent flag edit): merge LWW and retry.
                    if let server = failure.error.serverRecord {
                        try? await mapper.mergeAndRequeue(local: failure.record, server: server, engine: syncEngine, archive: archive)
                    }
                case .zoneNotFound, .userDeletedZone:
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                case .quotaExceeded:
                    await SyncSettings.setStatus(.quotaExceeded, archive: archive)      // shown in Settings, no retry storm
                default:
                    log.error("save failed: \(failure.error.code.rawValue, privacy: .public)")
                }
            }

        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .didFetchChanges, .willSendChanges, .didSendChanges, .sentDatabaseChanges:
            break
        @unknown default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                          syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            do {
                // Builds an encrypted CKRecord from the archive row, or nil if the row vanished.
                return try await self.mapper.record(for: recordID, archive: self.archive)
            } catch {
                self.log.error("record build failed for \(recordID.recordName, privacy: .private)")
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
        }
    }

    private func persistState(_ s: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? archive.pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO capture_state(key, value) VALUES ('sync_zone_change_token', ?)",
                           arguments: [data.base64EncodedString()])
        }
    }
}
```

`RecordMapper` does the field work:

```swift
// BackglanceCore/Sync/RecordMapper.swift (excerpt)
import CloudKit
import GRDB

struct RecordMapper {
    let zoneID: CKRecordZone.ID

    func record(for id: CKRecord.ID, archive: Archive) async throws -> CKRecord? {
        if id.recordName.hasPrefix("tomb-") { return tombstone(id) }
        guard let row = try await archive.pool.read({ db in
            try Row.fetchOne(db, sql: """
                SELECT n.*, a.bundle_id, a.display_name FROM notifications n
                JOIN apps a ON a.id = n.app_id WHERE n.uuid = ?
                """, arguments: [id.recordName])
        }) else { return nil }

        let rec = CKRecord(recordType: "Notification", recordID: id)
        rec["deliveredAt"] = Date(timeIntervalSince1970: row["delivered_at"]) as CKRecordValue
        rec["modifiedAt"] = Date(timeIntervalSince1970: row["sync_modified_at"] ?? row["captured_at"]) as CKRecordValue
        rec["schema"] = 1 as CKRecordValue
        // Everything below is ciphertext on the server.
        let enc = rec.encryptedValues
        enc["bundleID"] = row["bundle_id"] as String
        enc["appName"] = row["display_name"] as String?
        enc["title"] = row["title"] as String?
        enc["subtitle"] = row["subtitle"] as String?
        enc["body"] = row["body"] as String?              // already redacted if it was an OTP
        enc["sender"] = row["sender"] as String?
        enc["threadID"] = row["thread_id"] as String?
        enc["category"] = row["category"] as String?
        enc["deepLink"] = row["deep_link"] as String?
        enc["attachmentsJSON"] = row["attachments_json"] as String?
        enc["presented"] = (row["presented"] as Int)
        enc["missed"] = ((row["away_session_id"] as Int64?) == nil ? 0 : 1)
        enc["redaction"] = row["redaction"] as String
        enc["isRead"] = row["is_read"] as Int
        enc["isPinned"] = row["is_pinned"] as Int
        enc["isDeleted"] = row["is_deleted"] as Int
        return rec
    }

    /// Fetched record → archive. Content is immutable; only flags can conflict → LWW by modifiedAt, delete wins.
    func apply(_ rec: CKRecord, in db: Database) throws {
        guard rec.recordType == "Notification" else { return try applyOther(rec, in: db) }
        let enc = rec.encryptedValues
        let remoteModified = (rec["modifiedAt"] as? Date) ?? .distantPast
        let remoteDeleted = (enc["isDeleted"] as? Int ?? 0) == 1

        if let local = try Row.fetchOne(db, sql: "SELECT id, sync_modified_at, is_deleted FROM notifications WHERE uuid = ?",
                                        arguments: [rec.recordID.recordName]) {
            let localModified = Date(timeIntervalSince1970: local["sync_modified_at"] ?? 0)
            let localDeleted = (local["is_deleted"] as Int) == 1
            let deleted = localDeleted || remoteDeleted                    // delete wins
            let takeRemote = remoteModified > localModified
            try db.execute(sql: """
                UPDATE notifications SET
                  is_read = CASE WHEN ? THEN ? ELSE is_read END,
                  is_pinned = CASE WHEN ? THEN ? ELSE is_pinned END,
                  is_deleted = ?, sync_record_name = ?, sync_modified_at = MAX(sync_modified_at, ?)
                WHERE id = ?
                """, arguments: [takeRemote, enc["isRead"] as? Int ?? 0,
                                 takeRemote, enc["isPinned"] as? Int ?? 0,
                                 deleted, rec.recordID.recordName, remoteModified.timeIntervalSince1970,
                                 local["id"] as Int64])
        } else {
            let appID = try AppRecord.upsertID(bundleID: enc["bundleID"] as? String ?? "unknown",
                                               displayName: enc["appName"] as? String, in: db)
            try db.execute(sql: """
                INSERT INTO notifications (uuid, app_id, title, subtitle, body, sender, thread_id, category,
                  delivered_at, captured_at, source, presented, deep_link, attachments_json, redaction,
                  is_read, is_pinned, is_deleted, sync_record_name, sync_modified_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'sync', ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [rec.recordID.recordName, appID,
                                 enc["title"] as? String, enc["subtitle"] as? String, enc["body"] as? String,
                                 enc["sender"] as? String, enc["threadID"] as? String, enc["category"] as? String,
                                 (rec["deliveredAt"] as? Date ?? Date()).timeIntervalSince1970,
                                 Date().timeIntervalSince1970,
                                 enc["presented"] as? Int ?? 1, enc["deepLink"] as? String,
                                 enc["attachmentsJSON"] as? String, enc["redaction"] as? String ?? "none",
                                 enc["isRead"] as? Int ?? 0, enc["isPinned"] as? Int ?? 0, remoteDeleted,
                                 rec.recordID.recordName, remoteModified.timeIntervalSince1970])
        }
    }

    private func tombstone(_ id: CKRecord.ID) -> CKRecord {
        let rec = CKRecord(recordType: "Tombstone", recordID: id)
        rec["deletedAt"] = Date() as CKRecordValue
        rec["reason"] = "user" as CKRecordValue
        return rec
    }
}
```

`source = 'sync'` is a new allowed value alongside `'live'` and `'import'` so the timeline can label rows that came from another Mac.

## Business Logic

### Conflict policy

| Object | Conflict surface | Rule |
|---|---|---|
| Notification content | none — content is immutable once captured | first writer's content stays; a `serverRecordChanged` on first upload means "same uuid captured on both Macs" → keep server content, merge flags |
| `is_read`, `is_pinned` | both Macs toggle | last-writer-wins by `modifiedAt` |
| `is_deleted` | one Mac deletes, other toggles | **delete wins** regardless of timestamps |
| Rules | edited on both Macs | LWW by `modifiedAt` per rule; deleted rule wins |
| Per-app settings (`AppSetting`) | retention/exclusion/mute/redact | **not synced by default**; when the "Sync per-app settings" toggle is on, LWW |

### What is synced, and from when

- Default: notifications with `delivered_at ≥ sync_opt_in_at`. Existing archive stays local unless the user picks **Include existing archive** (a one-time backfill, batched 400 records per send, throttled so it does not compete with capture).
- Retention: **decision — retention deletes propagate.** When Mac A's retention job soft-deletes a notification, a `Tombstone` is written and the record is deleted; Mac B applies the deletion even if its own retention would have kept it longer. Rationale: the alternative (per-device retention resurrecting rows) makes "I deleted it" untrue on one Mac. The Settings pane says so: "The shortest retention among your Macs wins."
- Panic wipe: `PanicWipe.execute()` calls `SyncCoordinator.deleteZone()` *before* wiping local files, then disables sync. Other Macs receive the zone deletion, stop syncing, and keep their local copies (a wipe on one Mac is not a remote wipe — the pane says this plainly; wiping every Mac means running the wipe on each).

### What is never synced

- Redacted originals — they were never stored anywhere.
- Embeddings — regenerated locally on the receiving Mac if semantic search is on.
- Logs, `capture_state` (except sync's own keys), cursors, adapter fingerprints, away sessions and digests (they describe *this* Mac's presence).
- Icons (re-resolved locally by `EnrichmentService`).

### Offline and account changes

- Offline: `CKSyncEngine` queues; the archive keeps working; Settings shows "Waiting for network".
- `.accountChange(.signOut)` / `.switchAccounts`: sync is disabled, local data kept, engine state cleared. Re-enabling requires the toggle again (and starts a fresh opt-in date).
- Zone deleted remotely: same as above with status "Sync was reset on another Mac".

## UI Components

Settings ▸ Sync (`SyncSettingsView` in `BackglanceUI`):

| Control | Behavior |
|---|---|
| **Sync with my other Macs via iCloud** toggle | off by default; turning on shows a sheet summarising what is and is not synced and the encryption note, then requests account status |
| Status line | Off / Up to date (last sync 2 min ago) / Syncing… / Waiting for network / Not signed in to iCloud / iCloud storage full / Sync was reset on another Mac |
| **Include existing archive** | one-time backfill (checkbox, only before first sync) |
| **Sync per-app settings** | off by default |
| **Reset sync data…** | deletes the zone (confirmation), keeps local archive, turns sync off on all Macs |
| Menu bar | small cloud glyph in the popover footer while syncing; nothing else |

## Edge Cases and Error Handling

| Case | Handling |
|---|---|
| Same notification captured on two Macs (e.g. iMessage signed in on both, same store uuid) | **decision:** dedupe by store uuid when equal — record name is the uuid, the second upload gets `serverRecordChanged`, flags merge LWW; content is identical anyway |
| Different Macs, different notifications | they are simply different records; the timeline shows a small "from Mac B" caption using the encrypted `origin` device name — **decision:** `origin` field added to `Notification` (encrypted; the user's own Mac name) |
| Notification captured on Mac B before Mac B opted in, deleted on Mac A | tombstone applies on B; the row is soft-deleted and pruned |
| iCloud quota exceeded | status shown, uploads pause; fetching continues; retry when the engine reports success |
| Very large backfill (100k rows) | batched; each batch ≤ 400 records / ≤ 2 MB; progress in the pane; can be cancelled (already-uploaded records stay) |
| Corrupt or future-schema record (`schema` > 1) | skipped and logged (no content in logs); the pane shows "Some records need a newer Backglance" |
| Sync on, then FDA revoked / capture degraded | unrelated; sync keeps working for existing data |
| Archive migrated/wiped while engine has pending changes | `SyncCoordinator` is stopped before `PanicWipe`/migrations run and re-created after |
| Clock skew between Macs | LWW uses each Mac's clock; skew shows up only as "the other Mac's flag won". Documented, not corrected |
| Encrypted field read fails (`encryptedValues` returns nil, e.g. Keychain not yet synced to a fresh Mac) | record applied with empty content and `redaction='none'`, marked `sync_needs_refetch`; refetched on next cycle |

## Testing Approach

- **Unit (no network):** `SyncEngineProtocol` wraps the small surface Backglance uses (`state.add`, `sendChanges`, `fetchChanges`); `InMemorySyncEngine` records pending changes and lets tests inject `CKSyncEngine.Event` values built with `CKRecord`s (constructing `CKRecord`, setting `encryptedValues` and reading them back works without a container). Tests cover: mapper round-trip (row → record → row) for every field, LWW flag merge in both directions, delete-wins, tombstone application, backfill boundary at `sync_opt_in_at`, `serverRecordChanged` merge, zone-deleted-remotely disables sync.
- **Migration:** `v6_sync_metadata` applied on top of a v5 fixture archive; assert columns and index exist and old rows have `sync_record_name IS NULL`.
- **Manual two-Mac checklist (release blocker for the sync milestone):**
  1. Enable on A; capture 20 notifications; enable on B; all 20 appear within 60 s, redacted rows still show `[code redacted]`.
  2. Mark read on A → B updates; pin on B → A updates; delete on A while pinning on B → deleted on both.
  3. Retention 24h on A, 30d on B → row disappears on B after A prunes it.
  4. Panic wipe on A → B shows "Sync was reset on another Mac", B's data intact.
  5. Sign out of iCloud on B → sync off, archive intact; sign in → toggle stays off until re-enabled.
  6. Airplane mode on A for 10 min while capturing → catch-up completes without duplicates.
  7. Inspect a record in CloudKit Console: content fields absent from the cleartext view.
- CI: unit tests only; CloudKit is never contacted from GitHub Actions.

## Related Documentation

- [SECURITY.md](../security/SECURITY.md) — threat model, what encryption covers
- [PERMISSIONS_PRIVACY.md](./PERMISSIONS_PRIVACY.md) — network access guarantee
- [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md) — retention, panic wipe, redaction
- [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md) — `v6_sync_metadata`
- [ARCHITECTURE.md](../architecture/ARCHITECTURE.md)
- [PACKAGING_NOTARIZATION.md](../deployment/PACKAGING_NOTARIZATION.md) — iCloud entitlement, embedded provisioning profile
- [TESTING.md](../testing/TESTING.md)
- [ROADMAP.md](../reference/ROADMAP.md)
