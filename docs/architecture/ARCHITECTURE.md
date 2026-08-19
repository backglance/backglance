# Backglance Architecture

Last Updated: 2026-08-18

This document describes how Backglance is put together: the pipeline that turns rows in Apple's Notification Center database (the **system store**) into notifications in Backglance's own **archive**, the four Swift packages plus the app shell that implement it, the concurrency model, the security posture, and the error-handling and logging conventions every module follows. It is written for contributors who want to change the code and for anyone who wants to check the privacy claims against the actual design. The single most important architectural idea is the **schema-adapter boundary**: capture rides an undocumented database, so everything that touches Apple's schema is isolated behind a small protocol with a fingerprint-based registry and a fixture-driven test suite.

## Table of Contents

- [System Overview](#system-overview)
- [Component Breakdown](#component-breakdown)
  - [BackglanceCapture](#backglancecapture)
  - [BackglanceCore](#backglancecore)
  - [BackglanceSearch](#backglancesearch)
  - [BackglanceUI](#backglanceui)
  - [App Shell (Backglance target)](#app-shell-backglance-target)
  - [Dependency Graph](#dependency-graph)
- [Data Flows](#data-flows)
  - [Live Capture Path](#live-capture-path)
  - [First-Launch Import Path](#first-launch-import-path)
  - [Digest Path](#digest-path)
  - [Search Path](#search-path)
- [Watch Strategy: Poll + DispatchSource + Snapshot](#watch-strategy-poll--dispatchsource--snapshot)
- [The Schema-Adapter Boundary](#the-schema-adapter-boundary)
  - [StoreAdapter Protocol](#storeadapter-protocol)
  - [Fingerprint-First Registry Resolution](#fingerprint-first-registry-resolution)
  - [Degraded Mode](#degraded-mode)
- [CaptureEngine Loop](#captureengine-loop)
- [Concurrency Model](#concurrency-model)
- [Security Architecture Overview](#security-architecture-overview)
- [Error Handling Patterns](#error-handling-patterns)
- [Logging Architecture](#logging-architecture)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## System Overview

Backglance is a menu bar utility with one long-running pipeline and one interactive surface. The pipeline reads from Apple's system store and writes into the archive; the surface reads from the archive only. Nothing in the app ever writes to Apple's files, and nothing leaves the machine except Sparkle update checks (which the user can disable).

```
┌───────────────────────────────────────────────────────────────────────────────┐
│ macOS (usernoted)                                                             │
│   ~/Library/Group Containers/group.com.apple.usernoted/db2/db  (+ -wal, -shm) │
│   ⚠️ undocumented schema · requires Full Disk Access · pruned by the system  │
└───────────────┬───────────────────────────────────────────────────────────────┘
                │ read-only copy of db + wal (never opens Apple's live file for write)
                ▼
┌───────────────────────────────┐   BackglanceCapture
│ StoreLocator / StoreWatcher   │   DispatchSource on -wal + poll (15 s / 60 s low power)
│ StoreSnapshot (immutable)     │   copy → App Support/Backglance/tmp/<uuid>/db
│ StoreFingerprint → Registry   │   fingerprint match → OS fallback → degraded
│ StoreAdapterV14 / V15 / V26   │   SQL against `record` / `app` / `dbinfo`
│ RecordParser (bplist)         │   RawStoreRecord → ParsedNotification
│ EnrichmentService             │   app icon cache, deep link resolution
└───────────────┬───────────────┘
                │ ParsedNotification (in memory)
                ▼
┌───────────────────────────────┐   BackglanceCore
│ OTPRedactor (before insert)   │   `[code redacted]`, RedactionEvent, no original
│ ExclusionList / RulesEngine   │   never-store list · visual triage only
│ Archive (GRDB DatabasePool)   │   ~/Library/Application Support/Backglance/archive.sqlite
│ RetentionJob · AwaySession    │   per-app retention · locked/asleep/focus/presenting
│ DigestEngine · ExportService  │   "what did I miss" · CSV/JSON
└───────────────┬───────────────┘
                │ ValueObservation / async reads
                ▼
┌───────────────────────────────┐   BackglanceSearch
│ FTSIndex (fts5 external)      │   notifications_fts, unicode61, prefix 2 3
│ QueryParser · FuzzyMatcher    │   from:slack before:2026-08-01 invoice
│ SemanticIndex (NLEmbedding)   │   opt-in, on-device 512-dim, cosine top-K
│ HybridSearch                  │   FTS 0.4 · semantic 0.5 · fuzzy 0.3
└───────────────┬───────────────┘
                │ [SearchHit] / [ArchivedNotification]
                ▼
┌───────────────────────────────┐   BackglanceUI + app shell
│ NSStatusItem + NSPopover      │   AppKit shell, ⌃⌥N hotkey, LSUIElement
│ TimelineView · DigestView     │   SwiftUI, @MainActor view models
│ SearchBar · SettingsViews     │   Settings, Onboarding (FDA walkthrough)
│ SparkleUpdaterController      │   only network access, user-disableable
└───────────────────────────────┘
```

Two properties fall out of this shape and are worth stating up front:

- **The archive is the source of truth for the UI.** If capture stops (no FDA, unknown schema, store missing), everything already archived keeps working: timeline, search, digest history, export. This is the "capture paused, archive intact" guarantee referenced throughout the docs.
- **The system store is only ever read from a private copy.** Backglance never holds a write handle on Apple's database and never runs a query on Apple's live file, so it cannot corrupt Notification Center even if a future macOS changes the file format under it.

## Component Breakdown

| Component | Kind | Owns | Depends on |
|---|---|---|---|
| `BackglanceCapture` | Swift package | Locating, watching, snapshotting, fingerprinting, adapting, parsing, enriching the system store | GRDB, `BackglanceCore` (models only) |
| `BackglanceCore` | Swift package | Archive (GRDB), migrations, models, retention, redaction, rules, digest, away sessions, export, panic wipe | GRDB |
| `BackglanceSearch` | Swift package | FTS index, query parsing, fuzzy matching, semantic index, hybrid ranking | GRDB, NaturalLanguage, Accelerate, `BackglanceCore` |
| `BackglanceUI` | Swift package | SwiftUI views shared by popover, window, widgets | SwiftUI, `BackglanceCore`, `BackglanceSearch` |
| `Backglance` | App target | AppKit shell: status item, popover, hotkey, launch at login, URL scheme, Sparkle | All packages, Sparkle |

### BackglanceCapture

Responsibilities:

- `StoreLocation.current()` resolves `~/Library/Group Containers/group.com.apple.usernoted/db2/db` and throws when the directory is absent.
- `StoreWatcher` produces an `AsyncStream<WakeReason>` from a `DispatchSource` on the store's `-wal` and `db` files, a fallback poll timer, and system events (`NSWorkspace.didWakeNotification`, `com.apple.screenIsUnlocked`).
- `StoreSnapshot` copies `db` + `-wal` into `~/Library/Application Support/Backglance/tmp/<uuid>/` and opens the copy read-only.
- `StoreFingerprint.compute(in:)` hashes the store's `sqlite_master` SQL and reads `dbinfo`.
- `StoreAdapterRegistry` picks a `StoreAdapter` (`StoreAdapterV14`, `StoreAdapterV15`, `StoreAdapterV26`).
- `RecordParser` decodes the `record.data` binary plist into `ParsedNotification`.
- `EnrichmentService` attaches app icons (cached in `~/Library/Application Support/Backglance/icons/`) and resolves deep links.
- `CaptureEngine` (an actor) runs the loop and publishes `CaptureStatus`.

> ⚠️ **Warning:** Everything under `Adapters/` and `RecordParser` depends on an undocumented Apple schema. This is what we have observed, not an API. Column names may change in any macOS release; the fingerprint + adapter + fixture strategy exists for that reason. See [The Schema-Adapter Boundary](#the-schema-adapter-boundary) and [OS_COMPATIBILITY_PLAYBOOK.md](./OS_COMPATIBILITY_PLAYBOOK.md).

### BackglanceCore

Responsibilities:

- `Archive` — `final class` wrapping a GRDB `DatabasePool` at `~/Library/Application Support/Backglance/archive.sqlite` (WAL mode, file `0600`, directory `0700`). `Archive.shared` in the app, `Archive(inMemory: true)` in tests.
- `ArchiveMigrations` — `DatabaseMigrator` with `v1_initial`, `v1_fts`, then v1.x migrations (`v2_saved_searches`, `v3_snoozes`, `v4_embeddings`, `v5_sync_metadata`). `eraseDatabaseOnSchemaChange = true` only in DEBUG.
- Models — `ArchivedNotification`, `AppRecord`, `Rule`, `Digest`, `DigestItem`, `RedactionEvent`, `AwaySession`, `CaptureState`, and v1.x `SavedSearch`, `Snooze`, `Embedding`. All are `Codable, FetchableRecord, PersistableRecord`.
- `OTPRedactor` — runs in memory before insert; on by default for `com.apple.MobileSMS` and `com.apple.mail`.
- `ExclusionList` — bundle IDs that are never stored (password managers, `com.apple.Passwords`, Backglance itself).
- `RulesEngine.evaluate(_:rules:) -> Triage` — visual triage only (highlight, pin, mute). Rules never change system delivery.
- `AwaySessionTracker` + `DigestEngine` — detect lock/sleep/Focus/presenting, build one digest per away session.
- `RetentionJob` — prunes by global default (30 days) or per-app override, hard-deletes soft-deleted rows.
- `ExportService`, `SnoozeScheduler`, `PanicWipe`.

### BackglanceSearch

Responsibilities:

- `FTSIndex` — owns the `notifications_fts` external-content FTS5 table and its sync triggers; exposes `match(_:)` returning ranked row IDs with `bm25()` scores.
- `QueryParser` — turns `from:slack before:2026-08-01 invoice` into an FTS `MATCH` string plus structured filters.
- `FuzzyMatcher` — Levenshtein similarity (threshold 0.6) over FTS prefix/trigram candidates; ported from PasteShelf.
- `SemanticIndex` — opt-in; `NLEmbedding.sentenceEmbedding(for: .english)`, batches of 50 in the background, vectors stored as BLOB in `embeddings`.
- `HybridSearch.search(_:) async throws -> [SearchHit]` — merges FTS (0.4), semantic (0.5) and fuzzy (0.3) scores.

### BackglanceUI

Responsibilities:

- `TimelineView`, `NotificationRow`, `DigestView`, `SearchBar`, `SettingsViews` — SwiftUI, no AppKit imports except through small `NSViewRepresentable` shims.
- View models are `@MainActor @Observable` classes that subscribe to GRDB `ValueObservation` streams.
- The same views are hosted three ways: in the `NSPopover`, in the `TimelineWindow`, and (v1.x) in WidgetKit timelines with a reduced data model.

### App Shell (Backglance target)

Responsibilities:

- `BackglanceApp.swift` / `AppDelegate.swift` — `LSUIElement = YES`, no Dock icon, wires `Archive.shared`, `CaptureEngine`, `AwaySessionTracker`, `SparkleUpdaterController`.
- `StatusItemController.swift` — `NSStatusItem` with `NSPopover` hosting an `NSHostingController`; icon reflects `CaptureStatus` (running / paused / degraded).
- `HotKeyCenter.swift` — Carbon `RegisterEventHotKey` wrapper, default ⌃⌥N.
- `LaunchAtLogin.swift` — `SMAppService.mainApp`.
- `URLSchemeHandler.swift` — `backglance://search`, `open`, `digest`, `pause`, `resume` (v1.0) and `export` (v1.x).
- `SparkleUpdaterController.swift` — the only networked component; honours the "Check for updates automatically" toggle.

### Dependency Graph

```
        ┌───────────────────────── Backglance (app) ─────────────────────────┐
        │  AppKit shell · Sparkle · URL scheme · HotKeyCenter · SMAppService │
        └───────┬───────────────┬────────────────┬───────────────────────────┘
                │               │                │
                ▼               ▼                ▼
        BackglanceUI ──▶ BackglanceSearch ──▶ BackglanceCore ◀── BackglanceCapture
                │                │                 │                    │
                └────────────────┴──────► GRDB ◄───┴────────────────────┘
                                          │
                                   system SQLite (FTS5)
```

`BackglanceCapture` depends on `BackglanceCore` only for the `ParsedNotification` and `RedactionEvent` value types and the `Archive` insert API. `BackglanceCore` never imports `BackglanceCapture`, so the archive can be tested, migrated and searched without any system-store code in the process. `BackglanceUI` never imports `BackglanceCapture` either: capture status reaches the UI as a plain `CaptureStatus` value.

## Data Flows

### Live Capture Path

```
usernoted writes ──▶ db2/db, db2/db-wal
                            │
     ┌──────────────────────┼──────────────────────────────┐
     │ DispatchSource       │ poll timer 15 s               │ didWake / screenIsUnlocked
     │ (.write .extend)     │ (60 s in Low Power Mode)      │ (immediate)
     └──────────────────────┴───────────────┬───────────────┘
                                            │ debounce 500 ms
                                            ▼
                         StoreWatcher.wakes : AsyncStream<WakeReason>
                                            ▼
                         CaptureEngine.tick(reason:)                       [actor]
                           1. StoreSnapshot.take(of:)  copy db + wal → tmp/<uuid>/
                           2. snapshot.read { adapter.records(after: cursor) }
                           3. RecordParser.parse(raw)          bplist → ParsedNotification
                           4. ExclusionList.allows(bundleID)   drop, advance cursor
                           5. OTPRedactor.redact(parsed)       in memory, before any write
                           6. EnrichmentService.enrich(clean)  icon cache · deep link
                           7. Archive.insert(...)              notifications, apps,
                                                               redactions (FTS via triggers)
                           8. cursor = adapter.cursor(for: raw); Archive.saveCursor
                           9. snapshot.discard()
                                            ▼
                         ValueObservation(archive) ──▶ TimelineModel (@MainActor)
                                            ▼
                         SwiftUI TimelineView · unread badge on NSStatusItem
```

Notes on the ordering: exclusion and redaction happen before step 7 so excluded apps and original OTP digits never touch disk, not even in the WAL. Cursor persistence happens after the batch so a crash mid-batch re-reads the same records; the unique index on `notifications.store_rec_id` makes the re-insert a no-op.

### First-Launch Import Path

The system prunes its store after clearing and after roughly a week, so an import can only recover whatever still exists. That is stated plainly in onboarding.

```
Onboarding "Import existing notifications?" ──▶ CaptureEngine.importExisting()
                                                       │
                              cursor = StoreCursor.start (rec_id 0), source = 'import'
                                                       │
            ┌──────────────────────────────────────────┴───────────────────────┐
            │  loop:                                                           │
            │    snapshot = StoreSnapshot.take(of:)                            │
            │    batch = adapter.records(after: importCursor, in: db)  (≤ 500) │
            │    parse → exclude → redact → enrich → Archive.insert(source: .import)
            │    duplicates (store_rec_id already archived) are skipped        │
            │    importCursor = adapter.cursor(for: batch.last)                │
            │  until batch.isEmpty                                             │
            └──────────────────────────────────────────────────────────────────┘
                                                       │
                              capture_state.last_import_at = now
                              live cursor is NOT moved (it already points at the tail)
                                                       ▼
                              Onboarding shows "Imported N notifications from the last X days"
```

Budget: 10k store records in under 10 s (see [../deployment/PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md)). Import runs on the `CaptureEngine` actor, so live ticks queue behind it rather than interleaving.

### Digest Path

```
DistributedNotificationCenter          NSWorkspace                     Focus files ⚠️
 com.apple.screenIsLocked/Unlocked     willSleep / didWake             ~/Library/DoNotDisturb/DB/
                 │                          │                          Assertions.json
                 └──────────────┬───────────┴───────────────┬──────────────┘
                                ▼                           │  frontmost app in presenter list
                    AwaySessionTracker (@MainActor)  ◀──────┘  (Keynote, PowerPoint, Zoom, ...)
                                │ start(reason:) / end()
                                ▼
                    away_sessions row (started_at, ended_at, reason)
                                │ on end, if duration ≥ 5 min
                                ▼
                    DigestEngine.build(session:)
                      SELECT notifications WHERE delivered_at BETWEEN started_at AND ended_at
                                             OR presented = 0
                      group by app · VIP rules first · rank
                                │ item_count ≥ 1 ?
                                ▼
                    digests + digest_items rows ──▶ DigestModel ──▶ DigestView banner
                                                          (max one banner per away session)
```

Notifications archived during the session are linked back via `notifications.away_session_id`, so the digest can be re-opened later from the timeline.

### Search Path

```
SearchBar text ──▶ QueryParser.parse("from:slack before:2026-08-01 invoice")
                        │
                        ├─ filters: app = com.tinyspeck.slackmacgap, delivered_at < 2026-08-01
                        └─ terms:   "invoice"
                        ▼
              HybridSearch.search(query)                          [async, off main]
                ├─ FTSIndex.match("invoice*")        bm25 → normalized 0…1      × 0.4
                ├─ FuzzyMatcher over FTS prefix hits Levenshtein ≥ 0.6           × 0.3
                └─ SemanticIndex.topK(embed(q), 50)  cosine (opt-in only)        × 0.5
                        │ merge by notification id, sum weighted scores, apply filters
                        ▼
              [SearchHit] (id, score, snippet) ──▶ SearchModel (@MainActor) ──▶ TimelineView
```

Latency targets: FTS p95 < 50 ms at 100k notifications; hybrid p95 < 250 ms. When semantic search is off (default) the semantic branch is skipped entirely and no embeddings exist on disk.

## Watch Strategy: Poll + DispatchSource + Snapshot

Backglance needs to notice new rows quickly without keeping a CPU-hungry loop alive. Three triggers feed one debounced stream, and every trigger ends in the same read-only snapshot read.

| Trigger | Mechanism | Why |
|---|---|---|
| File change | `DispatchSource.makeFileSystemObjectSource` on `db-wal` and `db` (`.write`, `.extend`, `.rename`, `.delete`) | Sub-second latency; near-zero idle cost |
| Directory change | `DispatchSource` on `db2/` (`.write`, `.rename`, `.delete`) | Re-arms the file sources if usernoted recreates or checkpoints the files, leaving the old descriptors on a dead inode |
| Poll | `DispatchSource.makeTimerSource`, 15 s (60 s in Low Power Mode) | Belt and braces: catches missed events, checkpoints, and edits that do not touch the watched inode |
| Wake / unlock | `NSWorkspace.didWakeNotification`, `com.apple.screenIsUnlocked` | Immediate catch-up when the user comes back |

All triggers are debounced 500 ms before a tick, which keeps idle CPU under 0.1 % even when an app is spamming notifications. The debounce is capped at four intervals, so sustained activity delays a tick rather than cancelling it forever — see [CAPTURE.md](../features/CAPTURE.md#storewatcher).

(The directory watch was originally specified as an `FSEventStream`. A `DispatchSource` on the directory's own descriptor delivers the same signal — an entry under `db2/` appeared, vanished or was renamed — with the primitive the file watches already use, and without the C callback and `Unmanaged` pointer an `FSEventStream` needs. The only thing either mechanism does here is re-arm and wake.)

> ❌ **Don't:** open Apple's live `db` with a normal `DatabaseQueue`. Even a read-only handle participates in the WAL/shm locking protocol on a file we do not own, and a stray write path would be a data-loss risk for the user's Notification Center.

> ✅ **Do:** copy `db` + `db-wal` into a private temp directory and open the copy read-only. The copy is discarded after the tick.

```swift
// Packages/BackglanceCapture/Sources/BackglanceCapture/StoreSnapshot.swift
import Foundation
import GRDB

/// A private, read-only copy of the system store taken for one capture tick.
public struct StoreSnapshot: Sendable {
    public let directory: URL
    public let databaseURL: URL

    /// Copies `db` and `db-wal` (not `-shm`; SQLite rebuilds the wal-index itself)
    /// into ~/Library/Application Support/Backglance/tmp/<uuid>/.
    public static func take(of location: URL) throws -> StoreSnapshot {
        let fm = FileManager.default
        let dir = try SnapshotDirectory.fresh()
        let target = dir.appendingPathComponent("db")
        do {
            try fm.copyItem(at: location, to: target)
            let wal = URL(fileURLWithPath: location.path + "-wal")
            if fm.fileExists(atPath: wal.path) {
                try fm.copyItem(at: wal, to: URL(fileURLWithPath: target.path + "-wal"))
            }
        } catch let error as NSError where isPermissionDenied(error) {
            // The classic "no Full Disk Access" symptom. Matched on the errno underneath
            // (EACCES/EPERM), not on a single Cocoa code: copyItem with an unreadable
            // *source* reports NSFileWriteNoPermissionError (513), attributing the
            // failure to the destination, so a 257-only check never fires here.
            try? fm.removeItem(at: dir)
            throw CaptureError.fullDiskAccessDenied
        } catch {
            try? fm.removeItem(at: dir)
            throw CaptureError.snapshotFailed(underlying: error.localizedDescription)
        }
        return StoreSnapshot(directory: dir, databaseURL: target)
    }

    /// Runs `body` on a read-only connection to the copied file.
    public func read<T>(_ body: (Database) throws -> T) throws -> T {
        var config = Configuration()
        config.readonly = true
        config.label = "backglance.store-snapshot"
        config.prepareDatabase { db in
            // Second line of defence: even if a bug tries to write, SQLite refuses.
            try db.execute(sql: "PRAGMA query_only = 1")
        }
        // A plain path, deliberately NOT `file:…?immutable=1`: immutable makes SQLite
        // skip WAL recovery, which silently hides every row still in the copied -wal —
        // the most recent notifications, and the reason the -wal is copied at all.
        // Building a -shm inside our own 0700 snapshot directory is harmless; Apple's
        // file is never opened. See CAPTURE.md#snapshot-copy.
        let queue = try DatabaseQueue(path: databaseURL.path, configuration: config)
        return try queue.read(body)
    }

    /// Removes the temp directory. Safe to call twice.
    public func discard() {
        try? FileManager.default.removeItem(at: directory)
    }
}
```

`SnapshotDirectory.fresh()` also sweeps any leftover `tmp/<uuid>/` directories older than one hour on each call, so a crash never leaves copies of the system store behind. `PanicWipe` deletes the whole `tmp/` directory as well.

## The Schema-Adapter Boundary

> ⚠️ **Warning:** Backglance reads `~/Library/Group Containers/group.com.apple.usernoted/db2/db`, a private database owned by `usernoted`. Apple documents nothing about it. Everything Backglance knows about tables `dbinfo`, `app`, `record` (and the bplist keys inside `record.data`) comes from fixtures generated on real machines and from public forensics write-ups. Any macOS update can change it. The architecture treats this as a first-class boundary rather than an implementation detail.

The boundary has three parts:

1. **`StoreFingerprint`** — a content hash of the store's DDL plus its `dbinfo` version and the OS version. Computed on every bootstrap and persisted in `capture_state.fingerprint`.
2. **`StoreAdapter`** implementations — one per schema family (`StoreAdapterV14`, `StoreAdapterV15`, `StoreAdapterV26`), each shipped with a synthetic fixture under `Tests/Fixtures/SystemStore/macOS<N>/`.
3. **`StoreAdapterRegistry`** — resolves fingerprint → adapter with an OS-major fallback and a `probe()` sanity check, or returns a degraded reason.

Nothing outside `BackglanceCapture/Adapters/` and `RecordParser` may name a system-store column. That rule is enforced by code review and by a grep in `Scripts/verify_fixture.sh`.

### StoreAdapter Protocol

```swift
// Packages/BackglanceCapture/Sources/BackglanceCapture/StoreAdapter.swift
import Foundation
import GRDB

/// One system-store schema family. Adapters are stateless value types; every
/// query runs against the `Database` handle of a read-only snapshot.
public protocol StoreAdapter: Sendable {
    /// Stable identifier persisted in `capture_state.adapter_id`, e.g. "v26".
    static var id: String { get }
    /// macOS major versions this adapter was written and fixture-tested against.
    static var supportedOS: ClosedRange<Int> { get }
    /// Exact-match test against the fingerprint of the live store.
    static func matches(_ fp: StoreFingerprint) -> Bool
    /// Cheap sanity check on a snapshot: tables present, columns present, readable.
    func probe(_ db: Database) throws -> ProbeResult
    /// Records newer than `cursor`, ascending by rec_id, bounded batch.
    func records(after cursor: StoreCursor, in db: Database) throws -> [RawStoreRecord]
    /// The cursor to persist once `record` has been archived.
    func cursor(for record: RawStoreRecord) -> StoreCursor
}

public enum ProbeResult: Sendable, Equatable {
    case ok(recordCount: Int)
    case unknownSchema(details: String)
    case permissionDenied
    case missingTables([String])
}

public struct StoreCursor: Codable, Sendable, Equatable {
    public var lastRecID: Int64
    public var lastDeliveredDate: Double   // Cocoa reference seconds, as stored by Apple

    public static let start = StoreCursor(lastRecID: 0, lastDeliveredDate: 0)

    public init(lastRecID: Int64, lastDeliveredDate: Double) {
        self.lastRecID = lastRecID
        self.lastDeliveredDate = lastDeliveredDate
    }
}

/// A row from the store's `record` table, untouched. Parsing happens later.
public struct RawStoreRecord: Sendable {
    public let recID: Int64
    public let appIdentifier: String
    public let uuid: UUID
    public let plistData: Data
    public let deliveredDate: Date?
    public let requestDate: Date?
    public let presented: Bool
    public let style: Int?
}
```

A concrete adapter is short (about 80 lines): `matches` checks the fingerprint against the bundled `KnownFingerprints.json` that `Scripts/verify_fixture.sh` regenerates from the fixtures, `probe` verifies that `dbinfo`, `app` and `record` exist with the columns the adapter needs and returns `.permissionDenied` on `SQLITE_AUTH`/`SQLITE_CANTOPEN`, `records(after:in:)` runs one `SELECT ... FROM record JOIN app ... WHERE rec_id > ? ORDER BY rec_id LIMIT 500`, and `cursor(for:)` copies `rec_id` and `delivered_date`. A complete adapter skeleton is in [OS_COMPATIBILITY_PLAYBOOK.md](./OS_COMPATIBILITY_PLAYBOOK.md#template-for-a-new-adapter).

### Fingerprint-First Registry Resolution

Resolution order is deliberate: an exact fingerprint match is trusted; an OS-major fallback is trusted only after `probe()` succeeds; anything else is degraded. The two-step API keeps the pure lookup testable without a database.

```swift
// Packages/BackglanceCapture/Sources/BackglanceCapture/StoreAdapterRegistry.swift
import Foundation
import GRDB

public enum StoreAdapterRegistry {
    /// Newest first: on an OS-major tie, or for an OS newer than anything we
    /// know, the most recent adapter is the best guess.
    public static let adapters: [any StoreAdapter] = [
        StoreAdapterV26(),
        StoreAdapterV15(),
        StoreAdapterV14(),
    ]

    /// Step 1 — pure lookup. Fingerprint match first, then OS-major fallback.
    /// Returns nil when there is no plausible candidate at all.
    public static func resolve(fingerprint fp: StoreFingerprint) -> (any StoreAdapter)? {
        if let exact = adapters.first(where: { type(of: $0).matches(fp) }) {
            return exact
        }
        let major = fp.osVersion.majorVersion
        if let sameOS = adapters.first(where: { type(of: $0).supportedOS.contains(major) }) {
            return sameOS
        }
        // A macOS newer than every adapter (e.g. a 27 beta): try the newest one,
        // but only the probe in step 2 decides whether it is usable.
        if let newest = adapters.first, major > type(of: newest).supportedOS.upperBound {
            return newest
        }
        return nil
    }

    public enum Resolution: Sendable {
        case matched(any StoreAdapter)
        case fallback(any StoreAdapter, note: String)
        case degraded(reason: DegradedReason)
    }

    /// Step 2 — resolution with a probe() sanity check on a read-only snapshot.
    public static func resolve(fingerprint fp: StoreFingerprint, probing db: Database) -> Resolution {
        guard let candidate = resolve(fingerprint: fp) else {
            return .degraded(reason: .unknownSchema(fp))
        }
        let isExact = type(of: candidate).matches(fp)
        do {
            switch try candidate.probe(db) {
            case .ok:
                if isExact { return .matched(candidate) }
                let note = "fingerprint \(fp.schemaHash.prefix(12)) unknown; \(type(of: candidate).id) probe ok"
                return .fallback(candidate, note: note)
            case .permissionDenied:
                return .degraded(reason: .noFullDiskAccess)
            case .missingTables, .unknownSchema:
                return .degraded(reason: .unknownSchema(fp))
            }
        } catch {
            return .degraded(reason: .readError(failureDescription(error)))
        }
    }

    /// A content-free rendering of a probe failure.
    ///
    /// 🔒 Deliberately *not* `String(describing:)`: a `DatabaseError`'s description
    /// carries the failing statement and its arguments, and this string reaches the
    /// file log and the diagnostics export. `StoreSnapshot` narrows its SQLite errors
    /// the same way.
    private static func failureDescription(_ error: Error) -> String {
        guard let dbError = error as? DatabaseError else { return "\(type(of: error))" }
        return "sqlite \(dbError.resultCode.rawValue)"
    }
}
```

The `.fallback` case is the one that matters for a fresh macOS beta: Backglance keeps capturing with the previous adapter, logs the unknown fingerprint once, and the UI shows a small "running on best-effort adapter" note in Settings ▸ Capture. If a later beta breaks the probe, resolution flips to `.degraded` on the next bootstrap. The [OS_COMPATIBILITY_PLAYBOOK.md](./OS_COMPATIBILITY_PLAYBOOK.md) covers what happens then.

### Degraded Mode

```swift
public enum CaptureStatus: Sendable, Equatable {
    case running
    case paused(until: Date?)
    case degraded(DegradedReason)
    case stopped
}

public enum DegradedReason: Sendable, Equatable {
    case noFullDiskAccess
    case storeNotFound
    case unknownSchema(StoreFingerprint)
    case readError(String)
}
```

Degraded is a *state*, not an error. The engine stays alive, keeps listening to the watcher, and retries bootstrap on every wake (so granting FDA in System Settings is picked up within one poll interval, no relaunch). The archive, timeline, search, digests and export keep working on whatever was already captured. The status item icon changes, Settings ▸ Capture explains the reason in one sentence, and nothing nags.

## CaptureEngine Loop

The engine is an actor: one serialized owner of the adapter, the cursor and the status. The watcher stream drives it; the archive receives finished, redacted notifications.

```swift
// Packages/BackglanceCapture/Sources/BackglanceCapture/CaptureEngine.swift
import Foundation
import GRDB
import OSLog
import BackglanceCore

public actor CaptureEngine {
    public private(set) var status: CaptureStatus = .stopped {
        didSet { statusContinuation.yield(status) }
    }
    public nonisolated let statusStream: AsyncStream<CaptureStatus>
    private let statusContinuation: AsyncStream<CaptureStatus>.Continuation

    private let archive: Archive
    private let watcher: StoreWatcher
    private let parser = RecordParser()
    private let redactor: OTPRedactor
    private let exclusions: ExclusionList
    private let enrichment: EnrichmentService
    private let logger = Logger(subsystem: "app.backglance.Backglance", category: "capture")

    private var adapter: (any StoreAdapter)?
    private var cursor: StoreCursor = .start
    private var loopTask: Task<Void, Never>?
    private var autoResumeTask: Task<Void, Never>?

    public init(archive: Archive,
                watcher: StoreWatcher,
                redactor: OTPRedactor = .default,
                exclusions: ExclusionList,
                enrichment: EnrichmentService) {
        self.archive = archive
        self.watcher = watcher
        self.redactor = redactor
        self.exclusions = exclusions
        self.enrichment = enrichment
        let (stream, continuation) = AsyncStream.makeStream(of: CaptureStatus.self)
        self.statusStream = stream
        self.statusContinuation = continuation
    }

    // MARK: Lifecycle

    public func start() async {
        guard loopTask == nil else { return }
        await bootstrapOrDegrade()
        loopTask = Task {
            for await reason in watcher.wakes {
                await tick(reason: reason)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        autoResumeTask?.cancel()
        status = .stopped
    }

    public func pause(until date: Date?) {
        autoResumeTask?.cancel()
        status = .paused(until: date)
        guard let date else { return }
        autoResumeTask = Task {
            let seconds = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await resume()
        }
    }

    public func resume() async {
        autoResumeTask?.cancel()
        guard adapter != nil else {
            await bootstrapOrDegrade()
            return
        }
        // Notifications delivered while paused are intentionally not archived:
        // fast-forward the cursor to the store's current tail.
        do {
            try fastForwardCursor()
            status = .running
        } catch let error as CaptureError {
            status = .degraded(error.degradedReason)
        } catch {
            status = .degraded(.readError("\(type(of: error))"))   // never the description
        }
    }

    // MARK: Bootstrap

    private func bootstrapOrDegrade() async {
        do {
            try bootstrap()
        } catch let error as CaptureError {
            status = .degraded(error.degradedReason)   // engine stays alive, retries on wake
        } catch {
            status = .degraded(.readError("\(type(of: error))"))   // never the description
        }
    }

    private func bootstrap() throws {
        let location = try StoreLocation.current()             // CaptureError.storeNotFound
        let snapshot = try StoreSnapshot.take(of: location)     // .fullDiskAccessDenied / .snapshotFailed
        defer { snapshot.discard() }

        let resolution = try snapshot.read { db -> StoreAdapterRegistry.Resolution in
            let fingerprint = try StoreFingerprint.compute(in: db)
            try archive.saveFingerprint(fingerprint)
            return StoreAdapterRegistry.resolve(fingerprint: fingerprint, probing: db)
        }

        let selected: any StoreAdapter
        switch resolution {
        case .matched(let a):
            selected = a
        case .fallback(let a, let note):
            selected = a
            logger.notice("adapter fallback: \(note, privacy: .public)")
        case .degraded(let reason):
            throw CaptureError.degraded(reason)
        }
        adapter = selected
        try archive.saveAdapterID(type(of: selected).id)
        cursor = try archive.loadCursor() ?? .start
        status = .running
    }

    // MARK: Tick

    private func tick(reason: WakeReason) async {
        if case .degraded = status {
            await bootstrapOrDegrade()   // FDA may have been granted, store may be back
            return
        }
        guard case .running = status, let adapter else { return }

        do {
            let snapshot = try StoreSnapshot.take(of: StoreLocation.current())
            defer { snapshot.discard() }
            let startCursor = cursor
            let batch = try snapshot.read { db in
                try adapter.records(after: startCursor, in: db)
            }
            guard !batch.isEmpty else { return }

            var archived = 0
            for raw in batch {
                await archiveOne(raw, source: .live, archivedCount: &archived)
                cursor = adapter.cursor(for: raw)
            }
            try archive.saveCursor(cursor)
            logger.debug("tick \(reason.rawValue, privacy: .public): \(archived, privacy: .public)/\(batch.count, privacy: .public) archived")
        } catch let error as CaptureError {
            status = .degraded(error.degradedReason)
        } catch {
            status = .degraded(.readError("\(type(of: error))"))   // never the description
        }
    }

    /// Parse → exclude → redact → enrich → insert. Per-record failures are logged
    /// by rec_id only and never stop the batch.
    private func archiveOne(_ raw: RawStoreRecord, source: NotificationSource, archivedCount: inout Int) async {
        do {
            let parsed = try parser.parse(raw)
            guard exclusions.allows(parsed.bundleID) else { return }
            let (clean, redaction) = redactor.redact(parsed)
            let enriched = await enrichment.enrich(clean)
            try archive.insert(enriched, redaction: redaction, storeRecID: raw.recID, source: source)
            archivedCount += 1
        } catch ArchiveError.duplicate {
            // Already archived (import + live overlap). Advance silently.
        } catch let error as CaptureError {
            logger.error("skip rec \(raw.recID, privacy: .public): \(error.logDescription, privacy: .public)")
        } catch let error as ArchiveError {
            logger.error("archive rec \(raw.recID, privacy: .public): \(error.logDescription, privacy: .public)")
        } catch {
            logger.error("rec \(raw.recID, privacy: .public): \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    // MARK: Import

    /// First-launch import. Starts from rec_id 0, tags rows source = 'import',
    /// and leaves the live cursor alone (dedup via notifications.store_rec_id).
    @discardableResult
    public func importExisting() async throws -> Int {
        guard let adapter else { throw CaptureError.degraded(.storeNotFound) }
        var importCursor = StoreCursor.start
        var total = 0
        while true {
            let snapshot = try StoreSnapshot.take(of: StoreLocation.current())
            defer { snapshot.discard() }
            let c = importCursor
            let batch = try snapshot.read { db in try adapter.records(after: c, in: db) }
            if batch.isEmpty { break }
            for raw in batch {
                await archiveOne(raw, source: .import, archivedCount: &total)
                importCursor = adapter.cursor(for: raw)
            }
        }
        try archive.saveLastImport(Date())
        logger.notice("import finished: \(total, privacy: .public) notifications")
        return total
    }

    private func fastForwardCursor() throws {
        guard let adapter else { return }
        let snapshot = try StoreSnapshot.take(of: StoreLocation.current())
        defer { snapshot.discard() }
        var c = cursor
        while true {
            let batch = try snapshot.read { db in try adapter.records(after: c, in: db) }
            guard let last = batch.last else { break }
            c = adapter.cursor(for: last)
        }
        cursor = c
        try archive.saveCursor(c)
    }
}
```

Two details worth calling out:

- **`defer { snapshot.discard() }` inside a loop body** runs at the end of each iteration, so import never holds more than one snapshot on disk.
- **Pause semantics.** While paused the cursor does not move; on resume it is fast-forwarded to the tail so notifications delivered during the pause are never archived. That is what "pause capture" is meant to promise. (Import, by contrast, deliberately starts from zero.)

## Concurrency Model

Backglance is small enough to have a simple rule set. It builds with strict concurrency checking as a goal (`-strict-concurrency=complete`, Swift 5 language mode) so these rules are compiler-enforced wherever the type system can see them.

| Unit | Isolation | Notes |
|---|---|---|
| `CaptureEngine` | `actor` | Sole owner of adapter, cursor, status. One tick at a time; import serializes behind ticks. |
| `EnrichmentService` | `actor` | Icon cache in memory + on disk; `NSWorkspace` calls hop to main internally where AppKit requires it. |
| `SemanticIndex` | `actor` | Background embedding batches of 50; cancellable. |
| `StoreWatcher` | `final class`, `@unchecked Sendable` | Owns a private serial `DispatchQueue`; `DispatchSource` handlers only touch state on that queue; emits via `AsyncStream`. |
| `Archive` | `final class`, `Sendable` | Wraps GRDB `DatabasePool` (WAL): concurrent readers, one writer, GRDB serializes for us. |
| Models | `struct`, `Sendable` | `ArchivedNotification`, `ParsedNotification`, `RawStoreRecord`, etc. |
| `AwaySessionTracker` | `@MainActor final class` | Listens to `NSWorkspace` / `DistributedNotificationCenter`; writes sessions via `Archive`. |
| View models | `@MainActor @Observable final class` | Subscribe to `ValueObservation.values(in:)`; hold only display state. |
| SwiftUI views / AppKit shell | `@MainActor` | Never touch GRDB directly. |

`DatabasePool` is the piece that makes the rest simple: capture writes on the engine's executor, view models read on the pool's reader connections, and `ValueObservation` delivers changes to the main actor without any hand-written locking. Long reads (search, export) use `pool.read` off the main actor; writes go through `pool.write` and are short.

```swift
// Packages/BackglanceUI/Sources/BackglanceUI/Timeline/TimelineModel.swift
import Foundation
import GRDB
import Observation
import BackglanceCore

@MainActor @Observable
public final class TimelineModel {
    public private(set) var rows: [ArchivedNotification] = []
    public private(set) var loadError: String?
    private var observation: Task<Void, Never>?

    public init() {}

    public func start(archive: Archive) {
        observation?.cancel()
        observation = Task {
            let stream = ValueObservation
                .tracking { db in try ArchivedNotification.recent(limit: 200).fetchAll(db) }
                .values(in: archive.pool)
            do {
                for try await batch in stream {
                    rows = batch
                }
            } catch {
                loadError = ArchiveError.observationFailed(String(describing: error)).userMessage
            }
        }
    }

    public func stop() {
        observation?.cancel()
        observation = nil
    }
}

extension ArchivedNotification {
    /// Newest first, soft-deleted rows excluded, first page of 200.
    public static func recent(limit: Int) -> QueryInterfaceRequest<ArchivedNotification> {
        filter(Column("is_deleted") == 0)
            .order(Column("delivered_at").desc)
            .limit(limit)
    }
}
```

> 💡 **Tip:** If you find yourself wanting a lock, you probably want an actor or a `pool.write` block instead. The only `@unchecked Sendable` in the codebase is `StoreWatcher`, and it exists because `DispatchSource` predates Swift concurrency.

## Security Architecture Overview

The full policy lives in [../security/SECURITY.md](../security/SECURITY.md) and [../features/PERMISSIONS_PRIVACY.md](../features/PERMISSIONS_PRIVACY.md). Architecturally, these are the load-bearing decisions:

```
 trust boundary ───────────────────────────────────────────────────────────────
 │  Apple system store (FDA-gated) ──copy──▶ tmp/<uuid>/ (0700, discarded per tick)
 │                                                │ read-only, immutable, query_only
 │                                                ▼
 │  in-memory: parse → exclusion list → OTP redaction   ← nothing before this touches disk
 │                                                ▼
 │  archive.sqlite (0600, dir 0700, WAL)  ·  icons/  ·  embeddings (opt-in)
 │                                                ▼
 │  UI (local)  ·  export (user-initiated, ~/Downloads)  ·  URL scheme (local)
 └─ network: Sparkle appcast + DMG download only (EdDSA-signed, user can disable) ────
```

- **Not sandboxed, and not on the Mac App Store.** Reading the system store needs Full Disk Access, and FDA is incompatible with App Sandbox. Backglance is Developer ID signed, notarized, hardened-runtime, and distributed via GitHub Releases + Homebrew cask.
- **FDA is used for exactly one path.** `StoreLocation.current()` is the only place that returns a URL under `Group Containers`, and `StoreSnapshot.take(of:)` is the only code that opens it. Both are in `BackglanceCapture` and are auditable in a few minutes.
- **Read-only, from a copy.** Three layers: filesystem copy, `Configuration.readonly = true`, `PRAGMA query_only = 1`.
- **Redaction and exclusion happen in memory before insert.** Original OTP digits are never written anywhere, including logs and the WAL. `redactions` stores only `kind` and `pattern_id`.
- **At-rest.** v1.0 relies on FileVault plus `0600` file permissions in an own `0700` directory. SQLCipher via `GRDB.swift/SQLCipher` with the key in Keychain is a v1.x option, not a v1.0 promise.
- **Only network access is Sparkle.** No telemetry, no crash reporter, no analytics, no accounts. The updater can be turned off in Settings ▸ Updates; the appcast is EdDSA-signed with `SUPublicEDKey` in `Info.plist`.
- **Panic wipe** closes the pool, enables `PRAGMA secure_delete`, deletes archive + WAL + SHM + icons + tmp + embeddings, and recreates an empty archive. Typed "wipe" confirmation, Touch ID when available.
- **URL scheme is local and narrow.** `backglance://` handlers validate arguments, never accept file paths, and `export` (v1.x) asks for confirmation.

> 🔒 **Security:** The exclusion list (password managers, `com.apple.Passwords`, Backglance itself) is checked by bundle ID *before* redaction and *before* insert. An excluded app's notification exists in Backglance's memory for the duration of one `archiveOne` call and nowhere else.

## Error Handling Patterns

Every module defines one typed error enum, errors carry only identifiers and reasons (never content), and anything the user can act on becomes a *state* the UI renders rather than an alert.

| Module | Error type | Surfaced as |
|---|---|---|
| `BackglanceCapture` | `CaptureError` | `CaptureStatus.degraded(DegradedReason)`; status item icon + Settings ▸ Capture |
| `BackglanceCore` | `ArchiveError` | `ArchiveHealth` banner in the timeline; migration failure blocks launch with a plain dialog |
| `BackglanceSearch` | `SearchError` | Inline "search unavailable" row; falls back to FTS-only when semantic index errors |
| App shell | `ShellError` | Hotkey registration failure → Settings ▸ Shortcuts note; Sparkle errors → Sparkle's own UI |

```swift
// Packages/BackglanceCapture/Sources/BackglanceCapture/CaptureError.swift
import Foundation

public enum CaptureError: Error, Sendable {
    case fullDiskAccessDenied
    case storeNotFound(URL)
    case snapshotFailed(underlying: String)
    case degraded(DegradedReason)
    case parseFailed(recID: Int64, reason: String)
    case readFailed(String)

    /// The state the engine moves into. Content-free by construction.
    public var degradedReason: DegradedReason {
        switch self {
        case .fullDiskAccessDenied:
            return .noFullDiskAccess
        case .storeNotFound:
            return .storeNotFound
        case .snapshotFailed(let s), .readFailed(let s):
            return .readError(s)
        case .degraded(let reason):
            return reason
        case .parseFailed(let id, let reason):
            return .readError("rec \(id): \(reason)")
        }
    }

    /// Safe for the file log and os_log with privacy: .public.
    public var logDescription: String {
        switch self {
        case .fullDiskAccessDenied: return "full disk access denied"
        case .storeNotFound(let url): return "store not found at \(url.lastPathComponent)"
        case .snapshotFailed(let s): return "snapshot failed: \(s)"
        case .degraded(let r): return "degraded: \(r)"
        case .parseFailed(let id, let reason): return "parse failed rec \(id): \(reason)"
        case .readFailed(let s): return "read failed: \(s)"
        }
    }
}
```

```swift
// Packages/BackglanceCore/Sources/BackglanceCore/ArchiveError.swift
import Foundation

public enum ArchiveError: Error, Sendable {
    case openFailed(path: String, underlying: String)
    case migrationFailed(name: String, underlying: String)
    case duplicate                                   // store_rec_id or uuid already archived
    case insertFailed(uuid: UUID, underlying: String)
    case integrityCheckFailed(String)
    case observationFailed(String)
    case wipeIncomplete(remaining: [String])

    public var logDescription: String {
        switch self {
        case .openFailed(let path, let u): return "open failed (\(path)): \(u)"
        case .migrationFailed(let name, let u): return "migration \(name) failed: \(u)"
        case .duplicate: return "duplicate"
        case .insertFailed(let uuid, let u): return "insert \(uuid.uuidString) failed: \(u)"
        case .integrityCheckFailed(let s): return "integrity: \(s)"
        case .observationFailed(let s): return "observation: \(s)"
        case .wipeIncomplete(let remaining): return "wipe incomplete: \(remaining.joined(separator: ", "))"
        }
    }

    /// One plain sentence for the UI. No paths, no SQL.
    public var userMessage: String {
        switch self {
        case .openFailed: return "Backglance couldn't open its archive."
        case .migrationFailed: return "Backglance couldn't upgrade its archive. Your data is untouched."
        case .duplicate: return "Already archived."
        case .insertFailed: return "A notification couldn't be saved."
        case .integrityCheckFailed: return "The archive failed an integrity check."
        case .observationFailed: return "The timeline stopped updating. Reopen the window to retry."
        case .wipeIncomplete: return "Some files couldn't be removed. See the log for details."
        }
    }
}
```

Conventions:

- **Success and failure paths are both explicit.** `probe()` returns a `ProbeResult`, not a thrown error, because "unknown schema" is an expected outcome. Thrown errors are reserved for I/O failures.
- **Per-record failures never fail the batch.** A record that fails to parse is logged by `rec_id` and skipped; the cursor still advances past it.
- **Degraded states are values in the UI**, rendered by `CaptureStatusView` and `ArchiveHealthView`. There are no modal alerts on the capture path.
- **`ArchiveError.duplicate` is not logged at error level.** It is the normal outcome of import + live overlap.

## Logging Architecture

Logging is redaction-first: the log format is designed so that it is *impossible* to leak notification content by accident, not merely discouraged.

- `os.Logger(subsystem: "app.backglance.Backglance", category: ...)` with categories `capture`, `archive`, `search`, `digest`, `ui`, `updater`.
- A local rotating file log at `~/Library/Logs/Backglance/backglance.log` (max 5 files × 2 MB), written by `FileLogSink` from the same call sites.
- Interpolated values are limited to: counts, durations, `rec_id`, notification `uuid`, adapter id, fingerprint prefix, error `logDescription`, bundle IDs. **Never** `title`, `subtitle`, `body`, `sender`, `userInfo`, deep links, or attachment names.
- Bundle IDs are `privacy: .private` in `os_log` (they reveal installed apps) but do appear in the local file log, which stays on disk and is only ever shared by the user's own choice.
- Log lines about the store never include SQL text or file paths beyond the last path component.

```swift
// Packages/BackglanceCore/Sources/BackglanceCore/Logging/Log.swift
import Foundation
import OSLog

public enum Log {
    public static let subsystem = "app.backglance.Backglance"

    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let archive = Logger(subsystem: subsystem, category: "archive")
    public static let search  = Logger(subsystem: subsystem, category: "search")
    public static let digest  = Logger(subsystem: subsystem, category: "digest")
    public static let ui      = Logger(subsystem: subsystem, category: "ui")
    public static let updater = Logger(subsystem: subsystem, category: "updater")
}

// Usage: only identifiers, counts and error descriptions are interpolated.
//   Log.capture.info("archived \(uuid.uuidString, privacy: .public)")
```

`FileLogSink` does not read the unified log back (that would need extra entitlements). Each `Log` call site is a thin wrapper that writes once to `os_log` and once to the file sink; the file sink only ever receives strings that were already built under the no-content rule, so it cannot leak what the call site never had. See [../operations/MONITORING_LOGGING.md](../operations/MONITORING_LOGGING.md) for rotation and how to attach a log to a bug report.

## Next Steps

- Read [DATABASE_SCHEMA.md](./DATABASE_SCHEMA.md) for the archive DDL, indexes and migrations.
- Read [OS_COMPATIBILITY_PLAYBOOK.md](./OS_COMPATIBILITY_PLAYBOOK.md) for what happens when Apple changes the store, and how a new adapter ships.
- Read [TECH_STACK.md](./TECH_STACK.md) for why the stack looks the way it does.
- Read [../features/CAPTURE.md](../features/CAPTURE.md) for the user-facing behaviour of the pipeline described here.

## Related Documentation

- [TECH_STACK.md](./TECH_STACK.md)
- [DATABASE_SCHEMA.md](./DATABASE_SCHEMA.md)
- [OS_COMPATIBILITY_PLAYBOOK.md](./OS_COMPATIBILITY_PLAYBOOK.md)
- [../api/API_DOCUMENTATION.md](../api/API_DOCUMENTATION.md)
- [../features/CAPTURE.md](../features/CAPTURE.md)
- [../features/PERMISSIONS_PRIVACY.md](../features/PERMISSIONS_PRIVACY.md)
- [../features/SEARCH.md](../features/SEARCH.md)
- [../features/MISSED_DIGEST.md](../features/MISSED_DIGEST.md)
- [../features/PRIVACY_CONTROLS.md](../features/PRIVACY_CONTROLS.md)
- [../security/SECURITY.md](../security/SECURITY.md)
- [../operations/MONITORING_LOGGING.md](../operations/MONITORING_LOGGING.md)
- [../deployment/PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md)
- [../testing/TESTING.md](../testing/TESTING.md)
- [../getting-started/DEVELOPMENT_GUIDE.md](../getting-started/DEVELOPMENT_GUIDE.md)
- [../../README.md](../../README.md)
