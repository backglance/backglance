# Performance Guide

Last Updated: 2026-08-18

Backglance is a local menu bar utility, so "performance" here does not mean scaling servers; it means staying invisible on a laptop that runs it all day: near-zero idle CPU, a small memory footprint, an archive that stays fast at 100k notifications, search that feels instant, and a popover that opens before you notice it. This guide explains the strategies behind each of those budgets, how they are measured, and what counts as a regression. The numbers are the same ones every other document uses; they are locked in this guide and enforced by the tests in `Tests/`.

## Table of Contents

- [Budgets at a glance](#budgets-at-a-glance)
- [Capture: polling vs DispatchSource, and battery](#capture-polling-vs-dispatchsource-and-battery)
  - [Why the hybrid](#why-the-hybrid)
  - [Timings](#timings)
  - [Low Power Mode adaptation](#low-power-mode-adaptation)
  - [App Nap and ProcessInfo activities](#app-nap-and-processinfo-activities)
  - [Coalescing and debounce](#coalescing-and-debounce)
  - [Measuring energy](#measuring-energy)
- [Archive at 100k notifications](#archive-at-100k-notifications)
  - [Size](#size)
  - [Index usage](#index-usage)
  - [Keyset pagination](#keyset-pagination)
  - [FTS5: external content vs contentless](#fts5-external-content-vs-contentless)
  - [FTS maintenance: optimize and merge](#fts-maintenance-optimize-and-merge)
  - [WAL checkpointing](#wal-checkpointing)
- [Search latency](#search-latency)
  - [FTS: p95 under 50 ms](#fts-p95-under-50-ms)
  - [Hybrid: p95 under 250 ms](#hybrid-p95-under-250-ms)
  - [Semantic cost math](#semantic-cost-math)
  - [Background embedding generation](#background-embedding-generation)
- [Menu bar responsiveness](#menu-bar-responsiveness)
- [Memory footprint](#memory-footprint)
- [Import performance](#import-performance)
- [Instrumentation](#instrumentation)
  - [Signposts](#signposts)
  - [xctrace](#xctrace)
  - [XCTMetric performance tests](#xctmetric-performance-tests)
- [Regression budgets and CI policy](#regression-budgets-and-ci-policy)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Budgets at a glance

| Area | Budget | Where enforced |
|---|---|---|
| Idle CPU | < 0.1 % average | `powermetrics` spot checks, nightly perf job |
| Poll interval | 15 s (60 s in Low Power Mode) | `StoreWatcher` constants |
| DispatchSource wake → read | debounce 500 ms | `StoreWatcher` |
| Memory, idle | < 60 MB RSS | `MemoryFootprintTests` |
| Memory, window open at 100k | < 150 MB RSS (embeddings excluded) | `MemoryFootprintTests` |
| Archive size | ~1 KB/notification → 100k ≈ 100–150 MB incl. FTS | `ArchiveSizeTests` |
| Popover open → first paint | < 100 ms | `PopoverLaunchTests` (signpost) |
| Timeline scroll | 60 fps, pages of 200 rows | manual Instruments check per release |
| FTS search | p95 < 50 ms at 100k | `SearchLatencyTests` |
| Hybrid search | p95 < 250 ms at 100k | `SearchLatencyTests` |
| Import | 10k store records < 10 s | `ImportPerformanceTests` |

## Capture: polling vs DispatchSource, and battery

### Why the hybrid

Backglance never receives notifications; it reads Apple's system store (`~/Library/Group Containers/group.com.apple.usernoted/db2/db`, ⚠️ undocumented) after `usernoted` writes to it. There are two ways to know that something was written:

| Strategy | Wakes the process | Latency | Battery | Weakness |
|---|---|---|---|---|
| `DispatchSource.makeFileSystemObjectSource` on `db` and `db-wal` | only on `.write`/`.extend`/`.rename` | tens of ms | near zero | vnode sources die when the file is replaced (`usernoted` rotates the WAL on checkpoint); events for a file in a group container are not guaranteed after sleep |
| Timer poll | every N seconds | up to N seconds | proportional to N | wasteful if nothing happened; but it always works |

Neither is enough alone. A vnode source alone silently stops after the WAL is truncated and recreated (the descriptor now points at the old inode). A poll alone at a battery-friendly interval means a notification can take 15 s to appear, and at a snappy interval it burns power for nothing on a machine that gets three notifications an hour. So `StoreWatcher` runs both:

```
              ┌────────────────────────────────────────────┐
              │ StoreWatcher                               │
              │                                            │
  db-wal ──▶  │ DispatchSource (vnode)  ──┐                │
  db     ──▶  │ DispatchSource (vnode)  ──┼──▶ debounce ───┼──▶ CaptureEngine.tick()
              │ DispatchSourceTimer 15 s ─┤   500 ms       │      (snapshot copy → read-only open →
  wake/unlock │ NSWorkspace / DNC  ───────┘   coalesce     │       adapter.records(after:) → archive)
              └────────────────────────────────────────────┘
```

The poll is a safety net, not the primary path. On a quiet machine the timer fires, `tick()` compares the store file's `st_mtime` and size to the last seen values, and returns without opening anything. The re-arm step after every tick re-creates the vnode sources so a rotated WAL is picked up again.

### Timings

| Event | Action |
|---|---|
| vnode event on `db` or `db-wal` | start/extend a 500 ms debounce; one `tick()` when it settles |
| poll timer (15 s; 60 s in Low Power Mode) | cheap `stat` check; `tick()` only if mtime/size changed |
| `NSWorkspace.didWakeNotification`, `com.apple.screenIsUnlocked` | immediate `tick()`, then normal cadence |
| capture paused | sources cancelled, timer suspended; nothing runs |
| store missing / no FDA (degraded) | timer only, backed off to 60 s, no vnode sources |

The timer uses leeway so the kernel can align it with other wakeups:

```swift
// BackglanceCapture/StoreWatcher.swift (excerpt)
private func makePollTimer(interval: TimeInterval) -> DispatchSourceTimer {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    // 20 % leeway lets the system coalesce our wakeup with others.
    timer.schedule(deadline: .now() + interval,
                   repeating: interval,
                   leeway: .milliseconds(Int(interval * 200)))
    timer.setEventHandler { [weak self] in
        self?.pollIfChanged()
    }
    return timer
}
```

### Low Power Mode adaptation

When the user turns on Low Power Mode, the poll interval widens from 15 s to 60 s and the debounce stays at 500 ms (vnode wakes are essentially free; the cost is the read, and reads only happen when there is something to read). `StoreWatcher` observes the change rather than checking on every tick:

```swift
// BackglanceCapture/StoreWatcher.swift (excerpt)
import Foundation

extension StoreWatcher {
    static let normalPollInterval: TimeInterval = 15
    static let lowPowerPollInterval: TimeInterval = 60

    var preferredPollInterval: TimeInterval {
        ProcessInfo.processInfo.isLowPowerModeEnabled
            ? Self.lowPowerPollInterval
            : Self.normalPollInterval
    }

    func observePowerState() {
        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                // Rebuild the timer with the new interval; keep vnode sources as they are.
                self.pollTimer?.cancel()
                self.pollTimer = self.makePollTimer(interval: self.preferredPollInterval)
                self.pollTimer?.resume()
                self.logger.info("poll interval changed: \(self.preferredPollInterval, privacy: .public)s")
            }
        }
    }
}
```

Semantic indexing (see below) also pauses while Low Power Mode is on, and resumes when it turns off.

### App Nap and ProcessInfo activities

Backglance is an `LSUIElement` agent with no windows most of the time, so App Nap will throttle it. That is desirable for the idle path: vnode sources still deliver events, and a napped timer that fires late is harmless because it is only a safety net. The app does not fight App Nap globally.

There are two exceptions where the app declares an activity so the system does not slow it down or terminate it mid-write:

```swift
// BackglanceCore/Archive+Activity.swift
import Foundation

enum ArchiveActivity {
    /// Wrap a burst of archive writes: prevents sudden termination while the
    /// transaction is open. Short-lived; the token is released on return.
    static func protectingWrites<T>(_ reason: String, _ body: () throws -> T) rethrows -> T {
        let token = ProcessInfo.processInfo.beginActivity(
            options: [.suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: reason
        )
        defer { ProcessInfo.processInfo.endActivity(token) }
        return try body()
    }

    /// Wrap a user-visible long task (import, re-index): allows idle system
    /// sleep but opts out of App Nap so the progress bar actually progresses.
    static func userInitiated<T>(_ reason: String, _ body: () async throws -> T) async rethrows -> T {
        let token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: reason
        )
        defer { ProcessInfo.processInfo.endActivity(token) }
        return try await body()
    }
}
```

`importExisting()` and the semantic re-index run under `userInitiated`; every `CaptureEngine.tick()` write runs under `protectingWrites`. Nothing holds an activity token while idle.

### Coalescing and debounce

A single incoming notification produces several writes to the store's WAL within a few milliseconds (`record` insert, `delivered` insert, `dbinfo` bump). Without a debounce each write would trigger a snapshot copy. The 500 ms debounce coalesces those into a single read, and a burst of twenty notifications (a group chat catching up after sleep) still costs one snapshot and one archive transaction:

```swift
// BackglanceCapture/StoreWatcher.swift (excerpt)
private var debounceWorkItem: DispatchWorkItem?

private func scheduleDebouncedTick() {
    debounceWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
        guard let self else { return }
        Task { await self.engine.tick(trigger: .fileEvent) }
    }
    debounceWorkItem = item
    queue.asyncAfter(deadline: .now() + .milliseconds(500), execute: item)
}
```

Inside `tick()`, all records read from the store are inserted in one GRDB write transaction, and the FTS triggers therefore produce one FTS segment per burst rather than one per row.

### Measuring energy

Two tools, both built in:

```bash
# 60 s of per-process energy samples (needs sudo). Look at "CPU ms/s" and "Energy Impact".
sudo powermetrics --samplers tasks --show-process-energy -i 5000 -n 12 \
  | grep -E '^(ID|.*Backglance)'
```

Expected idle reading on Apple silicon: CPU ms/s well under 1.0 (0.1 % of one core), Energy Impact ≈ 0.0–0.1. If you see periodic spikes every 15 s, the `stat` short-circuit is not working (check `pollIfChanged`).

Activity Monitor ▸ Energy tab shows "Energy Impact" (instantaneous) and "12 hr Power" (average). Backglance should sit near the bottom next to menu bar utilities, and "Preventing Sleep" must read "No" at idle. If "App Nap" reads "No" while idle, an activity token is being held; search for `beginActivity` and check the `defer`.

> 💡 **Tip:** `log stream --predicate 'subsystem == "app.backglance.Backglance" AND category == "capture"'` shows every tick and its trigger (`fileEvent`, `poll`, `wake`), so you can correlate spikes with causes. Log lines never include notification content, see [MONITORING_LOGGING.md](../operations/MONITORING_LOGGING.md).

## Archive at 100k notifications

### Size

Measured on a synthetic archive generated by `Scripts/make_fixture.sh --archive --count 100000` (seeded RNG, realistic length distribution: title ≈ 30 chars, body ≈ 120 chars, ~30 % with subtitle/sender):

| Component | Bytes/notification | 100k |
|---|---|---|
| `notifications` row | ~450 | 45 MB |
| indexes on `notifications` | ~120 | 12 MB |
| `notifications_fts` (external content, prefix 2 3) | ~400–800 | 40–80 MB |
| `apps`, `away_sessions`, `digests`, `redactions` | negligible | < 1 MB |
| **Total** | **~1 KB** | **100–150 MB** |
| `embeddings` (optional) | 2,048 + overhead ≈ 2.1 KB | +210 MB |

The prefix index is most of the FTS cost. It buys prefix matching for as-you-type search without needing trigram tokenization; the trade is documented in [SEARCH.md](../features/SEARCH.md).

### Index usage

The four hot queries and their plans, verified against the 100k fixture with `sqlite3 archive.sqlite`:

```sql
-- 1. Timeline first page (newest first)
EXPLAIN QUERY PLAN
SELECT * FROM notifications
WHERE is_deleted = 0
ORDER BY delivered_at DESC, id DESC
LIMIT 200;
-- QUERY PLAN
-- `--SCAN notifications USING INDEX idx_notifications_delivered

-- 2. Per-app timeline
EXPLAIN QUERY PLAN
SELECT * FROM notifications
WHERE app_id = 12 AND is_deleted = 0
ORDER BY delivered_at DESC LIMIT 200;
-- QUERY PLAN
-- `--SEARCH notifications USING INDEX idx_notifications_app_delivered (app_id=?)

-- 3. Digest items for an away session
EXPLAIN QUERY PLAN
SELECT * FROM notifications WHERE away_session_id = 77;
-- QUERY PLAN
-- `--SEARCH notifications USING INDEX idx_notifications_away (away_session_id=?)

-- 4. FTS query joined back to rows
EXPLAIN QUERY PLAN
SELECT n.* FROM notifications_fts f
JOIN notifications n ON n.id = f.rowid
WHERE notifications_fts MATCH 'invoice*' AND n.is_deleted = 0
ORDER BY n.delivered_at DESC LIMIT 200;
-- QUERY PLAN
-- |--SCAN f VIRTUAL TABLE INDEX 0:M1
-- |--SEARCH n USING INTEGER PRIMARY KEY (rowid=?)
-- `--USE TEMP B-TREE FOR ORDER BY
```

Plan 1 walks `idx_notifications_delivered` and stops after 200 rows; the `is_deleted = 0` filter is applied per row, which is fine because deleted rows are a small minority and are hard-pruned by the retention job. Plan 4's temp b-tree is bounded by the number of FTS hits, not by the table size; for a query with tens of thousands of hits `HybridSearch` caps FTS candidates at 2,000 (`ORDER BY rank LIMIT 2000` inside a subquery) before the join.

> ⚠️ **Warning:** Adding `is_deleted` to `idx_notifications_delivered` looks tempting but doubles the index writes on every capture and does not change plan 1's shape. Do not add indexes without a plan diff in the PR.

### Keyset pagination

The timeline never uses `OFFSET`. Offset pagination at page 400 of a 100k archive scans 80k index entries; keyset pagination scans 200 regardless of depth. Because `delivered_at` is not unique (bursts share a second), the key is the pair `(delivered_at, id)`:

```swift
// BackglanceCore/Archive+Timeline.swift
import GRDB

public struct TimelineCursor: Sendable, Equatable {
    public var deliveredAt: Double   // Unix seconds (UnixDate)
    public var id: Int64
}

extension Archive {
    /// Fetch the next page older than `cursor` (or the newest page when nil).
    public func timelinePage(after cursor: TimelineCursor?, limit: Int = 200) throws -> [ArchivedNotification] {
        try pool.read { db in
            if let c = cursor {
                return try ArchivedNotification.fetchAll(db, sql: """
                    SELECT * FROM notifications
                    WHERE is_deleted = 0
                      AND (delivered_at < ? OR (delivered_at = ? AND id < ?))
                    ORDER BY delivered_at DESC, id DESC
                    LIMIT ?
                    """, arguments: [c.deliveredAt, c.deliveredAt, c.id, limit])
            } else {
                return try ArchivedNotification.fetchAll(db, sql: """
                    SELECT * FROM notifications
                    WHERE is_deleted = 0
                    ORDER BY delivered_at DESC, id DESC
                    LIMIT ?
                    """, arguments: [limit])
            }
        }
    }
}
```

The `OR` form is what SQLite's planner handles best with the `(delivered_at DESC)` index; a row-value comparison `(delivered_at, id) < (?, ?)` also works on macOS 14+ SQLite but the index is not on `(delivered_at, id)`, so the plans are equivalent. Both were measured at < 2 ms per page at 100k.

### FTS5: external content vs contentless

| | External content (`content='notifications'`) — **used** | Contentless (`content=''`) |
|---|---|---|
| Stores text twice? | No; FTS keeps only the index and reads text from `notifications` when needed | No |
| Size | index only (~40–80 MB at 100k) | slightly smaller (no docsize needed if `columnsize=0`) |
| `snippet()` / `highlight()` | Yes | No (no text to highlight) |
| Row update / delete | via `_au` / `_ad` triggers using the `'delete'` command | Not supported before SQLite 3.43 (`contentless_delete=1`); Backglance targets macOS 14 whose SQLite is 3.39 |
| Consistency risk | triggers must stay in sync with the schema | none |

External content wins because search results show highlighted snippets and because retention deletes rows individually. The three triggers are created in migration `v1_fts` and every migration that touches `notifications` columns must re-check them; `FTSIndexTests.testTriggersKeepFTSInSync` inserts, updates and deletes and then compares `SELECT count(*) FROM notifications_fts` to the table.

### FTS maintenance: optimize and merge

Each write transaction produces a new FTS segment; hundreds of tiny segments slow every query. Two commands keep the b-tree tidy:

```sql
-- Incremental: merge up to 16 segments; cheap; run after each import batch and
-- from the retention job.
INSERT INTO notifications_fts(notifications_fts, rank) VALUES('merge', 16);

-- Full: rewrite into a single segment; O(index size); run weekly by the
-- maintenance job and after a bulk import.
INSERT INTO notifications_fts(notifications_fts) VALUES('optimize');
```

`optimize` on the 100k fixture takes ~1.5 s on an M1 and holds the write lock for that time; the maintenance job runs it only when the popover has been closed for at least 30 s and no import is running. See [MAINTENANCE.md](../operations/MAINTENANCE.md#fts-optimize).

### WAL checkpointing

The archive runs in WAL mode so timeline reads never block on capture writes. SQLite's default `wal_autocheckpoint = 1000` pages (~4 MB) is kept. Two extra steps prevent the WAL from growing when a reader is always present (the popover's `ValueObservation` keeps a read transaction open while it is visible):

```swift
// BackglanceCore/Archive+Maintenance.swift
import GRDB

extension Archive {
    /// Called after importExisting() and by the 6-hourly maintenance job.
    public func checkpointIfNeeded() throws {
        try pool.writeWithoutTransaction { db in
            // TRUNCATE resets the -wal file to zero bytes when no reader holds it;
            // PASSIVE is the fallback that never blocks.
            do {
                try db.checkpoint(.truncate)
            } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY {
                try db.checkpoint(.passive)
            }
        }
    }
}
```

`Archive` also sets `PRAGMA journal_size_limit = 8388608` (8 MB) in `Configuration.prepareDatabase`, which caps the WAL file on disk after a checkpoint even if it grew during an import.

## Search latency

### FTS: p95 under 50 ms

The FTS path is `QueryParser` → one `MATCH` with `bm25()` ranking → join → hydrate 200 rows. On the 100k fixture, an M1 MacBook Air, warm cache:

| Query shape | p50 | p95 |
|---|---|---|
| single term `invoice` | 4 ms | 9 ms |
| prefix `inv*` (as-you-type) | 6 ms | 14 ms |
| phrase `"meeting moved"` | 5 ms | 12 ms |
| term + filters `from:slack before:2026-08-01 invoice` | 7 ms | 18 ms |
| very common term (`the`, > 40k hits) | 21 ms | 44 ms |

The common-term case is the one that decides the budget. It is kept under 50 ms by the candidate cap (`LIMIT 2000` on the FTS subquery ordered by `rank`) and by `bm25()` weights that favour title matches so the top 2,000 are the useful ones. Queries shorter than 2 characters are not sent to FTS at all; the timeline simply filters the loaded page.

### Hybrid: p95 under 250 ms

`HybridSearch` combines three signals with the ported PasteShelf weights (FTS 0.4, semantic 0.5, fuzzy 0.3):

```
query ──▶ QueryParser ──▶ FTS candidates (≤ 2000, ranked)
                    │
                    ├──▶ Fuzzy: Levenshtein ≥ 0.6 against titles/senders of the
                    │           FTS candidates + last 500 timeline rows (no full scan)
                    │
                    └──▶ Semantic (if enabled): embed query once (~8 ms),
                                cosine vs candidate vectors read in chunks
                    ▼
            score merge → dedupe by id → top 200
```

Fuzzy matching is deliberately bounded to candidates already in memory. Levenshtein against 100k titles would alone blow the budget (≈ 100k × 30 × 30 cell updates ≈ 90 M operations ≈ 150–300 ms in Swift). Against ≤ 2,500 rows it is < 10 ms.

### Semantic cost math

`NLEmbedding.sentenceEmbedding(for: .english)` produces 512 `Double`s; `SemanticIndex` stores them as 512 `Float32` in a BLOB (2,048 bytes). At 100k notifications:

- 100,000 × 512 × 4 bytes = 204,800,000 bytes ≈ **200 MB** of vectors.
- Keeping that resident would triple the memory budget on its own, so vectors are **never** loaded wholesale.
- A brute-force cosine over 100k vectors with `vDSP_dotpr` is ~10–20 ms of arithmetic; the real cost is reading and decoding 200 MB of BLOBs from SQLite (~400–800 ms cold). That is what breaks the 250 ms budget, not the math.

Therefore:

1. **Candidates are pre-filtered.** When the query has FTS hits, only their vectors are scored (≤ 2,000 rows ≈ 4 MB). When it has none (a purely semantic query such as "that thing about the flight"), the candidate set is a date window: newest first, at most 20,000 rows (~40 MB), which covers roughly the last few weeks on a busy machine. The user can widen the window with `before:`/`after:` filters.
2. **Vectors are read in chunks** of 500 rows (≈ 1 MB per chunk) via a prepared `SELECT notification_id, vector FROM embeddings WHERE notification_id IN (...)`, scored, and discarded before the next chunk. Peak extra memory during a semantic query is therefore ~2 MB, and it is released at the end.

```swift
// BackglanceSearch/SemanticIndex+Query.swift (excerpt)
import Accelerate
import GRDB

extension SemanticIndex {
    static let chunkSize = 500

    /// Score candidates against `query` (already L2-normalised), returning the best `k`.
    func score(candidates: [Int64], query: [Float], k: Int, in pool: DatabasePool) throws -> [(id: Int64, cosine: Float)] {
        var heap: [(id: Int64, cosine: Float)] = []
        heap.reserveCapacity(k + 1)

        for chunk in stride(from: 0, to: candidates.count, by: Self.chunkSize) {
            let ids = Array(candidates[chunk..<min(chunk + Self.chunkSize, candidates.count)])
            let placeholders = databaseQuestionMarks(count: ids.count)
            let rows = try pool.read { db in
                try Row.fetchAll(db,
                    sql: "SELECT notification_id, vector FROM embeddings WHERE notification_id IN (\(placeholders))",
                    arguments: StatementArguments(ids))
            }
            for row in rows {
                let id: Int64 = row["notification_id"]
                let blob: Data = row["vector"]
                guard blob.count == 512 * MemoryLayout<Float>.size else { continue } // skip corrupt/foreign dims
                let dot: Float = blob.withUnsafeBytes { raw in
                    let v = raw.bindMemory(to: Float.self)
                    var out: Float = 0
                    vDSP_dotpr(v.baseAddress!, 1, query, 1, &out, 512)   // stored vectors are normalised at insert
                    return out
                }
                heap.append((id, dot))
                if heap.count > k * 4 {                       // keep the heap small; exact top-k at the end
                    heap.sort { $0.cosine > $1.cosine }
                    heap.removeLast(heap.count - k)
                }
            }
        }
        heap.sort { $0.cosine > $1.cosine }
        return Array(heap.prefix(k))
    }
}
```

Measured hybrid p95 on the 100k fixture with semantic on: 140–190 ms for FTS-backed queries, 210–240 ms for pure-semantic queries over the 20k window. The budget holds; it does not have much slack, which is why the window is capped.

### Background embedding generation

Embeddings are generated only when the "Semantic search" setting is on, and only in the background:

- batches of **50** notifications, oldest un-embedded first among the last 30 days, then older;
- `await Task.yield()` between batches, and a check of `isLowPowerModeEnabled` and "popover visible" before each batch (skip while either is true);
- one write transaction per batch (50 BLOB inserts ≈ 3 ms);
- throughput ≈ 400 notifications/s on M1 (`NLEmbedding` dominates), so a 100k backlog finishes in about five minutes of idle time and never blocks anything.

```swift
// BackglanceSearch/SemanticIndex+Backfill.swift (excerpt)
func backfill(archive: Archive) async throws {
    while !Task.isCancelled {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { try await Task.sleep(for: .seconds(60)); continue }
        let pending = try archive.pendingEmbeddingRows(limit: 50)   // id + text only
        if pending.isEmpty { return }                                // caught up; watcher restarts us on new rows
        let vectors = pending.compactMap { row in embed(row.text).map { (row.id, $0) } }
        try archive.insertEmbeddings(vectors, model: "nl.sentence.en.v1", dims: 512)
        await Task.yield()
    }
}
```

## Menu bar responsiveness

Budget: **< 100 ms** from status item click to first painted row. What makes it hold:

| Technique | Why |
|---|---|
| **Preloaded first page.** `TimelineStore` keeps the newest 200 rows in memory, refreshed by a GRDB `ValueObservation` on the timeline query. Opening the popover renders from memory; no query on the click path. | Removes the only I/O from the hot path |
| **`LazyVStack` with stable `Int64` IDs.** `ForEach(rows, id: \.id)`; rows are `Identifiable` by archive id, never by index or `UUID()`. | Stable identity lets SwiftUI diff 200 rows in < 5 ms instead of rebuilding them |
| **Fixed popover size, no SwiftUI-driven resizing.** `NSPopover.contentSize` is set once; `NSHostingController.sizingOptions = []` so SwiftUI does not push intrinsic-size changes back into AppKit on every scroll frame. | Avoids `NSHostingView` resize thrash, which showed up as 8–15 ms/frame in Instruments |
| **Icon cache.** `EnrichmentService` caches `NSImage` per bundle ID in an `NSCache` (limit 200) backed by the on-disk cache. Rows never call `NSWorkspace.shared.icon(forFile:)` directly. | An uncached icon lookup is 2–6 ms and would run 200 times on first paint |
| **No relative-time timers per row.** One `TimelineDateFormatterTicker` updates a single `@Published date` every 30 s; rows read it. | 200 timers would keep the app out of App Nap forever |
| **Pagination of 200.** Scrolling near the end appends the next keyset page; older pages are dropped beyond 1,000 rows. | Bounded memory, 60 fps scroll |

```swift
// Backglance/App/StatusItemController.swift (excerpt)
let hosting = NSHostingController(rootView: MenuBarPopoverView().environmentObject(timelineStore))
hosting.sizingOptions = []                       // we own the size; SwiftUI does not
popover.contentSize = NSSize(width: 380, height: 520)
popover.contentViewController = hosting
popover.behavior = .transient
```

The first-paint measurement is a signpost interval from `StatusItemController.togglePopover()` to `MenuBarPopoverView.onAppear` on the first row (see [Signposts](#signposts)).

## Memory footprint

Budgets: **< 60 MB RSS idle**, **< 150 MB with the timeline window open at 100k notifications**, embeddings excluded (they never live in memory beyond the 2 MB scoring window). Idle RSS on macOS 26 is typically 38–48 MB, most of it AppKit and SwiftUI runtime.

Rules that keep it there:

- **No in-memory full timeline.** Everything is paginated; `TimelineStore` holds at most 1,000 rows (~1 MB of Swift structs).
- **`DatabasePool` connection limits.** `Configuration.maximumReaderCount = 3` (default 5). Each reader connection carries a page cache; `PRAGMA cache_size = -2000` (2 MB) per connection keeps the pool at ≈ 8 MB worst case.
- **Thumbnails are never loaded.** `attachments_json` is metadata only; the archive never stores image bytes and the UI never opens attachment files.
- **`autoreleasepool` in import loops.** `PropertyListSerialization` and `Data` from the store's `record.data` BLOB are Objective-C objects; without a pool per batch, a 10k import held ~300 MB until the loop returned.

```swift
// BackglanceCapture/CaptureEngine+Import.swift (excerpt)
for batch in rawRecords.chunked(into: 500) {
    try autoreleasepool {
        let parsed = try batch.compactMap { try parser.parse($0) }   // plist decode happens here
        try archive.insertBatch(parsed, source: .import)
    }
    await Task.yield()
}
```

`MemoryFootprintTests` opens the 100k fixture, renders `TimelineView` in an offscreen `NSHostingView`, scrolls five pages and asserts `mach_task_basic_info.resident_size` < 150 MB; the idle test asserts < 60 MB after `Archive.shared` is opened and one capture tick has run.

## Import performance

`CaptureEngine.importExisting()` reads whatever the system store still holds (typically a few days, at most a few thousand rows; the budget uses **10k records < 10 s**). Measured: 10k synthetic records import in 3.8 s on M1, 7.9 s on a 2018 Intel MacBook Pro.

1. **Batched transactions of 500.** One transaction per 500 rows balances WAL growth against fsync count (20 commits for 10k rows instead of 10,000).
2. **Prepared statements.** `db.cachedStatement(sql:)` for the `notifications` insert and the `apps` upsert; arguments bound per row.
3. **FTS build after the bulk insert.** The `_ai` trigger is dropped for the duration of the import and the FTS index for the imported id range is built in one statement, then the trigger is recreated and `merge` runs. This produces one FTS segment instead of twenty and saves ~25 % wall time; correctness is guaranteed by `FTSIndexTests.testImportRebuildsFTSForRange`.

```swift
// BackglanceCore/Archive+Import.swift
import GRDB

extension Archive {
    public func importBatchesBuildingFTSAfter(_ batches: [[ParsedNotification]]) throws -> ClosedRange<Int64>? {
        var firstID: Int64?
        var lastID: Int64?

        try pool.write { db in try db.execute(sql: "DROP TRIGGER IF EXISTS notifications_ai") }
        defer {
            // Always restore the trigger, even if a batch failed.
            try? pool.write { db in try FTSIndex.createInsertTrigger(db) }
        }

        for batch in batches {
            try pool.write { db in
                let insert = try db.cachedStatement(sql: """
                    INSERT OR IGNORE INTO notifications
                      (uuid, app_id, title, subtitle, body, sender, thread_id, category,
                       delivered_at, captured_at, source, presented, deep_link, attachments_json, redaction, store_rec_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'import', ?, ?, ?, ?, ?)
                    """)
                for n in batch {
                    let appID = try upsertApp(bundleID: n.bundleID, in: db)   // cachedStatement inside
                    try insert.execute(arguments: n.insertArguments(appID: appID, capturedAt: Date()))
                    if db.changesCount == 1 {
                        let id = db.lastInsertedRowID
                        firstID = firstID ?? id
                        lastID = id
                    }
                }
            }
        }

        guard let f = firstID, let l = lastID else { return nil }
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO notifications_fts(rowid, title, subtitle, body, sender)
                SELECT id, title, subtitle, body, sender FROM notifications WHERE id BETWEEN ? AND ?
                """, arguments: [f, l])
            try db.execute(sql: "INSERT INTO notifications_fts(notifications_fts, rank) VALUES('merge', 16)")
        }
        try checkpointIfNeeded()
        return f...l
    }
}
```

> ⚠️ **Warning:** While the `_ai` trigger is dropped, live capture must not insert. `CaptureEngine` serialises `importExisting()` and `tick()` through the same actor, so this holds by construction; do not call `importBatchesBuildingFTSAfter` from anywhere else.

## Instrumentation

### Signposts

Every budgeted path is wrapped in an `OSSignposter` interval so Instruments' "os_signpost" track shows it without adding code:

```swift
// BackglanceCore/Perf.swift
import OSLog

public enum Perf {
    public static let signposter = OSSignposter(subsystem: "app.backglance.Backglance", category: "perf")

    /// Wraps a synchronous block in a signpost interval. Names are static, values are counts/durations only.
    public static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        defer { signposter.endInterval(name, state) }
        return try body()
    }
}

// Usage in CaptureEngine.tick():
// let inserted = try Perf.measure("capture.tick") { try archive.insertBatch(parsed, source: .live) }
// Perf.signposter.emitEvent("capture.tick.count", "\(inserted, privacy: .public)")
```

Interval names in use: `capture.tick`, `capture.snapshot`, `capture.parse`, `archive.insertBatch`, `search.fts`, `search.hybrid`, `search.semantic.score`, `popover.open`, `import.batch`, `retention.run`.

### xctrace

Record without opening Instruments (useful on a laptop where you want to reproduce the idle profile):

```bash
# 30 s time profile of the running app
xctrace record --template 'Time Profiler' --attach Backglance --time-limit 30s --output ~/Desktop/bg-idle.trace

# Signposts + CPU while you open the popover ten times
xctrace record --template 'App Launch' --attach Backglance --time-limit 60s --output ~/Desktop/bg-popover.trace

# Export the signpost table to XML for scripting
xctrace export --input ~/Desktop/bg-popover.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]' > popover-signposts.xml
```

The Energy Log template (`--template 'Energy Log'`) is the one to use before a release: it shows wakeups per second, which is the metric that actually correlates with battery drain for a mostly-idle agent.

### XCTMetric performance tests

Performance tests live next to the code they measure and are skipped unless `BACKGLANCE_PERF=1` is set — which **only the test plan's `Performance` configuration does**:

```bash
xcodebuild test -scheme Backglance -testPlan Backglance \
  -only-test-configuration Performance \
  -only-testing:BackglanceSearchTests/SearchLatencyTests
```

`env BACKGLANCE_PERF=1 xcodebuild test …` does not work: xcodebuild does not forward the invoking shell's environment into the test host, so the variable never arrives and every budget skips silently. Gate the suite with `PerfGate.isEnabled` (`BackglanceTestSupport`) rather than reading the variable directly:

```swift
// Tests/BackglanceSearchTests/SearchLatencyTests.swift
import XCTest
import GRDB
@testable import BackglanceCore
@testable import BackglanceSearch

final class SearchLatencyTests: XCTestCase {
    var archive: Archive!
    var search: HybridSearch!

    override func setUpWithError() throws {
        try XCTSkipUnless(PerfGate.isEnabled,
                          "set BACKGLANCE_PERF=1 to measure; runner variance exceeds these budgets")
        archive = try Archive(fixtureNamed: "archive-100k")     // copies Tests/Fixtures/Archive/archive-100k.sqlite to tmp
        search = HybridSearch(archive: archive, semantic: nil)
    }

    func testFTSCommonTermUnder50msP95() throws {
        let options = XCTMeasureOptions()
        options.iterationCount = 20
        measure(metrics: [XCTClockMetric()], options: options) {
            let hits = try? search.ftsOnly(SearchQuery(text: "the"), limit: 200)
            XCTAssertNotNil(hits)
        }
        // Baseline recorded in the .xcbaseline: 44 ms max on macos-26 runner.
    }

    func testHybridUnder250msP95() async throws {
        let options = XCTMeasureOptions()
        options.iterationCount = 20
        let query = SearchQuery(text: "invoice from:slack")
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let exp = expectation(description: "search")
            Task {
                do {
                    _ = try await search.search(query)
                } catch {
                    XCTFail("search failed: \(error)")
                }
                exp.fulfill()
            }
            wait(for: [exp], timeout: 5)
        }
    }
}
```

`ImportPerformanceTests` and `MemoryFootprintTests` follow the same pattern with `XCTClockMetric` and `XCTMemoryMetric`; `PopoverLaunchTests` uses `XCTOSSignpostMetric(subsystem:category:name:)` on `popover.open`. Baselines are stored per runner in the `.xcbaseline` bundle and are updated only by a deliberate commit that explains why.

## Regression budgets and CI policy

| Metric | Budget | Failure threshold in CI | Test |
|---|---|---|---|
| FTS common-term p95 | 50 ms | > 75 ms (baseline + 50 %) | `SearchLatencyTests.testFTSCommonTermUnder50msP95` |
| Hybrid p95 | 250 ms | > 375 ms | `SearchLatencyTests.testHybridUnder250msP95` |
| Import 10k | 10 s | > 15 s | `ImportPerformanceTests.testImport10k` |
| Popover first paint | 100 ms | > 150 ms | `PopoverLaunchTests.testFirstPaint` |
| Idle RSS | 60 MB | > 70 MB | `MemoryFootprintTests.testIdle` |
| Window open RSS at 100k | 150 MB | > 170 MB | `MemoryFootprintTests.testWindowAt100k` |
| Archive bytes/notification | 1.5 KB | > 2 KB | `ArchiveSizeTests.testBytesPerNotification` |
| Wakeups/s idle | < 1 | manual, Energy Log per release | release checklist |

Policy:

- **Pull requests** run the functional test plan only: `ci.yml` and `fixtures.yml` pass `-skip-test-configuration Performance`, so `BACKGLANCE_PERF` is unset and every budget skips. GitHub-hosted runner variance is larger than the budgets, and a perf test that fails because the machine was busy teaches everyone to ignore perf tests.
- **Nightly** (`.github/workflows/perf.yml`, `macos-26`) runs `-only-test-configuration Performance`, which is the only thing that sets `BACKGLANCE_PERF=1`, with the +50 % failure thresholds above. A failure opens an issue labelled `perf`; it does not block merges but does block the next release until triaged.
- **The gate is checked, not assumed.** `perf.yml` fails if any test in that run was *skipped* rather than executed. A budget that is never measured passes forever, which is exactly how these budgets went unmeasured through two milestones (BACKGLANCE-194) — so "the suite was green" now means "the suite ran".
- **Release** builds run the full perf suite locally on the developer's Mac (release checklist in [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md)) and the Energy Log check.
- Any PR that changes a hot path (`StoreWatcher`, `Archive+Timeline`, `FTSIndex`, `HybridSearch`, `SemanticIndex`, `TimelineView`) must paste `EXPLAIN QUERY PLAN` output for changed queries and a before/after number from a local `-only-test-configuration Performance` run in its description.
- Budgets in this table are the same numbers as in [ARCHITECTURE.md](../architecture/ARCHITECTURE.md) and [SEARCH.md](../features/SEARCH.md). Change them here first, then everywhere else, in one PR.

## Next Steps

- Run the perf suite locally: `xcodebuild test -scheme Backglance -testPlan Backglance -only-test-configuration Performance -only-testing:BackglanceSearchTests/SearchLatencyTests`.
- Record an Energy Log trace of the idle app for 10 minutes and confirm wakeups/s < 1 before tagging a release.
- Read [MONITORING_LOGGING.md](../operations/MONITORING_LOGGING.md) for the `capture` log category that shows tick triggers.

## Related Documentation

- [ARCHITECTURE.md](../architecture/ARCHITECTURE.md)
- [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md)
- [CAPTURE.md](../features/CAPTURE.md)
- [SEARCH.md](../features/SEARCH.md)
- [TIMELINE.md](../features/TIMELINE.md)
- [TESTING.md](../testing/TESTING.md)
- [CI_CD.md](./CI_CD.md)
- [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md)
- [MONITORING_LOGGING.md](../operations/MONITORING_LOGGING.md)
- [MAINTENANCE.md](../operations/MAINTENANCE.md)
