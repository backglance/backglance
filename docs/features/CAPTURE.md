# Capture

Last Updated: 2026-08-18

This document describes continuous capture: how Backglance notices every notification that reaches Notification Center, copies it into its own local archive the moment it arrives, and keeps it there after the banner is dismissed, after the Mac restarts, and after the user clears Notification Center. It also covers the one-time late import on first launch, why that import can only recover "whatever the system still had", the pause semantics, every failure mode we know about, and how the whole thing is tested against synthetic fixtures. Capture is the one part of Backglance that reads an undocumented Apple database, so the fragile parts are marked ⚠️ throughout.

## Table of Contents

- [Feature Overview](#feature-overview)
- [Architecture](#architecture)
- [Archive Tables Involved](#archive-tables-involved)
- [UI Components](#ui-components)
- [Business Logic](#business-logic)
  - [StoreLocation](#storelocation)
  - [StoreWatcher](#storewatcher)
  - [Snapshot copy](#snapshot-copy)
  - [Adapter: StoreAdapterV26.records(after:)](#adapter-storeadapterv26recordsafter)
  - [RecordParser](#recordparser)
  - [Exclusion before parse](#exclusion-before-parse)
  - [Redaction, triage, enrichment](#redaction-triage-enrichment)
  - [Dedupe and thread updates](#dedupe-and-thread-updates)
  - [Cursor persistence](#cursor-persistence)
  - [CaptureEngine](#captureengine)
  - [Pause semantics](#pause-semantics)
  - [First-launch import](#first-launch-import)
- [Edge Cases and Error Handling](#edge-cases-and-error-handling)
- [Metrics and Logging](#metrics-and-logging)
- [Testing Approach](#testing-approach)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Feature Overview

macOS keeps delivered notifications in a private SQLite database owned by `usernoted` (the **system store**) and throws rows away when the user clears Notification Center and, on its own schedule, after roughly a week. Backglance's capture loop watches that store for new rows and archives each one locally, so:

| Event | What macOS does | What Backglance does |
|---|---|---|
| Banner dismissed | Notification stays in the store until cleared or pruned | Already archived; nothing changes |
| Notification Center cleared | Rows deleted from the store | Archive untouched; the notification stays searchable |
| Mac restarts / Backglance relaunched | Store persists; new rows accumulate | Cursor persisted in the archive; capture resumes from where it left off |
| System prunes old rows | Rows gone for good | Archive keeps them until the retention policy (default 30 days) removes them |
| First launch of Backglance | Store contains "whatever is left" | Optional late import of those rows, tagged `source = 'import'` |

Capture is a background loop with a small footprint (idle CPU under 0.1 %, poll every 15 s, DispatchSource wake with 500 ms debounce). It runs whenever the app runs and has Full Disk Access; without FDA it sits in a degraded state and retries quietly on every wake (see [PERMISSIONS_PRIVACY.md](./PERMISSIONS_PRIVACY.md)).

> ⚠️ **Warning:** Everything under `Packages/BackglanceCapture/Sources/BackglanceCapture/Adapters/` and `RecordParser` reads `~/Library/Group Containers/group.com.apple.usernoted/db2/db`, an undocumented system database. This is what we have observed, not an API. Column names may change in any macOS release; the fingerprint + adapter + fixture strategy exists for that reason. See [../architecture/OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md).

> ℹ️ **Info:** The late import is limited by design of the *system*, not of Backglance. If the user cleared Notification Center yesterday, yesterday's rows are gone before Backglance ever runs. Onboarding says exactly that: "This is all the system still had."

## Architecture

```
  usernoted ──writes──▶ ~/Library/Group Containers/group.com.apple.usernoted/db2/db  (+ -wal, -shm)
                                             │
             ┌───────────────────────────────┼─────────────────────────────────┐
             │ StoreLocation.current()       │                                 │
             │ resolves the path once,       │                                 │
             │ throws .storeNotFound         │                                 │
             └───────────────────────────────┼─────────────────────────────────┘
                                             ▼
   ┌───────────────────────────── StoreWatcher (serial DispatchQueue) ─────────────────────────────┐
   │  DispatchSource on db + db-wal   │  DispatchSourceTimer 15 s   │ NSWorkspace.didWake        │
   │  (.write .extend .rename .delete)│  (60 s in Low Power Mode)   │ com.apple.screenIsUnlocked │
   └──────────────────────────────────┴───────────────┬─────────────┴────────────────────────────┘
                                                      │ debounce 500 ms → AsyncStream<WakeReason>
                                                      ▼
   ┌────────────────────────────── CaptureEngine (actor) — one tick at a time ────────────────────┐
   │ 1. StoreSnapshot.take(of:)      copy db + db-wal → ~/Library/Application Support/Backglance/ │
   │                                 tmp/<uuid>/ (APFS clone, ms) — never touch Apple's live file │
   │ 2. snapshot.read { }            GRDB DatabaseQueue, readonly + query_only, plain path        │
   │ 3. adapter.tail(in:)            store reset? (tail.rec_id < cursor.rec_id) → reset cursor    │
   │ 4. adapter.records(after:)      SELECT … FROM record JOIN app USING(app_id)                  │
   │                                 WHERE rec_id > ? ORDER BY rec_id LIMIT 500                    │
   │ 5. ExclusionList.allows(raw.appIdentifier)   ── excluded → drop, never parse the bplist       │
   │ 6. RecordParser.parse(raw)      bplist → ParsedNotification (tolerant keys)                   │
   │ 7. OTPRedactor.redact(parsed)   in memory; digits never reach disk                            │
   │ 8. RulesEngine.evaluate(…)      triage (highlight / pin / mute) — visual only                 │
   │ 9. EnrichmentService.enrich(…)  app icon cache · deep link                                    │
   │10. Archive.insertOrUpdate(…)    dedupe on store_rec_id, then uuid (update, not insert)        │
   │11. cursor = adapter.cursor(for: last); Archive.saveCursor  →  capture_state['cursor']         │
   │12. snapshot.discard()                                                                         │
   └───────────────────────────────────────────────┬──────────────────────────────────────────────┘
                                                   ▼
                     GRDB ValueObservation ──▶ TimelineStore (@MainActor) ──▶ TimelineView, badge
```

Three properties of this pipeline are load-bearing:

1. **Never open Apple's live file.** Every read goes through a private copy. Even a read-only handle on the live database would participate in the WAL locking protocol on a file we do not own.
2. **Nothing sensitive is written before it is filtered.** Exclusion happens on the raw row (step 5) before the plist is even decoded; OTP redaction happens in memory (step 7) before the insert. Neither the excluded app's payload nor the original digits ever hit the archive, its WAL, or a log.
3. **Idempotent by construction.** The cursor advances after the batch is written. A crash between insert and cursor save re-reads the same rows; the unique index on `notifications.store_rec_id` turns the re-insert into a no-op.

> ⚠️ **Warning:** Steps 3, 4 and 6 are the only places that know a system-store column or plist key. Keeping them behind the `StoreAdapter` protocol is what lets a macOS point release break one adapter instead of the app. `Scripts/verify_fixture.sh` greps for `rec_id`, `delivered_date` and `usernoted` outside `Adapters/` and `RecordParser.swift` and fails CI when it finds any.

## Archive Tables Involved

Capture writes to four tables. Full DDL and the `UnixDate` wrapper are in [../architecture/DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md).

| Table | Written by capture | Columns that matter here |
|---|---|---|
| `notifications` | insert or update per record | `uuid` (from the store, else generated), `store_rec_id` (nullable, unique when present), `source` (`'live'` or `'import'`), `presented` (the store's own "banner was shown" flag), `delivered_at`, `captured_at`, `redaction`, `attachments_json` (metadata only) |
| `apps` | find-or-create per bundle ID | `bundle_id`, `display_name`, `first_seen_at`, `last_seen_at`, `notification_count`; `is_excluded` is *read* (exclusion list) |
| `redactions` | one row per `RedactionEvent` | `kind = 'otp'`, `pattern_id`; never the original text |
| `capture_state` | key/value | `cursor` (JSON `StoreCursor`), `fingerprint` (JSON `StoreFingerprint`), `adapter_id` (`"v14"`, `"v15"`, `"v26"`), `last_import_at` (Unix seconds) |

```sql
-- What a healthy capture_state looks like after first launch on macOS 26.
SELECT key, value FROM capture_state ORDER BY key;
-- adapter_id     | v26
-- cursor         | {"lastRecID":48211,"lastDeliveredDate":776120441.28}
-- fingerprint    | {"schemaHash":"7d1c…","dbinfoVersion":"17","osVersion":{"majorVersion":26,"minorVersion":5,"patchVersion":0}}
-- last_import_at | 1755436800
```

`notifications_fts` is maintained by triggers (`notifications_ai/_ad/_au`), so capture never writes to it directly. `apps.notification_count` is bumped in the same write transaction as the insert.

## UI Components

Capture has almost no UI of its own; it publishes a `CaptureStatus` and the shell renders it.

| Component | Module / file | Role |
|---|---|---|
| Status item icon | `Backglance/App/StatusItemController.swift` | Template image per status: normal (`.running`), pause glyph (`.paused`), `eye.slash` variant (`.degraded`) with a one-line tooltip |
| Pause menu | `StatusItemController` right-click menu + `MenuBarPopoverView` toolbar | "Pause capture ▸ 15 minutes / 1 hour / Until tomorrow / Indefinitely", "Resume capture" |
| `CaptureStatusView` | `Packages/BackglanceUI/Sources/BackglanceUI/Settings/CaptureStatusView.swift` | Settings ▸ Capture: status sentence, adapter id, "best-effort adapter" note on fallback, last tick time, counts (see [Metrics and Logging](#metrics-and-logging)) |
| Settings ▸ Capture toggles | `SettingsViews` | "Import notifications received while paused" (default off), "Poll interval" is *not* exposed (fixed 15 s / 60 s) |
| `ImportProgressView` | `Backglance/Scenes/Onboarding/ImportProgressView.swift` | First-launch import: determinate progress when the probe returned a count, "Imported N notifications from the last X days — this is all the system still had" on completion |
| Degraded banner | `MenuBarPopoverView` | Persistent, non-modal banner: "Backglance can't read notifications yet — Grant Full Disk Access…" (see [PERMISSIONS_PRIVACY.md](./PERMISSIONS_PRIVACY.md#degraded-mode-without-fda)) |

> ✅ **Do:** render capture state as a value (`CaptureStatus`) in one place. There are no modal alerts on the capture path — degraded is a state, not an error.

## Business Logic

### StoreLocation

```swift
// Packages/BackglanceCapture/Sources/BackglanceCapture/Store/StoreLocation.swift
import Foundation

public enum StoreLocation {
    /// Apple's Notification Center database. Requires Full Disk Access to read.
    /// ⚠️ Undocumented path; observed on macOS 11–26.
    public static func current() throws -> URL {
        try resolve(environment: ProcessInfo.processInfo.environment,
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    static let relativePath = "Library/Group Containers/group.com.apple.usernoted/db2/db"

    /// `BACKGLANCE_STORE_PATH` is consulted in DEBUG builds only.
    static let honoursStorePathOverride: Bool = {
        #if DEBUG
            true
        #else
            false
        #endif
    }()

    static func resolve(environment: [String: String],
                        homeDirectory: URL,
                        honoursOverride: Bool = honoursStorePathOverride,
                        fileManager: FileManager = .default) throws -> URL {
        if honoursOverride,
           let override = environment["BACKGLANCE_STORE_PATH"],
           !override.isEmpty, (override as NSString).isAbsolutePath {
            // A fixture is our own file, so its existence *can* be checked directly: no
            // FDA stands between us and it, and a typo should say so here.
            let url = URL(fileURLWithPath: override)
            guard fileManager.fileExists(atPath: url.path) else {
                throw CaptureError.storeNotFound(url)
            }
            return url
        }

        let url = homeDirectory.appendingPathComponent(relativePath)
        // Only the *directory* is checked here. `fileExists` on the db file itself is
        // unreliable without FDA (it can report false), and the snapshot copy gives a
        // precise errno anyway — which is what distinguishes `noFullDiskAccess` from
        // `storeNotFound`.
        var isDir: ObjCBool = false
        let dir = url.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw CaptureError.storeNotFound(url)
        }
        return url
    }
}
```

A namespace enum rather than a `struct`, matching `ArchivePaths`; `resolve(...)` is an internal seam so tests can exercise the override, the default branch and both build configurations without mutating the process environment or depending on what exists under the test runner's `~`. An empty or relative `BACKGLANCE_STORE_PATH` is ignored rather than trapped, so a misconfigured environment degrades to the real store — the same rule `ArchivePaths` applies to `BACKGLANCE_ARCHIVE_PATH`.

### StoreWatcher

Three triggers, one debounced stream. The watcher owns a private serial queue; `DispatchSource` handlers only touch state on that queue.

```swift
// Packages/BackglanceCapture/Sources/BackglanceCapture/StoreWatcher.swift
import AppKit
import Foundation
import OSLog

public enum WakeReason: String, Sendable {
    case fileChanged, poll, didWake, screenUnlocked, manual
}

public final class StoreWatcher: @unchecked Sendable {
    public let wakes: AsyncStream<WakeReason>

    private let continuation: AsyncStream<WakeReason>.Continuation
    private let queue = DispatchQueue(label: "app.backglance.Backglance.store-watcher", qos: .utility)
    private let location: URL
    private let logger = Logger(subsystem: "app.backglance.Backglance", category: "watcher")

    private var fileSources: [DispatchSourceFileSystemObject] = []
    private var pollTimer: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    public init(location: URL) {
        self.location = location
        let (stream, continuation) = AsyncStream.makeStream(of: WakeReason.self,
                                                            bufferingPolicy: .bufferingNewest(1))
        self.wakes = stream
        self.continuation = continuation
    }

    deinit { continuation.finish() }

    // MARK: Lifecycle

    public func start() {
        queue.async { [self] in
            armFileSources()
            armPollTimer()
            armSystemEvents()
        }
    }

    public func stop() {
        queue.async { [self] in
            fileSources.forEach { $0.cancel() }
            fileSources.removeAll()
            pollTimer?.cancel()
            pollTimer = nil
            pending?.cancel()
            let ws = NSWorkspace.shared.notificationCenter
            workspaceObservers.forEach { ws.removeObserver($0) }
            workspaceObservers.removeAll()
            let dnc = DistributedNotificationCenter.default()
            distributedObservers.forEach { dnc.removeObserver($0) }
            distributedObservers.removeAll()
        }
    }

    /// Manual trigger (Settings ▸ Capture ▸ "Check now", URL scheme resume).
    public func poke() {
        queue.async { [self] in scheduleWake(.manual, immediate: true) }
    }

    /// 15 s normally, 60 s in Low Power Mode. Re-read on every arm.
    private var pollInterval: TimeInterval {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 60 : 15
    }

    // MARK: Triggers

    private func armFileSources() {
        fileSources.forEach { $0.cancel() }
        fileSources.removeAll()
        for path in [location.path, location.path + "-wal"] {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else {
                // No FDA, or the -wal does not exist right now. The poll timer covers us;
                // the engine reports the precise reason from the snapshot copy.
                logger.notice("watch \(URL(fileURLWithPath: path).lastPathComponent, privacy: .public) unavailable, errno \(errno, privacy: .public)")
                continue
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .rename, .delete],
                queue: queue)
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                if source.data.contains(.rename) || source.data.contains(.delete) {
                    // usernoted checkpointed or recreated the file. Our fd points at the old
                    // inode; re-arm on the new one after the tick had a chance to run.
                    self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.armFileSources() }
                }
                self.scheduleWake(.fileChanged)
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            fileSources.append(source)
        }
    }

    private func armPollTimer() {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = pollInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.scheduleWake(.poll) }
        timer.resume()
        pollTimer = timer
    }

    private func armSystemEvents() {
        let ws = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification,
                                                 object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.scheduleWake(.didWake, immediate: true) }
        })
        // Low Power Mode flips the poll interval; re-arm the timer.
        workspaceObservers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.armPollTimer() }
        })
        let dnc = DistributedNotificationCenter.default()
        distributedObservers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                                    object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.scheduleWake(.screenUnlocked, immediate: true) }
        })
    }

    // MARK: Debounce

    /// Coalesces bursts (an app posting 50 notifications in a second) into one tick.
    private func scheduleWake(_ reason: WakeReason, immediate: Bool = false) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.continuation.yield(reason)
        }
        pending = item
        queue.asyncAfter(deadline: .now() + (immediate ? 0 : 0.5), execute: item)
    }
}
```

> 💡 **Tip:** `bufferingPolicy: .bufferingNewest(1)` means the engine can never fall behind the watcher. If a tick is still running when the next wake arrives, exactly one wake is queued, and that one wake reads everything that accumulated.

### Snapshot copy

The copy is cheap: `FileManager.copyItem` uses `copyfile(3)` with `COPYFILE_CLONE`, so on APFS a 150 MB store becomes a copy-on-write clone in a few milliseconds. The `-wal` is copied so uncheckpointed rows (the most recent ones — exactly the ones we want) are visible. The `-shm` is deliberately *not* copied: it is a live wal-index belonging to another process, and a stale one could point at WAL frames that our copy does not contain. SQLite rebuilds the wal-index from the copied `-wal` on open.

> ⚠️ **Warning:** Do not match the Full Disk Access denial on `NSFileReadNoPermissionError` (257) alone. `FileManager.copyItem` with a *source* it cannot read reports `NSFileWriteNoPermissionError` (**513**), attributing the failure to the destination and wording the message that way ("you don't have permission to access &lt;destination&gt;"). A 257-only check never fires on this path, so every FDA-denied user would be shown a generic `readError` instead of the one fix that works. `StoreSnapshot.isPermissionDenied(_:)` accepts either Cocoa code and decides on the `EACCES`/`EPERM` at the bottom of the `NSUnderlyingError` chain. The destination is a directory Backglance created moments earlier at `0700`, so a denial on this copy has no plausible cause other than the source.

```swift
// Packages/BackglanceCapture/Sources/BackglanceCapture/StoreSnapshot.swift
import Foundation
import GRDB

/// A private, read-only copy of the system store taken for one capture tick or import batch.
public struct StoreSnapshot: Sendable {
    public let directory: URL
    public let databaseURL: URL

    public static func take(of location: URL) throws -> StoreSnapshot {
        let fm = FileManager.default
        let dir = try SnapshotDirectory.fresh()          // …/Backglance/tmp/<uuid>/ (0700), sweeps stale dirs
        let target = dir.appendingPathComponent("db")
        do {
            try fm.copyItem(at: location, to: target)
            let wal = URL(fileURLWithPath: location.path + "-wal")
            if fm.fileExists(atPath: wal.path) {
                try fm.copyItem(at: wal, to: URL(fileURLWithPath: target.path + "-wal"))
            }
        } catch let error as NSError where isPermissionDenied(error) {
            try? fm.removeItem(at: dir)
            throw CaptureError.fullDiskAccessDenied              // EACCES/EPERM under Cocoa 257 *or* 513
        } catch let error as NSError where isNoSuchFile(error) {
            try? fm.removeItem(at: dir)
            throw CaptureError.storeNotFound(location)
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
            try db.execute(sql: "PRAGMA query_only = 1")     // belt and braces
        }
        // A plain path, NOT file:…?immutable=1 — see the warning below.
        do {
            let queue = try DatabaseQueue(path: databaseURL.path, configuration: config)
            return try queue.read(body)
        } catch let error as DatabaseError where error.isTornCopy {
            // usernoted was mid-write while we cloned. Not fatal: the next tick copies again.
            throw CaptureError.snapshotFailed(underlying: "torn copy (\(error.resultCode.rawValue))")
        } catch let error as DatabaseError {
            throw CaptureError.readFailed("sqlite \(error.resultCode.rawValue)")
        }
    }

    public func discard() {
        try? FileManager.default.removeItem(at: directory)
    }
}

extension DatabaseError {
    /// Result codes we have seen from a copy taken during a checkpoint.
    var isTornCopy: Bool {
        switch resultCode {
        case .SQLITE_CORRUPT, .SQLITE_NOTADB, .SQLITE_IOERR: return true
        default: return false
        }
    }
}
```

> ❌ **Don't:** open the snapshot as `file:…?immutable=1`. `immutable=1` promises SQLite the file cannot change, and SQLite takes that to mean it may **skip WAL recovery entirely** — so every row still sitting in the copied `-wal` becomes invisible, with no error and no warning. Those are precisely the rows capture came for: everything delivered since the last checkpoint. Measured on macOS 26 against a copy holding one checkpointed row and one WAL-only row, `immutable=1` returned only the checkpointed one; against a copy whose table had not been checkpointed at all it reported `no such table`. This flatly contradicts the reason the `-wal` is copied in the first place.
>
> The original rationale for `immutable=1` — "no locking, no wal-index writes" — was aimed at a risk that does not exist here. Locking and `-shm` creation are only dangerous on *Apple's* file, and `StoreSnapshot` never opens Apple's file. On our own copy, SQLite building a `-shm` inside the `0700` snapshot directory is exactly what makes the WAL rows readable, and `discard()` removes it with the rest of the directory at the end of the tick.
>
> (`SQLiteURIFilenames`, which earlier drafts of this document referenced, does not exist and is not needed. It would have wrapped `sqlite3_config(SQLITE_CONFIG_URI, …)`, which is a variadic C function and therefore unavailable from Swift without a C shim. macOS's system SQLite parses `file:` URIs regardless.)

> ❌ **Don't:** open the live `db` "just for a quick count". Not with `sqlite3`, not with GRDB, not read-only. Every code path goes through `StoreSnapshot`.

### Adapter: StoreAdapterV26.records(after:)

The adapter is the only type that names a system-store column. `StoreAdapterV14` and `StoreAdapterV15` differ from V26 in the fingerprint set and, where a fixture proved it necessary, in a column name; the query shape is identical.

```swift
// Packages/BackglanceCapture/Sources/BackglanceCapture/Adapters/StoreAdapterV26.swift
import Foundation
import GRDB

/// Companion to StoreAdapter: the newest record in the store. Used for store-reset
/// detection and for fast-forwarding the cursor after a pause. Every shipped adapter conforms.
public protocol StoreTailProviding: Sendable {
    func tail(in db: Database) throws -> StoreCursor?
}

/// ⚠️ macOS 26 (Tahoe). Layout observed in dev testing and re-verified by
/// Tests/Fixtures/SystemStore/macOS26 at every macOS point release. Not an API.
public struct StoreAdapterV26: StoreAdapter, StoreTailProviding {
    public static let id = "v26"
    public static let supportedOS: ClosedRange<Int> = 26...26
    public static let batchSize = 500

    public init() {}

    public static func matches(_ fp: StoreFingerprint) -> Bool {
        KnownFingerprints.shared.hashes(forAdapter: id).contains(fp.schemaHash)
    }

    public func probe(_ db: Database) throws -> ProbeResult {
        let required: [(table: String, columns: [String])] = [
            ("dbinfo", ["key", "value"]),
            ("app", ["app_id", "identifier"]),
            ("record", ["rec_id", "app_id", "uuid", "data", "delivered_date", "presented"]),
        ]
        do {
            var missing: [String] = []
            for entry in required {
                guard try db.tableExists(entry.table) else { missing.append(entry.table); continue }
                let present = Set(try db.columns(in: entry.table).map(\.name))
                missing.append(contentsOf: entry.columns
                    .filter { !present.contains($0) }
                    .map { "\(entry.table).\($0)" })
            }
            guard missing.isEmpty else { return .missingTables(missing) }
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record") ?? 0
            return .ok(recordCount: count)
        } catch let error as DatabaseError
            where error.resultCode == .SQLITE_AUTH || error.resultCode == .SQLITE_CANTOPEN {
            return .permissionDenied
        }
    }

    public func records(after cursor: StoreCursor, in db: Database) throws -> [RawStoreRecord] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT r.rec_id, a.identifier, r.uuid, r.data,
                   r.delivered_date, r.request_date, r.presented, r.style
            FROM record AS r
            JOIN app AS a USING (app_id)
            WHERE r.rec_id > ?
            ORDER BY r.rec_id ASC
            LIMIT ?
            """, arguments: [cursor.lastRecID, Self.batchSize])

        return rows.compactMap { row -> RawStoreRecord? in
            guard let recID: Int64 = row["rec_id"],
                  let identifier: String = row["identifier"],
                  let data: Data = row["data"] else {
                return nil          // a row without a payload is not a notification
            }
            let delivered: Double? = row["delivered_date"]
            let requested: Double? = row["request_date"]
            let presented: Int? = row["presented"]
            return RawStoreRecord(
                recID: recID,
                appIdentifier: identifier,
                uuid: Self.uuid(from: row["uuid"]) ?? UUID(),   // store uuid, else generated
                plistData: data,
                deliveredDate: delivered.map { Date(timeIntervalSinceReferenceDate: $0) },  // Cocoa epoch
                requestDate: requested.map { Date(timeIntervalSinceReferenceDate: $0) },
                presented: (presented ?? 1) != 0,
                style: row["style"])
        }
    }

    public func cursor(for record: RawStoreRecord) -> StoreCursor {
        StoreCursor(lastRecID: record.recID,
                    lastDeliveredDate: record.deliveredDate?.timeIntervalSinceReferenceDate ?? 0)
    }

    public func tail(in db: Database) throws -> StoreCursor? {
        guard let row = try Row.fetchOne(db, sql:
            "SELECT rec_id, delivered_date FROM record ORDER BY rec_id DESC LIMIT 1") else {
            return nil
        }
        let delivered: Double? = row["delivered_date"]
        return StoreCursor(lastRecID: row["rec_id"], lastDeliveredDate: delivered ?? 0)
    }

    /// `record.uuid` is a 16-byte BLOB on every fixture we have; tolerate TEXT too.
    static func uuid(from value: DatabaseValue) -> UUID? {
        switch value.storage {
        case .blob(let data) where data.count == 16:
            return data.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
        case .string(let text):
            return UUID(uuidString: text)
        default:
            return nil
        }
    }
}
```

The `LIMIT 500` is not optional. It bounds memory per tick, lets import report progress, and means one bad row can only delay — never block — the rest.

### RecordParser

`record.data` is a binary property list. The keys are undocumented and abbreviated; the parser reads with tolerant fallbacks and treats absence as `nil`, never as an error. Only two things fail a parse: data that is not a plist at all, and a plist with no text and no attachments (nothing to show).

```swift
// Packages/BackglanceCapture/Sources/BackglanceCapture/RecordParser.swift
import Foundation
import BackglanceCore

public struct RecordParser: Sendable {
    public init() {}

    public func parse(_ raw: RawStoreRecord) throws -> ParsedNotification {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: raw.plistData, options: [], format: nil)
        } catch {
            throw CaptureError.parseFailed(recID: raw.recID, reason: "not a property list")
        }
        guard let root = object as? [String: Any] else {
            throw CaptureError.parseFailed(recID: raw.recID, reason: "root is not a dictionary")
        }

        // ⚠️ Undocumented keys, observed on macOS 11–26: root `app`, `date`, `req`;
        // inside `req`: `titl`, `subt`, `body`, `iden`, `cate`, `thre`, `atta`, `usda`.
        // Long-form spellings are accepted too so a renamed key degrades gracefully.
        let req = (root["req"] as? [String: Any]) ?? root
        let bundleID = Self.string(root["app"]) ?? raw.appIdentifier

        let title = Self.string(req["titl"], req["title"])
        let subtitle = Self.string(req["subt"], req["subtitle"])
        let body = Self.string(req["body"])
        let threadID = Self.string(req["thre"], req["thread"], req["threadIdentifier"])
        let category = Self.string(req["cate"], req["category"])
        let userInfo = Self.stringMap(req["usda"] ?? req["userInfo"])
        let attachments = Self.attachments(req["atta"] ?? req["attachments"])

        guard title != nil || subtitle != nil || body != nil || !attachments.isEmpty else {
            throw CaptureError.parseFailed(recID: raw.recID, reason: "empty payload")
        }

        // Preference order: the row's delivered_date, the plist `date`, the request date, now.
        let deliveredAt = raw.deliveredDate ?? Self.date(root["date"]) ?? raw.requestDate ?? Date()

        return ParsedNotification(
            bundleID: bundleID,
            uuid: raw.uuid,
            title: title,
            subtitle: subtitle,
            body: body,
            sender: Self.sender(bundleID: bundleID, title: title, userInfo: userInfo),
            threadID: threadID,
            category: category,
            deliveredAt: deliveredAt,
            presented: raw.presented,
            attachments: attachments,
            deepLink: nil,                          // EnrichmentService fills this in
            userInfo: userInfo)
    }

    // MARK: Tolerant accessors

    /// First non-empty string among the candidates. Attributed strings are flattened.
    private static func string(_ candidates: Any?...) -> String? {
        for candidate in candidates {
            if let s = candidate as? String, !s.isEmpty { return s }
            if let a = candidate as? NSAttributedString, a.length > 0 { return a.string }
        }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let d = value as? Date { return d }
        if let n = value as? NSNumber { return Date(timeIntervalSinceReferenceDate: n.doubleValue) }
        return nil
    }

    /// userInfo is flattened to String: String. Nested containers and Data are dropped on
    /// purpose — we archive what a human could read, not arbitrary app payloads.
    private static func stringMap(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, raw) in dict {
            switch raw {
            case let s as String: out[key] = s
            case let n as NSNumber: out[key] = n.stringValue
            case let u as URL: out[key] = u.absoluteString
            default: continue
            }
        }
        return out
    }

    /// Metadata only. Backglance never reads or copies attachment bytes.
    private static func attachments(_ value: Any?) -> [AttachmentMeta] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.map { item in
            AttachmentMeta(type: string(item["type"], item["UTI"], item["uti"]) ?? "unknown",
                           name: string(item["name"], item["iden"], item["identifier"]),
                           size: (item["size"] as? NSNumber)?.intValue)
        }
    }

    /// Messages and Mail put the sender in the title; other apps sometimes in userInfo.
    private static func sender(bundleID: String, title: String?, userInfo: [String: String]) -> String? {
        if let s = userInfo["sender"] ?? userInfo["from"], !s.isEmpty { return s }
        switch bundleID {
        case "com.apple.MobileSMS", "com.apple.mail": return title
        default: return nil
        }
    }
}
```

> ⚠️ **Warning:** A parse failure is logged by `rec_id` and reason only. The parser never puts plist contents into an error, a log line, or a crash report — there is no crash-reporting service to begin with.

### Exclusion before parse

`RawStoreRecord.appIdentifier` comes from the store's `app.identifier` column, so the exclusion list can be applied *before* the bplist is decoded. Excluded apps' payloads are never deserialized into memory as objects, never redacted, never logged. This matters for password managers, whose notifications can contain account names.

```swift
// Inside CaptureEngine — see the full listing below.
private func archiveOne(_ raw: RawStoreRecord, source: ArchivedNotification.Source) async -> ArchiveOutcome {
    // 1. Exclusion on the raw row: no parse for excluded apps.
    guard exclusions.allows(raw.appIdentifier) else { return .excluded }
    do {
        // 2. Parse. The `app` key inside the plist may differ from app.identifier
        //    (iPhone Mirroring, helper processes); re-check the parsed bundle ID.
        let parsed = try parser.parse(raw)
        guard exclusions.allows(parsed.bundleID) else { return .excluded }
        // 3. Redact in memory. `redaction` carries only a pattern id, never the digits.
        let (clean, redaction) = redactor.redact(parsed)
        // 4. Enrich (icon, deep link) and write.
        let enriched = await enrichment.enrich(clean)
        switch try archive.insertOrUpdate(enriched, redaction: redaction, storeRecID: raw.recID, source: source) {
        case .inserted: return .archived
        case .updated:  return .updated
        case .duplicate: return .duplicate
        }
    } catch let error as CaptureError {
        logger.error("skip rec \(raw.recID, privacy: .public): \(error.logDescription, privacy: .public)")
        return .failed
    } catch let error as ArchiveError {
        logger.error("archive rec \(raw.recID, privacy: .public): \(error.logDescription, privacy: .public)")
        return .failed
    } catch {
        logger.error("rec \(raw.recID, privacy: .public): \(String(describing: error), privacy: .public)")
        return .failed
    }
}
```

`ExclusionList` is loaded from `apps.is_excluded = 1` plus the built-in defaults (password managers, `com.apple.Passwords`, `app.backglance.Backglance` itself) and cached in memory; it reloads on a `ValueObservation` of the `apps` table, so toggling an app in Settings takes effect on the next tick. See [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md).

### Redaction, triage, enrichment

- **`OTPRedactor.redact(_:)`** — on by default for `com.apple.MobileSMS` and `com.apple.mail`; replaces matched codes with `[code redacted]` and returns a `RedactionEvent` (`kind = 'otp'`, `pattern_id`). Runs before any write. Details in [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md).
- **`RulesEngine.evaluate(_:rules:)`** — capture does *not* store triage. Triage is computed at read time by the timeline from the current rules, so editing a rule re-triages history for free. Rules are visual only; they never change what the system delivers ([RULES.md](./RULES.md)).
- **`EnrichmentService.enrich(_:)`** — an actor. Resolves the app icon via `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` → `icon(forFile:)`, caches PNGs in `~/Library/Application Support/Backglance/icons/<bundle_id>.png`, and resolves a deep link from URL-ish `userInfo` values plus per-app resolvers (Messages `sms:`/`imessage:` thread, Mail `message://`, Slack/Discord where a URL is present). Enrichment failures are non-fatal: a missing icon falls back to a generic glyph, a missing deep link leaves `deep_link` NULL ([ACTIONS.md](./ACTIONS.md)).

### Dedupe and thread updates

Two keys, checked in order inside one write transaction:

1. **`store_rec_id`** — the same store row seen twice (import overlapping live, crash between insert and cursor save). Outcome: `.duplicate`, no write.
2. **`uuid`** — a *different* store row carrying a uuid we already have. This is what a thread update looks like: Messages replaces the banner for a conversation, Mail re-delivers an updated summary. Outcome: `.updated` — text and `store_rec_id` are refreshed on the existing archive row; the row keeps its id (and its place in digests); it becomes unread again only if the text actually changed.

```swift
// Packages/BackglanceCore/Sources/BackglanceCore/Archive+Capture.swift
import Foundation
import GRDB

extension Archive {
    public enum InsertOutcome: Sendable, Equatable {
        case inserted(id: Int64)
        case updated(id: Int64)
        case duplicate
    }

    public func insertOrUpdate(_ n: ParsedNotification,
                               redaction: RedactionEvent?,
                               storeRecID: Int64?,
                               source: ArchivedNotification.Source) throws -> InsertOutcome {
        try pool.write { db in
            if let recID = storeRecID,
               try ArchivedNotification.filter(Column("store_rec_id") == recID).fetchCount(db) > 0 {
                return .duplicate
            }
            var app = try AppRecord.findOrCreate(db, bundleID: n.bundleID, seenAt: UnixDate(n.deliveredAt))

            if var existing = try ArchivedNotification.filter(Column("uuid") == n.uuid.uuidString).fetchOne(db),
               let existingID = existing.id {
                let textChanged = existing.title != n.title
                    || existing.subtitle != n.subtitle
                    || existing.body != n.body
                existing.title = n.title
                existing.subtitle = n.subtitle
                existing.body = n.body
                existing.sender = n.sender
                existing.threadId = n.threadID
                existing.deliveredAt = UnixDate(n.deliveredAt)
                existing.presented = n.presented
                existing.deepLink = n.deepLink?.absoluteString
                existing.attachmentsJson = try Self.encodeAttachments(n.attachments)
                existing.storeRecId = storeRecID
                if textChanged { existing.isRead = false }
                try existing.update(db)                        // notifications_au keeps FTS in sync
                return .updated(id: existingID)
            }

            var row = ArchivedNotification(
                id: nil,
                uuid: n.uuid.uuidString,
                appId: app.id!,
                title: n.title,
                subtitle: n.subtitle,
                body: n.body,
                sender: n.sender,
                threadId: n.threadID,
                category: n.category,
                deliveredAt: UnixDate(n.deliveredAt),
                capturedAt: .now,
                source: source,
                presented: n.presented,
                awaySessionId: nil,                            // AwaySessionTracker links later
                deepLink: n.deepLink?.absoluteString,
                attachmentsJson: try Self.encodeAttachments(n.attachments),
                redaction: redaction == nil ? .none : .otp,
                isRead: false,
                isPinned: false,
                isDeleted: false,
                storeRecId: storeRecID)
            do {
                try row.insert(db)
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                // Two engines racing on the same uuid (tests) or a unique-index hit we did
                // not predict. Treat as duplicate rather than failing the batch.
                return .duplicate
            }
            if var event = redaction {
                event.notificationId = row.id!
                try event.insert(db)
            }
            app.notificationCount += 1
            app.lastSeenAt = max(app.lastSeenAt, UnixDate(n.deliveredAt))
            try app.update(db)
            return .inserted(id: row.id!)
        }
    }

    /// Store was reset (rec_ids restarted from 1). Old rows must stop shadowing new rec_ids;
    /// uuid remains the dedupe key for them.
    public func forgetStoreRecIDs() throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE notifications SET store_rec_id = NULL WHERE store_rec_id IS NOT NULL")
        }
    }

    private static func encodeAttachments(_ items: [AttachmentMeta]) throws -> String? {
        guard !items.isEmpty else { return nil }
        return String(decoding: try JSONEncoder().encode(items), as: UTF8.self)
    }
}
```

### Cursor persistence

`StoreCursor` is JSON in `capture_state.cursor`. It is written once per batch, *after* the batch's inserts committed. `lastRecID` is the primary key of progress; `lastDeliveredDate` is informational (shown in Settings as "last notification seen at") and used by the store-reset heuristic.

```swift
// Packages/BackglanceCore/Sources/BackglanceCore/Archive+CaptureState.swift
import Foundation
import GRDB

extension Archive {
    public enum CaptureStateKey: String { case cursor, fingerprint, adapterID = "adapter_id", lastImportAt = "last_import_at" }

    public func loadCursor() throws -> StoreCursor? {
        try pool.read { db in
            guard let json = try String.fetchOne(db, sql: "SELECT value FROM capture_state WHERE key = ?",
                                                 arguments: [CaptureStateKey.cursor.rawValue]) else { return nil }
            do {
                return try JSONDecoder().decode(StoreCursor.self, from: Data(json.utf8))
            } catch {
                // A corrupt cursor is not worth a degraded state: start from the tail on next bootstrap.
                return nil
            }
        }
    }

    public func saveCursor(_ cursor: StoreCursor) throws {
        let json = String(decoding: try JSONEncoder().encode(cursor), as: UTF8.self)
        try pool.write { db in
            try db.execute(sql: "INSERT INTO capture_state(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [CaptureStateKey.cursor.rawValue, json])
        }
    }

    public func saveLastImport(_ date: Date) throws {
        try pool.write { db in
            try db.execute(sql: "INSERT INTO capture_state(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [CaptureStateKey.lastImportAt.rawValue, String(date.timeIntervalSince1970)])
        }
    }
}
```

`StoreCursor` lives in `BackglanceCapture`; the JSON shape is what `Archive` persists, which is why `StoreCursor` is `Codable` and why `Archive` treats it as an opaque blob when it cannot decode it.

### CaptureEngine

The engine is an actor: the single owner of the adapter, the cursor and the status. The listing below is the complete v1.0 engine minus the import progress plumbing shown separately in [First-launch import](#first-launch-import).

```swift
// Packages/BackglanceCapture/Sources/BackglanceCapture/CaptureEngine.swift
import Foundation
import GRDB
import OSLog
import BackglanceCore

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

enum ArchiveOutcome { case archived, updated, duplicate, excluded, failed }

public actor CaptureEngine {
    public private(set) var status: CaptureStatus = .stopped {
        didSet { statusContinuation.yield(status) }
    }
    public nonisolated let statusStream: AsyncStream<CaptureStatus>
    private let statusContinuation: AsyncStream<CaptureStatus>.Continuation
    public private(set) var metrics = CaptureMetrics()

    private let archive: Archive
    private let watcher: StoreWatcher
    private let parser = RecordParser()
    private let redactor: OTPRedactor
    private let exclusions: ExclusionList
    private let enrichment: EnrichmentService
    private let settings: CaptureSettings
    private let logger = Logger(subsystem: "app.backglance.Backglance", category: "capture")

    private var adapter: (any StoreAdapter)?
    private var cursor: StoreCursor = .start
    private var loopTask: Task<Void, Never>?
    private var autoResumeTask: Task<Void, Never>?
    private var consecutiveTransientFailures = 0
    private static let transientFailureLimit = 5

    public init(archive: Archive, watcher: StoreWatcher, redactor: OTPRedactor = .default,
                exclusions: ExclusionList, enrichment: EnrichmentService,
                settings: CaptureSettings = .fromDefaults()) {
        self.archive = archive
        self.watcher = watcher
        self.redactor = redactor
        self.exclusions = exclusions
        self.enrichment = enrichment
        self.settings = settings
        let (stream, continuation) = AsyncStream.makeStream(of: CaptureStatus.self)
        self.statusStream = stream
        self.statusContinuation = continuation
    }

    // MARK: Lifecycle

    public func start() async {
        guard loopTask == nil else { return }
        await bootstrapOrDegrade()
        watcher.start()
        loopTask = Task { [watcher] in
            for await reason in watcher.wakes {
                await self.tick(reason: reason)
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        autoResumeTask?.cancel()
        watcher.stop()
        status = .stopped
    }

    /// Pause. `nil` = indefinitely. The watcher keeps running (cheap) but ticks are ignored.
    public func pause(until date: Date?) {
        autoResumeTask?.cancel()
        status = .paused(until: date)
        guard let date else { return }
        autoResumeTask = Task {
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
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
        do {
            if !settings.importWhilePaused {
                // Default: notifications delivered during the pause are never archived.
                try fastForwardCursor()
            }
            status = .running
            watcher.poke()
        } catch let error as CaptureError {
            status = .degraded(error.degradedReason)
        } catch {
            status = .degraded(.readError(String(describing: error)))
        }
    }

    // MARK: Bootstrap

    private func bootstrapOrDegrade() async {
        do {
            try bootstrap()
        } catch let error as CaptureError {
            status = .degraded(error.degradedReason)     // stays alive; retried on every wake
        } catch {
            status = .degraded(.readError(String(describing: error)))
        }
    }

    private func bootstrap() throws {
        let location = try StoreLocation.current()
        let snapshot = try StoreSnapshot.take(of: location)
        defer { snapshot.discard() }

        let resolution = try snapshot.read { db -> StoreAdapterRegistry.Resolution in
            let fingerprint = try StoreFingerprint.compute(in: db)
            try archive.saveFingerprint(fingerprint)
            return StoreAdapterRegistry.resolve(fingerprint: fingerprint, probing: db)
        }
        switch resolution {
        case .matched(let a):
            adapter = a
        case .fallback(let a, let note):
            adapter = a
            logger.notice("adapter fallback: \(note, privacy: .public)")
        case .degraded(let reason):
            throw CaptureError.degraded(reason)
        }
        try archive.saveAdapterID(type(of: adapter!).id)

        if let saved = try archive.loadCursor() {
            cursor = saved
        } else {
            // Fresh archive: live capture starts at the tail. Import is a separate, explicit step.
            cursor = try snapshot.read { db in try (adapter as? StoreTailProviding)?.tail(in: db) } ?? .start
            try archive.saveCursor(cursor)
        }
        consecutiveTransientFailures = 0
        status = .running
    }

    // MARK: Tick

    private func tick(reason: WakeReason) async {
        if case .degraded = status {
            await bootstrapOrDegrade()          // FDA granted? store back? try again
            return
        }
        guard case .running = status, let adapter else { return }

        do {
            let snapshot = try StoreSnapshot.take(of: StoreLocation.current())
            defer { snapshot.discard() }

            // Store reset: rec_id went backwards (user cleared everything and usernoted
            // recreated the db, or a migration renumbered). Everything in the store is new.
            if let tailProvider = adapter as? StoreTailProviding,
               let tail = try snapshot.read({ try tailProvider.tail(in: $0) }),
               tail.lastRecID < cursor.lastRecID {
                logger.notice("store reset: tail \(tail.lastRecID, privacy: .public) < cursor \(self.cursor.lastRecID, privacy: .public)")
                try archive.forgetStoreRecIDs()
                cursor = .start
                try archive.saveCursor(cursor)
                metrics.storeResets += 1
            }

            let startCursor = cursor
            let batch = try snapshot.read { db in try adapter.records(after: startCursor, in: db) }
            consecutiveTransientFailures = 0
            guard !batch.isEmpty else { return }

            var tally = CaptureMetrics.Tick()
            for raw in batch {
                tally.record(await archiveOne(raw, source: .live))
                cursor = adapter.cursor(for: raw)
            }
            try archive.saveCursor(cursor)
            metrics.add(tally)
            logger.debug("tick \(reason.rawValue, privacy: .public): \(tally.summary, privacy: .public)")
        } catch let error as CaptureError {
            handleTickFailure(error)
        } catch {
            handleTickFailure(.readFailed(String(describing: error)))
        }
    }

    /// Torn copies and busy files are transient: log, wait for the next wake, degrade only
    /// after five in a row. Permission and schema errors degrade immediately.
    private func handleTickFailure(_ error: CaptureError) {
        switch error {
        case .snapshotFailed, .readFailed:
            consecutiveTransientFailures += 1
            metrics.transientFailures += 1
            logger.notice("transient: \(error.logDescription, privacy: .public) (\(self.consecutiveTransientFailures, privacy: .public)/\(Self.transientFailureLimit, privacy: .public))")
            if consecutiveTransientFailures >= Self.transientFailureLimit {
                status = .degraded(error.degradedReason)
            }
        default:
            status = .degraded(error.degradedReason)
        }
    }

    private func fastForwardCursor() throws {
        guard let adapter else { return }
        let snapshot = try StoreSnapshot.take(of: StoreLocation.current())
        defer { snapshot.discard() }
        if let tailProvider = adapter as? StoreTailProviding,
           let tail = try snapshot.read({ try tailProvider.tail(in: $0) }) {
            cursor = tail
        } else {
            var c = cursor
            while true {
                let page = try snapshot.read { db in try adapter.records(after: c, in: db) }
                guard let last = page.last else { break }
                c = adapter.cursor(for: last)
            }
            cursor = c
        }
        try archive.saveCursor(cursor)
    }
}
```

`CaptureSettings` is a small `Sendable` struct read from `UserDefaults` (suite `app.backglance.Backglance`) with one field in v1.0: `importWhilePaused` (key `capture.importWhilePaused`, default `false`).

### Pause semantics

Pause is a promise: *nothing delivered while paused is archived*. That is why the implementation is not "stop the watcher" alone.

| While paused | Behaviour |
|---|---|
| Watcher | Keeps running (it costs nothing); wakes reach `tick`, which returns immediately because `status != .running` |
| Store | Keeps accumulating rows on its own — Backglance has no influence on system delivery |
| Cursor | Frozen |
| On resume, default | Cursor is fast-forwarded to the store's tail; rows delivered during the pause are skipped for good. Even if the user later opens Settings and turns "Import notifications received while paused" on, those rows are not recovered — the cursor already moved. |
| On resume, setting on | Cursor stays; the next tick archives everything delivered during the pause with `source = 'live'` |
| Status item | Pause glyph; tooltip "Capture paused until 14:30" or "Capture paused" |
| Auto-resume | `pause(until:)` schedules a `Task.sleep`; "until tomorrow" is 06:00 local next day; "indefinitely" is `nil` |
| URL scheme | `backglance://pause?minutes=30`, `backglance://resume` ([EXPORT_AUTOMATION.md](./EXPORT_AUTOMATION.md)) |

> ℹ️ **Info:** The Settings label reads *Import notifications received while paused: off*. Under it, one sentence: "When off, notifications that arrive during a pause are never archived, even if the system still has them."

### First-launch import

Onboarding offers a single choice — "Import the notifications macOS still has?" — with a count when the probe could produce one ("About 1,240 notifications from the last 6 days"). Import walks the store from `rec_id 0` in batches of 500, tags rows `source = 'import'`, dedupes against anything live capture already archived, and leaves the live cursor alone (it already sits at the tail).

```swift
// Packages/BackglanceCapture/Sources/BackglanceCapture/CaptureEngine+Import.swift
import Foundation
import BackglanceCore

public struct ImportProgress: Sendable, Equatable {
    public var scanned: Int
    public var archived: Int
    public var expectedTotal: Int?          // from probe(); nil → indeterminate bar
    public var oldestSeen: Date?
}

public struct ImportSummary: Sendable, Equatable {
    public var archived: Int
    public var duplicates: Int
    public var excluded: Int
    public var failed: Int
    public var oldest: Date?
    /// "Imported 1,187 notifications from the last 6 days — this is all the system still had."
    public var userSentence: String {
        let days = oldest.map { max(1, Int(Date().timeIntervalSince($0) / 86_400)) }
        let span = days.map { " from the last \($0) day\($0 == 1 ? "" : "s")" } ?? ""
        return "Imported \(archived.formatted()) notification\(archived == 1 ? "" : "s")\(span) — this is all the system still had."
    }
}

extension CaptureEngine {
    /// First-launch import. Safe to run again (dedupe by store_rec_id / uuid); Settings ▸ Capture
    /// exposes it as "Import again", mostly for people who granted FDA late.
    @discardableResult
    public func importExisting(progress: (@Sendable (ImportProgress) async -> Void)? = nil) async throws -> ImportSummary {
        guard let adapter = currentAdapter() else {
            throw CaptureError.degraded(.storeNotFound)
        }
        var expected: Int?
        var importCursor = StoreCursor.start
        var summary = ImportSummary(archived: 0, duplicates: 0, excluded: 0, failed: 0, oldest: nil)
        var scanned = 0

        while true {
            let snapshot = try StoreSnapshot.take(of: StoreLocation.current())
            defer { snapshot.discard() }
            if expected == nil, case .ok(let count) = try snapshot.read({ try adapter.probe($0) }) {
                expected = count
            }
            let c = importCursor
            let batch = try snapshot.read { db in try adapter.records(after: c, in: db) }
            if batch.isEmpty { break }

            for raw in batch {
                switch await archiveOne(raw, source: .imports) {
                case .archived, .updated: summary.archived += 1
                case .duplicate: summary.duplicates += 1
                case .excluded: summary.excluded += 1
                case .failed: summary.failed += 1
                }
                if let d = raw.deliveredDate { summary.oldest = min(summary.oldest ?? d, d) }
                importCursor = adapter.cursor(for: raw)
            }
            scanned += batch.count
            await progress?(ImportProgress(scanned: scanned, archived: summary.archived,
                                           expectedTotal: expected, oldestSeen: summary.oldest))
            try Task.checkCancellation()
        }
        try archive.saveLastImport(Date())
        logger.notice("import: \(summary.archived, privacy: .public) archived, \(summary.duplicates, privacy: .public) dup, \(summary.excluded, privacy: .public) excluded, \(summary.failed, privacy: .public) failed")
        return summary
    }
}
```

UX rules for the import screen:

- Progress is determinate when `probe()` returned a count, indeterminate otherwise.
- The completion sentence always ends with "this is all the system still had". No apology, no upsell, no "enable X to get more".
- Import runs on the engine actor, so live ticks queue behind it; the popover keeps working on the archive meanwhile.
- Cancelling keeps what was imported; `last_import_at` is not written, so Settings still offers "Import".
- Budget: 10k store records in under 10 s on Apple silicon ([../deployment/PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md)).

## Edge Cases and Error Handling

| Situation | Detection | Behaviour |
|---|---|---|
| Store locked / busy / mid-checkpoint | `copyItem` throws, or the copy opens with `SQLITE_CORRUPT`/`SQLITE_NOTADB`/`SQLITE_IOERR` | `CaptureError.snapshotFailed` → transient. Wait for the next wake (the poll guarantees one within 15 s). Degrade only after 5 consecutive failures. |
| Huge store (hundreds of MB, 100k+ rows) | — | APFS clone keeps the copy O(1); batches of 500 bound memory; `autoreleasepool` per batch in import; snapshot discarded per batch |
| Clock changes (NTP jump, time zone, manual) | — | Cursor is `rec_id`-based, so capture is unaffected. `delivered_at` is stored as the store reported it, `captured_at` as wall clock at insert. The timeline groups by `delivered_at` in the current time zone. |
| Notification with empty title *and* body | Parser | Archived if a subtitle or attachment exists; otherwise skipped as `parseFailed("empty payload")` and counted, not logged as an error |
| iOS app via iPhone Mirroring | `app.identifier` has no local `.app` bundle | ⚠️ Uncertain: observed to arrive with the iOS bundle ID; archived normally; icon falls back to a generic glyph; `display_name` from the plist `app` key or the bundle ID; deep links not resolved. Marked "unverified" in the fixtures manifest until we have a real capture. |
| Same `uuid` re-delivered (thread update, edited banner) | `Archive.insertOrUpdate` uuid check | Update in place; unread again only if the text changed |
| Store reset (rec_id goes backwards) | `tail.lastRecID < cursor.lastRecID` | `forgetStoreRecIDs()`, cursor → `.start`, everything in the store is archived as new; uuid dedupe still protects against true duplicates |
| FDA revoked mid-run | Next copy fails with Cocoa 257 (`EPERM`) | `.degraded(.noFullDiskAccess)`; icon changes; retried on every wake; browsing/search of the archive keeps working |
| Unknown schema (new macOS, changed columns) | `StoreAdapterRegistry` → `.degraded(.unknownSchema(fp))` | Degraded with the fingerprint shown in Settings ▸ Capture and a "Copy diagnostics" button (fingerprint only, no content). See [../architecture/OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md). |
| Store file missing (never delivered a notification, unusual setup) | `StoreLocation.current()` / copy → no such file | `.degraded(.storeNotFound)`; retried on wake |
| Adapter fallback on a beta | Fingerprint unknown, `probe()` ok | Keeps capturing on the previous adapter; "best-effort adapter" note; logs the fingerprint once |
| Parse failure on one record | `CaptureError.parseFailed` | Logged by `rec_id` + reason; cursor still advances past it |
| Archive write failure (disk full, `SQLITE_FULL`) | `ArchiveError.insertFailed` | Row skipped and logged; cursor still advances (re-import possible via "Import again"); `ArchiveHealth` banner in the timeline |
| App quit during a batch | — | Cursor not yet saved → the same rows are re-read; `store_rec_id` makes re-inserts no-ops |
| Corrupt cursor JSON | `loadCursor()` returns nil | Bootstrap treats it as a fresh archive: cursor at tail, no re-import (import is explicit) |
| Two Backglance instances (debug build + release) | Second `Archive` open | GRDB `DatabasePool` serializes writes; both would archive the same rows; unique indexes make one of them a duplicate. Not supported, documented in [../operations/TROUBLESHOOTING.md](../operations/TROUBLESHOOTING.md). |

`CaptureError` is the one typed error of the module. Every case maps to a `DegradedReason` (a state the UI can render) and a content-free `logDescription`:

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

    public var degradedReason: DegradedReason {
        switch self {
        case .fullDiskAccessDenied: return .noFullDiskAccess
        case .storeNotFound: return .storeNotFound
        case .snapshotFailed(let s), .readFailed(let s): return .readError(s)
        case .degraded(let reason): return reason
        case .parseFailed(let id, let reason): return .readError("rec \(id): \(reason)")
        }
    }

    /// Safe for the file log and os_log with privacy: .public — identifiers and reasons only.
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

> 🔒 **Security:** No `CaptureError` carries notification content, a plist, or a byte of `record.data`. `parseFailed.reason` is one of a fixed set of strings ("not a property list", "root is not a dictionary", "empty payload").

## Metrics and Logging

Counts only. Never titles, bodies, senders, bundle IDs of excluded apps, or plist keys' *values*.

```swift
// Packages/BackglanceCapture/Sources/BackglanceCapture/CaptureMetrics.swift
import Foundation

public struct CaptureMetrics: Sendable, Equatable {
    public struct Tick: Sendable, Equatable {
        public var read = 0, archived = 0, updated = 0, duplicates = 0, excluded = 0, failed = 0
        mutating func record(_ outcome: ArchiveOutcome) {
            read += 1
            switch outcome {
            case .archived: archived += 1
            case .updated: updated += 1
            case .duplicate: duplicates += 1
            case .excluded: excluded += 1
            case .failed: failed += 1
            }
        }
        var summary: String {
            "read \(read) archived \(archived) updated \(updated) dup \(duplicates) excluded \(excluded) failed \(failed)"
        }
    }
    public var ticks = 0
    public var totals = Tick()
    public var transientFailures = 0
    public var storeResets = 0
    public var lastTickAt: Date?

    mutating func add(_ tick: Tick) {
        ticks += 1
        totals.read += tick.read
        totals.archived += tick.archived
        totals.updated += tick.updated
        totals.duplicates += tick.duplicates
        totals.excluded += tick.excluded
        totals.failed += tick.failed
        lastTickAt = Date()
    }
}
```

| Where | What | Level |
|---|---|---|
| `os.Logger(subsystem: "app.backglance.Backglance", category: "capture")` | per-tick summary line (`tick fileChanged: read 3 archived 3 …`) | `.debug` (dropped from the file log by default) |
| same, category `capture` | bootstrap result, adapter id, fallback note, store reset, transient failure count, import summary | `.notice` |
| same, category `capture` | per-record failures by `rec_id` | `.error` |
| `~/Library/Logs/Backglance/backglance.log` (5 × 2 MB rotating) | `.notice` and above | — |
| Settings ▸ Capture ▸ Diagnostics | `CaptureMetrics` rendered as a small table + "Copy diagnostics" (status, adapter id, fingerprint hash, counts) | — |

See [../operations/MONITORING_LOGGING.md](../operations/MONITORING_LOGGING.md) for the log format and rotation.

## Testing Approach

All capture tests run against **synthetic fixtures** under `Tests/Fixtures/SystemStore/macOS14/`, `macOS15/`, `macOS26/`. Each fixture directory holds `store.db` (+ `store.db-wal` for the WAL cases), `manifest.json` (OS version, fingerprint hash, adapter id, notes such as "iPhone Mirroring rows: unverified") and `expected.json` (the `ParsedNotification` values the adapter + parser must produce). Fixtures are generated by `Scripts/make_fixture.sh` with a seeded RNG — text like `Fixture message 000042 from sender@example.com`, phone numbers `+1 555 0100`, OTP-shaped digits produced by `String(format: "%06d", rng.next() % 1_000_000)` — and never from a real machine's store.

| Suite | Target | What it proves |
|---|---|---|
| `AdapterFixtureTests` (parameterized over macOS 14 / 15 / 26) | `BackglanceCaptureTests` | `matches(fingerprint)`, `probe() == .ok`, `records(after: .start)` equals `expected.json`, cursor round trip |
| `CursorTests` | `BackglanceCaptureTests` | Persist/load; crash-between-insert-and-save re-read yields only duplicates; store reset detection nulls `store_rec_id` and restarts |
| `DedupeTests` | `BackglanceCoreTests` | Same `store_rec_id` → `.duplicate`; same uuid, new rec_id, changed body → `.updated` and `is_read = 0`; unchanged body → `.updated` and `is_read` preserved |
| `RecordParserFuzzTests` | `BackglanceCaptureTests` | 10k seeded mutations of fixture plists (byte flips, truncation, key renames, wrong types) never crash; every outcome is a `ParsedNotification` or a `CaptureError.parseFailed` |
| `ExclusionOrderTests` | `BackglanceCaptureTests` | A spy parser proves excluded bundle IDs are never parsed |
| `StoreWatcherTests` | `BackglanceCaptureTests` | Appending a row to a temp copy of a fixture emits `.fileChanged` within 2 s; a `-wal` rename re-arms; poll fires without file changes |
| `SnapshotTests` | `BackglanceCaptureTests` | A row present only in `store.db-wal` is visible through `StoreSnapshot.read` (guards against reintroducing `?immutable=1`, which hides it); torn copy → `snapshotFailed` |
| `PauseSemanticsTests` | `BackglanceCaptureTests` | Rows added during pause are absent after resume with the default; present with `importWhilePaused = true` |
| `ImportTests` | `BackglanceCaptureTests` | Import then live overlap yields no duplicates; summary sentence; cancellation keeps partial results |

```swift
// Tests/BackglanceCaptureTests/CursorTests.swift
import XCTest
import GRDB
@testable import BackglanceCapture
@testable import BackglanceCore

final class CursorTests: XCTestCase {
    func testStoreResetIsDetectedAndCursorRestarts() async throws {
        let archive = try Archive(inMemory: true)
        let fixture = try StoreFixture.load("macOS26")            // copies to a temp dir, returns URLs
        let watcher = StoreWatcher(location: fixture.databaseURL)
        let engine = CaptureEngine(archive: archive, watcher: watcher,
                                   exclusions: ExclusionList(defaults: [], archive: archive),
                                   enrichment: EnrichmentService(iconCache: .ephemeral),
                                   settings: CaptureSettings(importWhilePaused: false))
        try await engine.start()
        try await engine.importExisting()
        let before = try archive.count(ArchivedNotification.self)
        XCTAssertEqual(before, fixture.expected.count)

        // Simulate the user clearing everything and usernoted recreating the db:
        // rec_ids restart at 1 with brand-new uuids.
        try fixture.resetStore(newRecords: 3, seed: 7)
        watcher.poke()
        try await engine.waitForIdle(timeout: .seconds(5))

        let after = try archive.count(ArchivedNotification.self)
        XCTAssertEqual(after, before + 3, "new rows after a reset must not be shadowed by old rec_ids")
        let cursor = try XCTUnwrap(try archive.loadCursor())
        XCTAssertEqual(cursor.lastRecID, 3)
        let shadowed = try archive.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notifications WHERE store_rec_id IS NOT NULL AND source = 'import'") ?? 0
        }
        XCTAssertEqual(shadowed, 0, "forgetStoreRecIDs() must null out old store_rec_ids")
    }

    func testCorruptCursorFallsBackToTail() throws {
        let archive = try Archive(inMemory: true)
        try archive.pool.write { db in
            try db.execute(sql: "INSERT INTO capture_state(key, value) VALUES ('cursor', 'not json')")
        }
        XCTAssertNil(try archive.loadCursor())
    }
}
```

```swift
// Tests/BackglanceCaptureTests/RecordParserFuzzTests.swift
import XCTest
@testable import BackglanceCapture

final class RecordParserFuzzTests: XCTestCase {
    func testMutatedPlistsNeverCrash() throws {
        let fixture = try StoreFixture.load("macOS26")
        let seeds = try fixture.rawRecords()                       // via StoreAdapterV26 on the fixture
        var rng = SeededGenerator(seed: 2026)
        let parser = RecordParser()
        var parsed = 0, failed = 0

        for i in 0..<10_000 {
            let base = seeds[i % seeds.count]
            var bytes = [UInt8](base.plistData)
            switch rng.next() % 4 {
            case 0: bytes[Int(rng.next() % UInt64(bytes.count))] ^= 0xFF          // byte flip
            case 1: bytes.removeLast(Int(rng.next() % UInt64(bytes.count)))         // truncation
            case 2: bytes = Array(bytes.dropFirst(Int(rng.next() % 8)))              // header damage
            default: break                                                           // unchanged
            }
            let mutated = RawStoreRecord(recID: base.recID, appIdentifier: base.appIdentifier,
                                         uuid: base.uuid, plistData: Data(bytes),
                                         deliveredDate: base.deliveredDate, requestDate: base.requestDate,
                                         presented: base.presented, style: base.style)
            do {
                _ = try parser.parse(mutated)
                parsed += 1
            } catch CaptureError.parseFailed {
                failed += 1
            } catch {
                XCTFail("unexpected error type: \(error)")
            }
        }
        XCTAssertEqual(parsed + failed, 10_000)
        XCTAssertGreaterThan(parsed, 0)     // the unchanged quarter must parse
    }
}
```

CI runs the fixture suites on `macos-14`, `macos-15` and `macos-26` runners; the `fixtures.yml` workflow additionally re-verifies every fixture's fingerprint against `KnownFingerprints.json` so a stale fixture fails loudly. See [../testing/TESTING.md](../testing/TESTING.md) and [../deployment/CI_CD.md](../deployment/CI_CD.md).

> ✅ **Do:** when a macOS beta changes the store, add a fixture *first* (`Scripts/make_fixture.sh --os 27`), watch `AdapterFixtureTests` fail, then write or adjust the adapter. The playbook has the exact steps.

## Next Steps

- [TIMELINE.md](./TIMELINE.md) — what happens to a notification once it is in the archive.
- [MISSED_DIGEST.md](./MISSED_DIGEST.md) — how away sessions link back to `notifications.away_session_id`.
- [../architecture/OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md) — the procedure when a new macOS breaks the fingerprint.

## Related Documentation

- [PERMISSIONS_PRIVACY.md](./PERMISSIONS_PRIVACY.md)
- [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md)
- [RULES.md](./RULES.md)
- [ACTIONS.md](./ACTIONS.md)
- [TIMELINE.md](./TIMELINE.md)
- [MISSED_DIGEST.md](./MISSED_DIGEST.md)
- [EXPORT_AUTOMATION.md](./EXPORT_AUTOMATION.md)
- [../architecture/ARCHITECTURE.md](../architecture/ARCHITECTURE.md)
- [../architecture/DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md)
- [../architecture/OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md)
- [../deployment/PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md)
- [../deployment/CI_CD.md](../deployment/CI_CD.md)
- [../operations/MONITORING_LOGGING.md](../operations/MONITORING_LOGGING.md)
- [../operations/TROUBLESHOOTING.md](../operations/TROUBLESHOOTING.md)
- [../testing/TESTING.md](../testing/TESTING.md)
