# Database Schema

Last Updated: 2026-08-18

This document describes the two databases Backglance touches. Part (a) is the **archive** — Backglance's own SQLite file, which we fully control, migrate, and index. Part (b) is the **system store** — Apple's Notification Center database (`usernoted`), which we only ever read, never own, and which is ⚠️ undocumented by Apple. Keeping the two clearly separated matters: the archive is a stable contract inside this codebase; the system store is an observation that we re-verify at every macOS release through fingerprints, adapters, and fixtures.

## Table of Contents

- [Part (a): The archive (Backglance's SQLite)](#part-a-the-archive-backglances-sqlite)
  - [Overview](#overview)
  - [File layout and permissions](#file-layout-and-permissions)
  - [PRAGMA settings](#pragma-settings)
  - [Canonical DDL](#canonical-ddl)
  - [Column reference](#column-reference)
  - [Indexes and why each exists](#indexes-and-why-each-exists)
  - [Relationships (ER diagram)](#relationships-er-diagram)
  - [Full-text search: FTS5 external-content table](#full-text-search-fts5-external-content-table)
  - [Dates: the UnixDate wrapper](#dates-the-unixdate-wrapper)
  - [GRDB models](#grdb-models)
  - [Associations](#associations)
  - [Migration strategy](#migration-strategy)
  - [Rules for writing migrations](#rules-for-writing-migrations)
  - [Integrity checks](#integrity-checks)
  - [Sample queries](#sample-queries)
- [Part (b): The system store (Apple's, undocumented)](#part-b-the-system-store-apples-undocumented)
  - [Path and access](#path-and-access)
  - [What we have observed](#what-we-have-observed)
  - [The versioned adapter interface](#the-versioned-adapter-interface)
  - [Computing a fingerprint from sqlite_master](#computing-a-fingerprint-from-sqlite_master)
  - [Decoding record.data (binary plist)](#decoding-recorddata-binary-plist)
  - [Read-only snapshot open](#read-only-snapshot-open)
  - [Fixtures-based test strategy](#fixtures-based-test-strategy)
  - [Per-version notes](#per-version-notes)
  - [Never document the system store as stable API](#never-document-the-system-store-as-stable-api)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

---

## Part (a): The archive (Backglance's SQLite)

### Overview

The archive is a single SQLite file managed through GRDB.swift 7.x. It holds every captured notification, per-app settings, rules, away sessions, digests, redaction events, and capture bookkeeping. It is opened through `Archive`, a `final class` wrapping a GRDB `DatabasePool` (WAL mode, one writer, concurrent readers). `Archive.shared` is used by the app; tests inject `Archive(inMemory: true)`.

| Property | Value |
|---|---|
| Path | `~/Library/Application Support/Backglance/archive.sqlite` |
| Engine | System SQLite (macOS 14+ ships FTS5) via GRDB.swift 7.x |
| Journal | WAL (`archive.sqlite-wal`, `archive.sqlite-shm`) |
| Encryption (v1.0) | none at the SQLite layer; relies on FileVault + `0600` file mode + own directory `0700` |
| Encryption (v1.x, optional) | SQLCipher via `GRDB.swift/SQLCipher`, key in Keychain |
| Size budget | ~1 KB per notification without attachment metadata; 100k notifications ≈ 100–150 MB including FTS |
| Time columns | `REAL`, Unix epoch seconds, written through the `UnixDate` wrapper |

> ℹ️ **Info:** In this document "archive" always means Backglance's own database. Apple's Notification Center database is always "the system store" (or "store" once introduced). We never call ours a "store".

### File layout and permissions

```
~/Library/Application Support/Backglance/          drwx------ (0700)
├── archive.sqlite                                  -rw------- (0600)
├── archive.sqlite-wal                              -rw------- (0600)
├── archive.sqlite-shm                              -rw------- (0600)
├── icons/                                          drwx------ (0700)  app icon cache (PNG, keyed by bundle id)
│   └── com.apple.MobileSMS.png
├── tmp/                                            drwx------ (0700)  system-store snapshots (short-lived)
│   └── snapshot-<uuid>/db, db-wal, db-shm
└── embeddings are inside archive.sqlite (table `embeddings`, v1.x)
```

`Archive.open()` creates the directory with mode `0700` if missing and, on every launch, re-applies `0600` to the three database files (they can be created by SQLite with the process umask). The `tmp/` directory is emptied on launch and after each successful capture pass; anything older than 10 minutes is deleted opportunistically.

```swift
import Foundation

enum ArchivePaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Backglance", isDirectory: true)
    }
    static var archiveURL: URL { supportDirectory.appendingPathComponent("archive.sqlite") }
    static var iconsDirectory: URL { supportDirectory.appendingPathComponent("icons", isDirectory: true) }
    static var tmpDirectory: URL { supportDirectory.appendingPathComponent("tmp", isDirectory: true) }

    /// Creates the support directory (0700) and tightens permissions on database files (0600).
    static func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: iconsDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: tmpDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: archiveURL.path + suffix)
            if fm.fileExists(atPath: url.path) {
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }
}
```

> 🔒 **Security:** The archive contains the text of notifications. It is never copied outside this directory by Backglance itself (exports go to `~/Downloads` only when the user asks). Panic wipe (`PanicWipe.execute()`) closes the pool, enables `secure_delete`, deletes the archive, WAL, SHM, `icons/`, `tmp/`, and embeddings, then recreates an empty archive. See [../features/PRIVACY_CONTROLS.md](../features/PRIVACY_CONTROLS.md).

### PRAGMA settings

Applied in `Configuration.prepareDatabase` so every connection in the pool gets them.

| PRAGMA | Value | Why |
|---|---|---|
| `journal_mode` | `WAL` | Concurrent readers while capture writes; set once by `DatabasePool` |
| `synchronous` | `NORMAL` | Safe with WAL (durable at checkpoint); avoids fsync per transaction on a battery-powered laptop |
| `foreign_keys` | `ON` | Cascades for `digest_items`, `redactions`, `snoozes`, `embeddings`; `SET NULL` for `away_session_id` |
| `secure_delete` | `ON` | Overwrites freed pages with zeros; deleted notification text does not linger in free pages |
| `journal_size_limit` | `67108864` (64 MB) | Caps the WAL file after checkpoints so a burst import does not leave a huge `-wal` behind |
| `busy_timeout` | `5000` ms | GRDB `busyMode = .timeout(5)`; readers wait briefly instead of failing during checkpoints |
| `temp_store` | `MEMORY` | FTS and sort temporaries stay off disk |

```swift
import GRDB

extension Archive {
    static func makeConfiguration(inMemory: Bool) -> Configuration {
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.foreignKeysEnabled = true                 // PRAGMA foreign_keys = ON
        config.label = "app.backglance.Backglance.archive"
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA secure_delete = ON")
            try db.execute(sql: "PRAGMA journal_size_limit = 67108864")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
        }
        #if DEBUG
        config.publicStatementArguments = true           // readable SQL in debug logs; never in Release
        #endif
        return config
    }
}
```

> ⚠️ **Warning:** `publicStatementArguments` must stay DEBUG-only. In Release, GRDB error messages redact bound values so notification text never reaches `backglance.log`.

### Canonical DDL

This is the source of truth for table and column names. Migrations execute exactly this SQL (see [Migration strategy](#migration-strategy)); models, queries, and docs derive from it.

```sql
CREATE TABLE apps (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  bundle_id TEXT NOT NULL UNIQUE,
  display_name TEXT,
  retention TEXT NOT NULL DEFAULT 'inherit',   -- '24h','7d','30d','forever','never','inherit'
  is_excluded INTEGER NOT NULL DEFAULT 0,      -- never store (exclusion list)
  is_muted INTEGER NOT NULL DEFAULT 0,         -- timeline de-prioritize (visual only)
  redact_otp INTEGER NOT NULL DEFAULT 0,       -- 1 for Messages/Mail by default
  first_seen_at REAL NOT NULL,
  last_seen_at REAL NOT NULL,
  notification_count INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE notifications (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  uuid TEXT NOT NULL UNIQUE,                   -- from store when present, else generated
  app_id INTEGER NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
  title TEXT, subtitle TEXT, body TEXT,
  sender TEXT, thread_id TEXT, category TEXT,
  delivered_at REAL NOT NULL,
  captured_at REAL NOT NULL,
  source TEXT NOT NULL DEFAULT 'live',         -- 'live' | 'import'
  presented INTEGER NOT NULL DEFAULT 1,        -- store's own "banner was shown" flag
  away_session_id INTEGER REFERENCES away_sessions(id) ON DELETE SET NULL,
  deep_link TEXT,
  attachments_json TEXT,                       -- [{"type":"image","name":"...","size":1234}] metadata only, never bytes
  redaction TEXT NOT NULL DEFAULT 'none',      -- 'none' | 'otp'
  is_read INTEGER NOT NULL DEFAULT 0,
  is_pinned INTEGER NOT NULL DEFAULT 0,
  is_deleted INTEGER NOT NULL DEFAULT 0,       -- soft delete; hard-pruned by retention job
  store_rec_id INTEGER                         -- rec_id in the system store (nullable, for dedup)
);
CREATE INDEX idx_notifications_delivered ON notifications(delivered_at DESC);
CREATE INDEX idx_notifications_app_delivered ON notifications(app_id, delivered_at DESC);
CREATE INDEX idx_notifications_thread ON notifications(thread_id);
CREATE INDEX idx_notifications_away ON notifications(away_session_id);
CREATE UNIQUE INDEX idx_notifications_store_rec ON notifications(store_rec_id) WHERE store_rec_id IS NOT NULL;

CREATE VIRTUAL TABLE notifications_fts USING fts5(
  title, subtitle, body, sender,
  content='notifications', content_rowid='id',
  tokenize = "unicode61 remove_diacritics 2 tokenchars '@.-'",
  prefix = '2 3'
);
-- triggers notifications_ai / _ad / _au keep FTS in sync (external content pattern)

CREATE TABLE rules (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,                          -- 'highlight' | 'vip' | 'mute' | 'regex'
  pattern TEXT NOT NULL,                       -- keyword, sender, bundle id, or regex source
  match_field TEXT NOT NULL DEFAULT 'any',     -- 'any' | 'title' | 'body' | 'sender' | 'app'
  app_bundle_id TEXT,                          -- scope to one app (nullable)
  color TEXT,                                  -- highlight color token e.g. 'amber'
  priority INTEGER NOT NULL DEFAULT 0,
  is_enabled INTEGER NOT NULL DEFAULT 1,
  created_at REAL NOT NULL
);
CREATE TABLE away_sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at REAL NOT NULL, ended_at REAL,
  reason TEXT NOT NULL                         -- 'locked' | 'asleep' | 'focus' | 'presenting' | 'manual'
);
CREATE TABLE digests (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  away_session_id INTEGER NOT NULL REFERENCES away_sessions(id) ON DELETE CASCADE,
  created_at REAL NOT NULL, shown_at REAL, dismissed_at REAL,
  item_count INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE digest_items (
  digest_id INTEGER NOT NULL REFERENCES digests(id) ON DELETE CASCADE,
  notification_id INTEGER NOT NULL REFERENCES notifications(id) ON DELETE CASCADE,
  rank INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (digest_id, notification_id)
);
CREATE TABLE redactions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  notification_id INTEGER NOT NULL REFERENCES notifications(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,                          -- 'otp'
  pattern_id TEXT NOT NULL,                    -- e.g. 'otp.keyword.en'
  redacted_at REAL NOT NULL
);                                             -- NEVER stores the original text
CREATE TABLE capture_state (
  key TEXT PRIMARY KEY,                        -- 'cursor', 'fingerprint', 'adapter_id', 'last_import_at'
  value TEXT NOT NULL
);
CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);   -- 'archive_version'
-- v1.x
CREATE TABLE saved_searches (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, query TEXT NOT NULL, is_smart_folder INTEGER NOT NULL DEFAULT 0, sort_order INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL);
CREATE TABLE snoozes (id INTEGER PRIMARY KEY AUTOINCREMENT, notification_id INTEGER NOT NULL REFERENCES notifications(id) ON DELETE CASCADE, fire_at REAL NOT NULL, fired_at REAL, reminders_identifier TEXT);
CREATE TABLE embeddings (notification_id INTEGER PRIMARY KEY REFERENCES notifications(id) ON DELETE CASCADE, model TEXT NOT NULL, dims INTEGER NOT NULL, vector BLOB NOT NULL, created_at REAL NOT NULL);
```

### Column reference

#### `apps`

One row per bundle identifier ever seen. Also carries per-app settings so a user's choices survive even if every notification for the app is pruned.

| Column | Type | Meaning |
|---|---|---|
| `id` | INTEGER PK | Surrogate key referenced by `notifications.app_id` |
| `bundle_id` | TEXT UNIQUE | Bundle identifier as reported by the system store (`app.identifier`), e.g. `com.apple.MobileSMS` |
| `display_name` | TEXT | Localized app name resolved by `EnrichmentService` at first sight; refreshed lazily |
| `retention` | TEXT | Per-app override of `RetentionPolicy`; `'inherit'` means use the global default (30 days) |
| `is_excluded` | INTEGER | `1` = never store (default exclusion list: password managers, `com.apple.Passwords`, Backglance itself). Existing rows are hard-deleted when this flips to `1` |
| `is_muted` | INTEGER | Timeline de-prioritization only; capture continues |
| `redact_otp` | INTEGER | Run `OTPRedactor` on this app; `1` by default for `com.apple.MobileSMS`, `com.apple.mail` |
| `first_seen_at` | REAL | Unix seconds of the first captured notification |
| `last_seen_at` | REAL | Unix seconds of the most recent captured notification |
| `notification_count` | INTEGER | Denormalized live count (maintained by the insert/prune paths; recomputed by `Archive.repairCounts()` if it drifts) |

#### `notifications`

| Column | Type | Meaning |
|---|---|---|
| `id` | INTEGER PK | Rowid; also `content_rowid` for FTS |
| `uuid` | TEXT UNIQUE | Store's `record.uuid` when present (16 bytes → uppercase UUID string); otherwise `UUID()` generated at capture. Used by `backglance://open?id=` |
| `app_id` | INTEGER FK | → `apps.id`, cascade delete |
| `title` / `subtitle` / `body` | TEXT | Text as decoded from the store's bplist (`titl`, `subt`, `body`); after `OTPRedactor` if applicable |
| `sender` | TEXT | Best-effort sender (Messages contact/handle, Mail from-name); nullable |
| `thread_id` | TEXT | Store's `thre` key; groups conversation threads |
| `category` | TEXT | Store's `cate` (UN category identifier); nullable |
| `delivered_at` | REAL | Store's `delivered_date` converted from Cocoa reference date to Unix seconds |
| `captured_at` | REAL | When Backglance wrote the row (Unix seconds) |
| `source` | TEXT | `'live'` (watcher) or `'import'` (`CaptureEngine.importExisting()`) |
| `presented` | INTEGER | Store's `presented` flag; `0` means the system did not show a banner (Focus, screen locked, etc.); feeds the digest |
| `away_session_id` | INTEGER FK | Set when `delivered_at` fell inside an away session; `SET NULL` if the session row is deleted |
| `deep_link` | TEXT | Resolved by `EnrichmentService` (`sms:`, `imessage:`, `message://`, `https://…`) |
| `attachments_json` | TEXT | JSON array of `AttachmentMeta` (`type`, `name`, `size`); metadata only, never attachment bytes |
| `redaction` | TEXT | `'none'` or `'otp'`; the UI shows a small badge for redacted rows |
| `is_read` | INTEGER | Cleared when the row scrolls into view in the popover or window |
| `is_pinned` | INTEGER | User pin; pinned rows are exempt from retention pruning |
| `is_deleted` | INTEGER | Soft delete (user swipe/⌫); hard-pruned by the retention job |
| `store_rec_id` | INTEGER | Store's `record.rec_id`; nullable; unique where present so a re-import cannot duplicate |

#### `rules`

| Column | Type | Meaning |
|---|---|---|
| `kind` | TEXT | `'highlight'` (color), `'vip'` (pin to top / VIP-first in digest), `'mute'` (visual de-prioritize), `'regex'` (pattern is a regex source) |
| `pattern` | TEXT | Keyword, sender, bundle id, or regex source depending on `kind`/`match_field` |
| `match_field` | TEXT | `'any'`, `'title'`, `'body'`, `'sender'`, `'app'` |
| `app_bundle_id` | TEXT | Restrict rule to one app; `NULL` = all apps |
| `color` | TEXT | Highlight color token: `'amber'`, `'red'`, `'green'`, `'blue'`, `'purple'` |
| `priority` | INTEGER | Higher wins when two highlight rules match |
| `is_enabled` | INTEGER | Toggle without deleting |
| `created_at` | REAL | Unix seconds |

> ℹ️ **Info:** Rules are visual triage only. They do not change what macOS delivers, and they never call back into Notification Center. See [../features/RULES.md](../features/RULES.md).

#### `away_sessions`, `digests`, `digest_items`

| Table.Column | Meaning |
|---|---|
| `away_sessions.started_at` / `ended_at` | Unix seconds; `ended_at` is `NULL` while the session is open |
| `away_sessions.reason` | `AwayReason` raw value: `locked`, `asleep`, `focus`, `presenting`, `manual` |
| `digests.away_session_id` | The session this digest summarizes; one digest per session at most |
| `digests.created_at` / `shown_at` / `dismissed_at` | Lifecycle timestamps; `shown_at` set once, so a digest is never shown twice |
| `digests.item_count` | Denormalized count of `digest_items` |
| `digest_items.rank` | Display order (VIP first, then per-app grouping, then `delivered_at`) |

#### `redactions`

| Column | Meaning |
|---|---|
| `notification_id` | The redacted notification |
| `kind` | `'otp'` (only kind in v1.0) |
| `pattern_id` | Which pattern fired, e.g. `otp.keyword.en`, `otp.keyword.tr`, `otp.keyword.de`, `otp.body-only` |
| `redacted_at` | Unix seconds |

> 🔒 **Security:** `redactions` never stores the original text or the code. Redaction happens in memory before the insert. There is no column that could hold it.

#### `capture_state`, `schema_meta`

| Key | Value |
|---|---|
| `capture_state.cursor` | JSON of `StoreCursor { lastRecID, lastDeliveredDate }` |
| `capture_state.fingerprint` | JSON of the last `StoreFingerprint` seen |
| `capture_state.adapter_id` | e.g. `"v26"` |
| `capture_state.last_import_at` | Unix seconds of the last `importExisting()` |
| `schema_meta.archive_version` | Integer string mirrored from the last applied migration (`"5"` after `v5_sync_metadata`); informational — GRDB's migrator is authoritative |

#### v1.x tables

| Table | Meaning |
|---|---|
| `saved_searches` | Named `QueryParser` strings; `is_smart_folder = 1` shows in the sidebar |
| `snoozes` | Local reminders scheduled by `SnoozeScheduler`; `reminders_identifier` links an optional EventKit reminder |
| `embeddings` | 512-dim `Float32` little-endian vector as BLOB (2048 bytes); `model` = `"nl.sentence.en.v1"`; only present when "Semantic search" is on |
| `sync_metadata` | CloudKit bookkeeping (see `v5_sync_metadata`); only populated when sync is opted in |

### Indexes and why each exists

| Index | Columns | Serves |
|---|---|---|
| `idx_notifications_delivered` | `(delivered_at DESC)` | Timeline pagination (`ORDER BY delivered_at DESC LIMIT 200 OFFSET ?`), heatmap bucketing, retention prune ranges |
| `idx_notifications_app_delivered` | `(app_id, delivered_at DESC)` | Per-app timeline filter and per-app retention prune without touching other apps' rows |
| `idx_notifications_thread` | `(thread_id)` | Thread grouping in the timeline ("3 more from this conversation") |
| `idx_notifications_away` | `(away_session_id)` | Digest building and "missed since away" queries |
| `idx_notifications_store_rec` | partial unique `(store_rec_id) WHERE store_rec_id IS NOT NULL` | Idempotent import: `INSERT … ON CONFLICT(store_rec_id) DO NOTHING`; the partial predicate keeps generated-uuid rows out of the uniqueness constraint |
| `sqlite_autoindex_notifications_1` | `(uuid)` implicit | `backglance://open?id=`, dedup when the store re-delivers a uuid with a new `rec_id` |
| `sqlite_autoindex_apps_1` | `(bundle_id)` implicit | App lookup on every capture |

Deliberately absent: an index on `is_read` (low cardinality; the unread badge query is bounded by `delivered_at`), and any index on `body`/`title` (FTS covers text).

### Relationships (ER diagram)

```
 apps 1 ────────────< notifications >──────────── 0..1 away_sessions
  │                        │  │  │                        │
  │                        │  │  │                        │ 1
  │                        │  │  │                        │
  │                        │  │  └──< redactions          │
  │                        │  │                          digests
  │                        │  └────< snoozes    (v1.x)     │
  │                        │                               │
  │                        ├──── 1:1 embeddings (v1.x)     │
  │                        │                               │
  │                        └────< digest_items >───────────┘
  │                                (digest_id, notification_id)
  │
  └── rules.app_bundle_id is a soft reference by bundle_id (no FK; rules survive app row deletion)

 notifications_fts  (external content, rowid = notifications.id, kept in sync by triggers)
 capture_state, schema_meta, saved_searches, sync_metadata: standalone
```

Cascade summary:

| Delete | Effect |
|---|---|
| `apps` row | all its `notifications` (and transitively FTS rows, redactions, digest_items, snoozes, embeddings) |
| `notifications` row | FTS row (trigger), `redactions`, `digest_items`, `snoozes`, `embeddings` |
| `away_sessions` row | its `digests` (cascade); `notifications.away_session_id` → `NULL` |
| `digests` row | its `digest_items` |

### Full-text search: FTS5 external-content table

`notifications_fts` indexes `title`, `subtitle`, `body`, `sender` without duplicating the text; the content lives in `notifications` (`content='notifications', content_rowid='id'`). Three triggers keep it consistent. These are executed verbatim by the `v1_fts` migration.

```sql
CREATE TRIGGER notifications_ai AFTER INSERT ON notifications BEGIN
  INSERT INTO notifications_fts(rowid, title, subtitle, body, sender)
  VALUES (new.id, new.title, new.subtitle, new.body, new.sender);
END;

CREATE TRIGGER notifications_ad AFTER DELETE ON notifications BEGIN
  INSERT INTO notifications_fts(notifications_fts, rowid, title, subtitle, body, sender)
  VALUES ('delete', old.id, old.title, old.subtitle, old.body, old.sender);
END;

CREATE TRIGGER notifications_au AFTER UPDATE OF title, subtitle, body, sender ON notifications BEGIN
  INSERT INTO notifications_fts(notifications_fts, rowid, title, subtitle, body, sender)
  VALUES ('delete', old.id, old.title, old.subtitle, old.body, old.sender);
  INSERT INTO notifications_fts(rowid, title, subtitle, body, sender)
  VALUES (new.id, new.title, new.subtitle, new.body, new.sender);
END;
```

Tokenizer choices:

| Option | Why |
|---|---|
| `unicode61` | Unicode-aware word boundaries (Turkish, German text in the developer's own notifications) |
| `remove_diacritics 2` | `doğrulama` matches `dogrulama`; full Unicode diacritic folding |
| `tokenchars '@.-'` | Keeps `alex@example.com`, `v1.0.0`, `INV-2026-08` as single tokens |
| `prefix = '2 3'` | Fast prefix queries (`inv*`) for type-ahead; the fuzzy layer builds on prefix hits |

> 💡 **Tip:** After a bulk import, run `INSERT INTO notifications_fts(notifications_fts) VALUES('optimize');` (exposed as `Archive.optimizeFTS()`, scheduled by `MAINTENANCE` tasks) to merge FTS b-trees. If FTS ever disagrees with content (a crash mid-trigger), `INSERT INTO notifications_fts(notifications_fts) VALUES('rebuild');` re-derives it from `notifications`.

### Dates: the UnixDate wrapper

All `*_at` columns are `REAL` Unix epoch seconds. In Swift they are `UnixDate`, a `DatabaseValueConvertible` wrapper around `Date`. Storing REAL (rather than GRDB's default ISO-8601 text) keeps range scans on `delivered_at` cheap and makes ad-hoc `sqlite3` queries readable.

```swift
import Foundation
import GRDB

/// A `Date` persisted as REAL Unix epoch seconds.
public struct UnixDate: Hashable, Codable, Sendable {
    public var date: Date

    public init(_ date: Date) { self.date = date }
    public static var now: UnixDate { UnixDate(Date()) }

    // Codable: encode/decode as a plain Double so JSON exports and GRDB agree.
    public init(from decoder: Decoder) throws {
        let seconds = try decoder.singleValueContainer().decode(Double.self)
        date = Date(timeIntervalSince1970: seconds)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(date.timeIntervalSince1970)
    }
}

extension UnixDate: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { date.timeIntervalSince1970.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> UnixDate? {
        // Accept INTEGER too: hand-written fixtures and old sqlite3 sessions sometimes insert ints.
        if let seconds = Double.fromDatabaseValue(dbValue) {
            return UnixDate(Date(timeIntervalSince1970: seconds))
        }
        return nil
    }
}

extension UnixDate: Comparable {
    public static func < (lhs: UnixDate, rhs: UnixDate) -> Bool { lhs.date < rhs.date }
}
```

> ⚠️ **Warning:** The system store uses the Cocoa reference date (seconds since 2001-01-01). Conversion happens exactly once, in `RecordParser`, with `Date(timeIntervalSinceReferenceDate:)`. Nothing downstream of `ParsedNotification` should ever see a Cocoa-epoch number.

### GRDB models

All models are `Codable, FetchableRecord, MutablePersistableRecord` with an explicit `databaseTableName` and snake_case column mapping.

`MutablePersistableRecord` rather than `PersistableRecord`, because these are structs that need to learn their own autoincrement id: GRDB's `didInsert(_:)` is `mutating` on the mutable protocol and non-mutating on the other, so the pairing below only compiles this way. They live in `Packages/BackglanceCore/Sources/BackglanceCore/Models/`.

```swift
import Foundation
import GRDB

public enum RetentionPolicy: String, Codable, Sendable {
    case hours24 = "24h", days7 = "7d", days30 = "30d", forever, never
}

/// Per-app retention as stored in `apps.retention` (adds `inherit` on top of `RetentionPolicy`).
public enum AppRetention: RawRepresentable, Codable, Hashable, Sendable {
    case inherit
    case policy(RetentionPolicy)

    public init?(rawValue: String) {
        if rawValue == "inherit" { self = .inherit; return }
        guard let p = RetentionPolicy(rawValue: rawValue) else { return nil }
        self = .policy(p)
    }
    public var rawValue: String {
        switch self {
        case .inherit: return "inherit"
        case .policy(let p): return p.rawValue
        }
    }
}

public struct AppRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "apps"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var bundleId: String
    public var displayName: String?
    public var retention: AppRetention = .inherit
    public var isExcluded: Bool = false
    public var isMuted: Bool = false
    public var redactOtp: Bool = false
    public var firstSeenAt: UnixDate
    public var lastSeenAt: UnixDate
    public var notificationCount: Int = 0

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public static let notifications = hasMany(ArchivedNotification.self)
}

public struct ArchivedNotification: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "notifications"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public enum Source: String, Codable, Sendable { case live, imports = "import" }
    public enum Redaction: String, Codable, Sendable { case none, otp }

    public var id: Int64?
    public var uuid: String
    public var appId: Int64
    public var title: String?
    public var subtitle: String?
    public var body: String?
    public var sender: String?
    public var threadId: String?
    public var category: String?
    public var deliveredAt: UnixDate
    public var capturedAt: UnixDate
    public var source: Source = .live
    public var presented: Bool = true
    public var awaySessionId: Int64?
    public var deepLink: String?
    public var attachmentsJson: String?
    public var redaction: Redaction = .none
    public var isRead: Bool = false
    public var isPinned: Bool = false
    public var isDeleted: Bool = false
    public var storeRecId: Int64?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public static let app = belongsTo(AppRecord.self)
    public static let awaySession = belongsTo(AwaySession.self)
    public static let redactions = hasMany(RedactionEvent.self)
}

public struct Rule: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "rules"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public enum Kind: String, Codable, Sendable { case highlight, vip, mute, regex }
    public enum MatchField: String, Codable, Sendable { case any, title, body, sender, app }

    public var id: Int64?
    public var kind: Kind
    public var pattern: String
    public var matchField: MatchField = .any
    public var appBundleId: String?
    public var color: String?
    public var priority: Int = 0
    public var isEnabled: Bool = true
    public var createdAt: UnixDate

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum AwayReason: String, Codable, Sendable { case locked, asleep, focus, presenting, manual }

public struct AwaySession: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "away_sessions"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var startedAt: UnixDate
    public var endedAt: UnixDate?
    public var reason: AwayReason

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public static let notifications = hasMany(ArchivedNotification.self)
    public static let digest = hasOne(Digest.self)
}

public struct Digest: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "digests"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var awaySessionId: Int64
    public var createdAt: UnixDate
    public var shownAt: UnixDate?
    public var dismissedAt: UnixDate?
    public var itemCount: Int = 0

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    public static let awaySession = belongsTo(AwaySession.self)
    public static let items = hasMany(DigestItem.self)
    public static let notifications = hasMany(ArchivedNotification.self, through: items, using: DigestItem.notification)
}

public struct DigestItem: Codable, FetchableRecord, MutablePersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "digest_items"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var digestId: Int64
    public var notificationId: Int64
    public var rank: Int = 0

    public static let digest = belongsTo(Digest.self)
    public static let notification = belongsTo(ArchivedNotification.self)
}

public struct RedactionEvent: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "redactions"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var notificationId: Int64
    public var kind: String = "otp"
    public var patternId: String
    public var redactedAt: UnixDate

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Key/value bookkeeping for the capture pipeline (`capture_state`).
///
/// ⚠️ Illustrative only — there is no `CaptureState` record type in the codebase, and
/// none is planned. `capture_state` and `schema_meta` are two-column key/value tables
/// with nothing to map, so `Archive+CaptureState.swift` reads and writes them with typed
/// accessors over raw SQL (`captureStateJSON(_:as:)`, `saveCursor(_:)`, `saveAdapterID(_:)`)
/// and the keys live in `CaptureStateKey`. Shown here because the *shape* of the table is
/// what this document is about.
public struct CaptureState: Codable, FetchableRecord, MutablePersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "capture_state"

    public enum Key: String, Codable, Sendable { case cursor, fingerprint, adapterId = "adapter_id", lastImportAt = "last_import_at" }

    public var key: Key
    public var value: String
}
```

### Associations

GRDB infers the joins from the foreign keys declared in the DDL, so the associations above need no explicit column lists.

```swift
import GRDB

extension Archive {
    /// A timeline row: notification + its app (one query, one struct).
    public struct TimelineRow: Decodable, FetchableRecord, Sendable {
        public var notification: ArchivedNotification
        public var app: AppRecord
    }

    /// First page of the timeline with app rows joined in.
    public func timelinePage(offset: Int, limit: Int = 200) throws -> [TimelineRow] {
        try pool.read { db in
            try ArchivedNotification
                .filter(Column("is_deleted") == false)
                .including(required: ArchivedNotification.app)
                .order(Column("delivered_at").desc)
                .limit(limit, offset: offset)
                .asRequest(of: TimelineRow.self)
                .fetchAll(db)
        }
    }

    /// Notifications that belong to a digest, in display order.
    public func notifications(in digest: Digest) throws -> [ArchivedNotification] {
        try pool.read { db in
            try digest.request(for: Digest.notifications)
                .order(Column("rank"))
                .fetchAll(db)
        }
    }
}
```

### Migration strategy

Migrations live in `Packages/BackglanceCore/Sources/BackglanceCore/Archive/ArchiveMigrations.swift` and are applied by a `DatabaseMigrator` when `Archive` opens. Names are stable forever; `eraseDatabaseOnSchemaChange = true` is DEBUG-only so a developer editing a migration in place gets a fresh archive instead of a confusing half-state.

```swift
import Foundation
import GRDB

enum ArchiveMigrations {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_initial") { db in
            try db.execute(sql: Self.v1InitialSQL)          // the canonical DDL minus FTS + v1.x tables
            try db.execute(sql: "INSERT INTO schema_meta(key, value) VALUES ('archive_version', '1')")
        }

        migrator.registerMigration("v1_fts") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE notifications_fts USING fts5(
                  title, subtitle, body, sender,
                  content='notifications', content_rowid='id',
                  tokenize = "unicode61 remove_diacritics 2 tokenchars '@.-'",
                  prefix = '2 3'
                );
                """)
            try db.execute(sql: Self.ftsTriggersSQL)         // notifications_ai / _ad / _au
            // Backfill for archives created before FTS existed (no-op on a fresh install).
            try db.execute(sql: "INSERT INTO notifications_fts(notifications_fts) VALUES ('rebuild')")
        }

        migrator.registerMigration("v2_embeddings") { db in
            try db.execute(sql: """
                CREATE TABLE embeddings (
                  notification_id INTEGER PRIMARY KEY REFERENCES notifications(id) ON DELETE CASCADE,
                  model TEXT NOT NULL,
                  dims INTEGER NOT NULL,
                  vector BLOB NOT NULL,
                  created_at REAL NOT NULL
                );
                """)
            try setArchiveVersion(db, 2)
        }

        migrator.registerMigration("v3_saved_searches") { db in
            try db.execute(sql: """
                CREATE TABLE saved_searches (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  name TEXT NOT NULL,
                  query TEXT NOT NULL,
                  is_smart_folder INTEGER NOT NULL DEFAULT 0,
                  sort_order INTEGER NOT NULL DEFAULT 0,
                  created_at REAL NOT NULL
                );
                """)
            try setArchiveVersion(db, 3)
        }

        migrator.registerMigration("v4_snoozes") { db in
            try db.execute(sql: """
                CREATE TABLE snoozes (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  notification_id INTEGER NOT NULL REFERENCES notifications(id) ON DELETE CASCADE,
                  fire_at REAL NOT NULL,
                  fired_at REAL,
                  reminders_identifier TEXT
                );
                CREATE INDEX idx_snoozes_fire ON snoozes(fire_at) WHERE fired_at IS NULL;
                """)
            try setArchiveVersion(db, 4)
        }

        migrator.registerMigration("v5_sync_metadata") { db in
            // CloudKit bookkeeping (opt-in, v1.x). One row per synced local row.
            try db.execute(sql: """
                CREATE TABLE sync_metadata (
                  entity TEXT NOT NULL,                     -- 'notifications' | 'rules' | 'apps' | 'saved_searches'
                  local_id INTEGER NOT NULL,
                  ck_record_name TEXT NOT NULL,
                  ck_change_tag TEXT,
                  synced_at REAL,
                  PRIMARY KEY (entity, local_id)
                );
                CREATE UNIQUE INDEX idx_sync_metadata_record ON sync_metadata(ck_record_name);
                """)
            try setArchiveVersion(db, 5)
        }

        return migrator
    }

    private static func setArchiveVersion(_ db: Database, _ v: Int) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO schema_meta(key, value) VALUES ('archive_version', ?)",
                       arguments: [String(v)])
    }

    // v1InitialSQL and ftsTriggersSQL are string constants holding the DDL shown in this document.
    static let v1InitialSQL: String = ArchiveDDL.v1Initial
    static let ftsTriggersSQL: String = ArchiveDDL.ftsTriggers
}
```

Opening and migrating:

```swift
import GRDB

public final class Archive: Sendable {
    /// `DatabasePool` on disk, `DatabaseQueue` in memory (tests). Both are `DatabaseWriter`.
    let pool: any DatabaseWriter

    public static let shared: Archive = {
        do { return try Archive.open() }
        catch { fatalError("Archive cannot open: \(error)") }   // surfaced in onboarding before we get here
    }()

    public static func open() throws -> Archive {
        try ArchivePaths.prepare()
        let pool = try DatabasePool(path: ArchivePaths.archiveURL.path,
                                    configuration: makeConfiguration(inMemory: false))
        try ArchiveMigrations.migrator().migrate(pool)
        return Archive(writer: pool)
    }

    /// In-memory archive for tests. Migrations run the same way.
    public convenience init(inMemory: Bool) throws {
        precondition(inMemory, "Use Archive.open() for on-disk archives")
        let queue = try DatabaseQueue(configuration: Archive.makeConfiguration(inMemory: true))
        try ArchiveMigrations.migrator().migrate(queue)
        self.init(writer: queue)
    }

    init(writer: any DatabaseWriter) { self.pool = writer }
}
```

> ℹ️ **Info:** `pool` is typed `any DatabaseWriter` so the in-memory `DatabaseQueue` and the on-disk `DatabasePool` share one code path. All `Archive` methods use `pool.read { }` / `pool.write { }`, which both types provide.

Migrations are numbered in **ship order**, which is not the order the features were designed in: `v2_embeddings` ships with semantic search in `0.3.0`, ahead of saved searches and snoozes, so it takes the number that follows `v1_fts`. This is not cosmetic — migration ordering is guaranteed by registration order, and a migration can never be slipped in front of one that has already been applied on someone's Mac. A new migration is always *appended*, and takes the next number when it does. Migration ordering is guaranteed by registration order. A `0.2.0` archive has `v1_initial` and `v1_fts` applied; upgrading applies `v2_…` through `v5_…` on first launch, in one transaction each. Downgrading is not supported (GRDB will refuse to open an archive with unknown migrations applied); the app shows a plain dialog explaining that.

### Rules for writing migrations

> ✅ **Do:**
> - Add a new named migration for every schema change. Names are `v<N>_<what>`, `N` = archive version.
> - Make changes additive: new tables, new nullable columns, new indexes.
> - Backfill in batches of 500 rows inside the migration only if the backfill is cheap; otherwise write a lazy backfill in the feature code (the FTS `rebuild` is the one exception — it is done in the migration because search is unusable without it).
> - Bump `schema_meta.archive_version` in the same migration.
> - Add a test in `Tests/BackglanceCoreTests/ArchiveMigrationTests.swift` that opens a fixture archive from the previous version and migrates it.

> ❌ **Don't:**
> - Never edit a migration that has shipped. Add another one.
> - Never rename a column or table in place. Add the new one, copy in batches, drop the old one in a later release once no code reads it.
> - Never `DROP` data-bearing tables in a migration that runs on user machines without a preceding release that stopped writing to them.
> - Never rely on `eraseDatabaseOnSchemaChange` outside DEBUG.

Batching pattern for a hypothetical future backfill:

```swift
migrator.registerMigration("v6_example_backfill") { db in
    try db.execute(sql: "ALTER TABLE notifications ADD COLUMN example_col TEXT")
    var lastID: Int64 = 0
    while true {
        let ids = try Int64.fetchAll(db, sql: """
            SELECT id FROM notifications WHERE id > ? ORDER BY id LIMIT 500
            """, arguments: [lastID])
        if ids.isEmpty { break }
        try db.execute(sql: """
            UPDATE notifications SET example_col = lower(coalesce(title, '')) WHERE id BETWEEN ? AND ?
            """, arguments: [ids.first!, ids.last!])
        lastID = ids.last!
    }
}
```

### Integrity checks

`Archive.checkIntegrity(level:)` runs on launch (quick) and from Settings ▸ Advanced ▸ "Check archive" (full). It reports a failed check as a *value* — `ArchiveHealth.ok == false` with messages — and throws `ArchiveError.integrityCheckFailed` only when the check could not be run at all. Results go to `backglance.log` and, on failure, to a non-modal banner offering "Rebuild search index" and "Reveal archive in Finder".

```swift
import GRDB

public struct ArchiveHealth: Sendable {
    public enum Level: Sendable { case quick, full }
    public let ok: Bool
    public let messages: [String]
}

extension Archive {
    public func checkIntegrity(level: ArchiveHealth.Level) throws -> ArchiveHealth {
        do {
            // Read-only checks share one snapshot.
            var messages = try pool.read { db -> [String] in
                let sql = level == .quick ? "PRAGMA quick_check" : "PRAGMA integrity_check"
                let rows = try String.fetchAll(db, sql: sql)
                var messages = rows.filter { $0 != "ok" }
                let fk = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
                if !fk.isEmpty { messages.append("foreign_key_check: \(fk.count) violation(s)") }
                return messages
            }

            // FTS self-check: compares index against content table. Needs a
            // write-capable connection — see the note below.
            do {
                try pool.write { db in
                    try db.execute(sql: "INSERT INTO notifications_fts(notifications_fts, rank) VALUES ('integrity-check', 1)")
                }
            } catch {
                messages.append("fts integrity-check failed: \(error)")
            }

            return ArchiveHealth(ok: messages.isEmpty, messages: messages)
        } catch {
            throw ArchiveError.integrityCheckFailed(String(describing: error))
        }
    }
}
```

> ⚠️ **Warning:** The FTS check cannot live inside `pool.read`. SQLite treats `INSERT INTO notifications_fts(notifications_fts, rank) VALUES ('integrity-check', 1)` as a write against the virtual table — the `xUpdate` hook fires even though nothing is persisted — and GRDB's read access (a `DatabasePool` reader opened `SQLITE_OPEN_READONLY`, or a `DatabaseQueue` read under `PRAGMA query_only`) refuses it with "attempt to write a readonly database". Folding the four checks back into one `pool.read` makes a healthy archive report itself unhealthy. The cost of the split is a moment of the single writer lock on a diagnostic call, and the two blocks not sharing one snapshot — acceptable, because a health check does not need snapshot isolation across its own checks.

> ℹ️ **Info:** The result type is named `ArchiveHealth`, with `Level` nested inside it — that is the name the code, the UI banner and [ARCHITECTURE.md](ARCHITECTURE.md#error-handling-patterns) use. Earlier drafts of this document called it `IntegrityReport` with a separate `IntegrityLevel`.

| Check | When | Cost at 100k notifications |
|---|---|---|
| `PRAGMA quick_check` | every launch | ~50–150 ms |
| `PRAGMA integrity_check` | on demand, after crash recovery | ~1–3 s |
| `PRAGMA foreign_key_check` | both | ~20 ms |
| FTS `integrity-check` | both | ~100–300 ms |

### Sample queries

All queries below are what `Archive` executes; SQL shown so contributors can reproduce them in `sqlite3`.

**Timeline page (200 rows, newest first):**

```sql
SELECT n.*, a.bundle_id, a.display_name
FROM notifications n
JOIN apps a ON a.id = n.app_id
WHERE n.is_deleted = 0
ORDER BY n.delivered_at DESC
LIMIT 200 OFFSET ?;
```

**Per-app counts (last 7 days):**

```sql
SELECT a.bundle_id, a.display_name, COUNT(*) AS n
FROM notifications n
JOIN apps a ON a.id = n.app_id
WHERE n.is_deleted = 0 AND n.delivered_at >= unixepoch('now', '-7 days')
GROUP BY a.id
ORDER BY n DESC;
```

**Missed since away (digest source set):**

```sql
SELECT n.*
FROM notifications n
JOIN away_sessions s ON s.id = ?1
WHERE n.is_deleted = 0
  AND (
        (n.delivered_at BETWEEN s.started_at AND coalesce(s.ended_at, unixepoch('now')))
     OR (n.presented = 0 AND n.delivered_at >= s.started_at - 60)
      )
ORDER BY n.delivered_at DESC;
```

**FTS with bm25 ranking and highlight():**

```sql
SELECT n.id, n.uuid, n.delivered_at,
       highlight(notifications_fts, 0, '<b>', '</b>') AS title_hl,
       highlight(notifications_fts, 2, '<b>', '</b>') AS body_hl,
       bm25(notifications_fts, 3.0, 1.5, 1.0, 2.0) AS score      -- weights: title, subtitle, body, sender
FROM notifications_fts
JOIN notifications n ON n.id = notifications_fts.rowid
WHERE notifications_fts MATCH ?1                                 -- e.g. 'invoice OR inv*'
  AND n.is_deleted = 0
ORDER BY score
LIMIT 50;
```

**Retention prune (global 30 days, honoring per-app override, pins, and soft deletes):**

```sql
DELETE FROM notifications
WHERE id IN (
  SELECT n.id
  FROM notifications n
  JOIN apps a ON a.id = n.app_id
  WHERE n.is_pinned = 0
    AND (
      n.is_deleted = 1
      OR (
        CASE coalesce(nullif(a.retention, 'inherit'), ?1)         -- ?1 = global policy string, e.g. '30d'
          WHEN '24h'     THEN n.delivered_at < unixepoch('now', '-1 day')
          WHEN '7d'      THEN n.delivered_at < unixepoch('now', '-7 days')
          WHEN '30d'     THEN n.delivered_at < unixepoch('now', '-30 days')
          WHEN 'never'   THEN 1                                    -- 'never' means keep nothing
          ELSE 0                                                    -- 'forever'
        END
      )
    )
  LIMIT 2000                                                      -- batch; the job loops until 0 rows
);
```

**Heatmap buckets (hour × weekday, last 30 days):**

```sql
SELECT CAST(strftime('%w', delivered_at, 'unixepoch', 'localtime') AS INTEGER) AS weekday,
       CAST(strftime('%H', delivered_at, 'unixepoch', 'localtime') AS INTEGER) AS hour,
       COUNT(*) AS n
FROM notifications
WHERE is_deleted = 0 AND delivered_at >= unixepoch('now', '-30 days')
GROUP BY weekday, hour;
```

---

## Part (b): The system store (Apple's, undocumented)

> ⚠️ **Warning:** Everything in this part describes an **undocumented, private Apple database**. This is what we have observed, not an API. Column names may change in any macOS release; the fingerprint + adapter + fixture strategy exists for that reason. Nothing here is a promise about how macOS behaves.

### Path and access

| Item | Value |
|---|---|
| Path | `~/Library/Group Containers/group.com.apple.usernoted/db2/db` (+ `db-wal`, `db-shm`) |
| Owner | `usernoted` (Notification Center daemon) |
| Journal | WAL — the interesting recent rows are often only in `db-wal` |
| Access | Requires **Full Disk Access** (FDA). Without FDA, `open(2)` fails with `EPERM`; Backglance reports `.degraded(.noFullDiskAccess)` |
| Our mode | Read-only, on a **copied snapshot**, never on the live file |
| Located by | `StoreLocation.current()` (throws `.storeNotFound` if the path does not exist) |

> 🔒 **Security:** FDA is why Backglance is not sandboxed and not on the Mac App Store. See [../features/PERMISSIONS_PRIVACY.md](../features/PERMISSIONS_PRIVACY.md).

### What we have observed

Layout observed on macOS 11–15 (public forensics writeups) and, in development testing, on macOS 26 (same layout, re-verified by fixture at every macOS point release):

| Table | Observed columns (illustrative) | Our use |
|---|---|---|
| `dbinfo` | `key`, `value` | Fingerprint input (`dbinfoVersion`) |
| `app` | `app_id` INTEGER PK, `identifier` TEXT, `badge` INTEGER, others | Map `record.app_id` → bundle identifier |
| `record` | `rec_id` INTEGER PK, `app_id`, `uuid` BLOB, `data` BLOB, `request_date` REAL, `request_last_date` REAL, `delivered_date` REAL, `presented` INTEGER, `style` INTEGER, `snooze_fire_date` REAL | The notification itself; `data` is a binary plist |
| `requests`, `delivered`, `displayed`, `snoozed`, `categories` | not relied upon | Present in fingerprint hash only |

Observed behaviors:

- `record.data` is a binary plist (`bplist00`).
- `delivered_date` and `request_date` are seconds since **2001-01-01** (Cocoa reference date), not Unix.
- `presented = 0` appears on records the system did not show as a banner (Focus, locked screen). This is the signal `DigestEngine` uses in addition to away-session timing.
- Records are pruned by the system after the user clears them and roughly after ~7 days. This is exactly why `importExisting()` recovers only "whatever still exists" and why the live watcher matters.
- The `uuid` BLOB is 16 bytes; some rows have `NULL` uuid, in which case Backglance generates one.

> ⚠️ **Warning:** "Observed" means: we looked at real stores on our own machines and at public writeups. We do not have Apple's schema definition, and Apple has no obligation to keep it. Treat every field name here as a hypothesis that a fixture confirms per macOS version.

### The versioned adapter interface

An **adapter** is a `StoreAdapter` implementation for one store schema fingerprint / macOS major version. The engine never touches store SQL directly; it asks the registry for an adapter and calls the protocol.

```swift
import Foundation
import GRDB

public struct StoreFingerprint: Hashable, Codable, Sendable {
    public let schemaHash: String                 // SHA-256 hex of normalized sqlite_master SQL
    public let dbinfoVersion: String?             // value of a version-like row in `dbinfo`, if any
    public let osVersion: OperatingSystemVersion
}

extension OperatingSystemVersion: @retroactive Codable, @retroactive Hashable {
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        self.init(majorVersion: try c.decode(Int.self), minorVersion: try c.decode(Int.self), patchVersion: try c.decode(Int.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(majorVersion); try c.encode(minorVersion); try c.encode(patchVersion)
    }
    public static func == (l: OperatingSystemVersion, r: OperatingSystemVersion) -> Bool {
        (l.majorVersion, l.minorVersion, l.patchVersion) == (r.majorVersion, r.minorVersion, r.patchVersion)
    }
    public func hash(into h: inout Hasher) { h.combine(majorVersion); h.combine(minorVersion); h.combine(patchVersion) }
}

public enum ProbeResult: Sendable, Equatable {
    case ok(recordCount: Int)
    case unknownSchema(details: String)
    case permissionDenied
    case missingTables([String])
}

public struct StoreCursor: Codable, Hashable, Sendable {
    public var lastRecID: Int64
    public var lastDeliveredDate: Double           // Cocoa reference seconds, as stored in the store
    public static let start = StoreCursor(lastRecID: 0, lastDeliveredDate: 0)
    public init(lastRecID: Int64, lastDeliveredDate: Double) {
        self.lastRecID = lastRecID; self.lastDeliveredDate = lastDeliveredDate
    }
}

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

public protocol StoreAdapter: Sendable {
    static var id: String { get }                             // "v14", "v15", "v26"
    static var supportedOS: ClosedRange<Int> { get }          // major versions, e.g. 14...14
    static func matches(_ fp: StoreFingerprint) -> Bool       // known-good fingerprints for this adapter
    func probe(_ db: Database) throws -> ProbeResult
    func records(after cursor: StoreCursor, in db: Database) throws -> [RawStoreRecord]
    func cursor(for record: RawStoreRecord) -> StoreCursor
}
```

A concrete adapter (shape of `StoreAdapterV26`; V14 and V15 differ only in known fingerprints and, if a release ever changes it, in the SQL):

```swift
import Foundation
import GRDB

public struct StoreAdapterV26: StoreAdapter {
    public static let id = "v26"
    public static let supportedOS: ClosedRange<Int> = 26...26
    // Filled from fixtures/manifest.json; updated when a point release changes the schema hash.
    static let knownSchemaHashes: Set<String> = StoreFingerprints.v26

    public init() {}

    public static func matches(_ fp: StoreFingerprint) -> Bool {
        knownSchemaHashes.contains(fp.schemaHash)
    }

    public func probe(_ db: Database) throws -> ProbeResult {
        let required = ["record", "app", "dbinfo"]
        let present = try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        let missing = required.filter { !present.contains($0) }
        if !missing.isEmpty { return .missingTables(missing) }
        let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(record)").map { $0["name"] as String }
        for needed in ["rec_id", "app_id", "data", "delivered_date"] where !cols.contains(needed) {
            return .unknownSchema(details: "record.\(needed) missing; columns: \(cols.joined(separator: ","))")
        }
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record") ?? 0
        return .ok(recordCount: count)
    }

    public func records(after cursor: StoreCursor, in db: Database) throws -> [RawStoreRecord] {
        // rec_id is monotonically increasing in every store we have observed; delivered_date is the
        // secondary guard for stores that were vacuumed and re-numbered.
        let rows = try Row.fetchAll(db, sql: """
            SELECT r.rec_id, a.identifier, r.uuid, r.data, r.delivered_date, r.request_date, r.presented, r.style
            FROM record r
            JOIN app a ON a.app_id = r.app_id
            WHERE r.rec_id > ? OR (r.delivered_date IS NOT NULL AND r.delivered_date > ?)
            ORDER BY r.rec_id
            LIMIT 2000
            """, arguments: [cursor.lastRecID, cursor.lastDeliveredDate])

        return rows.compactMap { row in
            guard let recID: Int64 = row["rec_id"], let identifier: String = row["identifier"],
                  let data: Data = row["data"] else { return nil }
            let uuidData: Data? = row["uuid"]
            let uuid = uuidData.flatMap(UUID.init(data:)) ?? UUID()
            let delivered: Double? = row["delivered_date"]
            let requested: Double? = row["request_date"]
            let presented: Int? = row["presented"]
            return RawStoreRecord(
                recID: recID, appIdentifier: identifier, uuid: uuid, plistData: data,
                deliveredDate: delivered.map { Date(timeIntervalSinceReferenceDate: $0) },
                requestDate: requested.map { Date(timeIntervalSinceReferenceDate: $0) },
                presented: (presented ?? 1) != 0,
                style: row["style"])
        }
    }

    public func cursor(for record: RawStoreRecord) -> StoreCursor {
        StoreCursor(lastRecID: record.recID,
                    lastDeliveredDate: record.deliveredDate?.timeIntervalSinceReferenceDate ?? 0)
    }
}

extension UUID {
    /// 16-byte BLOB → UUID; returns nil for any other length.
    init?(data: Data) {
        guard data.count == 16 else { return nil }
        let b = [UInt8](data)
        self.init(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
```

Registry resolution order (`StoreAdapterRegistry.resolve(fingerprint:)`):

```
1. exact fingerprint match   → adapter whose matches(fp) is true
2. OS-major fallback         → adapter whose supportedOS contains fp.osVersion.majorVersion,
                               accepted only if probe(db) returns .ok
3. newest adapter fallback   → (macOS 27 beta) try StoreAdapterV26.probe(); accept if .ok,
                               log "unverified fingerprint" and mark status .running with a warning
4. otherwise                 → CaptureStatus.degraded(.unknownSchema(fp))
```

```swift
public enum StoreAdapterRegistry {
    static let all: [any StoreAdapter.Type] = [StoreAdapterV14.self, StoreAdapterV15.self, StoreAdapterV26.self]

    public static func resolve(fingerprint fp: StoreFingerprint, probeIn db: Database) throws -> (any StoreAdapter)? {
        if let exact = all.first(where: { $0.matches(fp) }) {
            return exact.init()
        }
        let major = fp.osVersion.majorVersion
        let candidates = all.filter { $0.supportedOS.contains(major) } + [StoreAdapterV26.self]
        for type in candidates {
            let adapter = type.init()
            if case .ok = try adapter.probe(db) { return adapter }
        }
        return nil
    }
}
```

> ℹ️ **Info:** For `type.init()` to compile, `StoreAdapter` declares `init()` as a requirement in the real source. It is omitted from the protocol listing above only because CANON §5 fixes the protocol's public shape; the initializer is an implementation detail.

### Computing a fingerprint from sqlite_master

The fingerprint is a SHA-256 of the normalized `sql` column of every entry in `sqlite_master`, plus whatever version-like value `dbinfo` carries, plus the running OS version. Normalization (whitespace collapse, lowercase) keeps the hash stable across cosmetic differences while still changing on any real column change.

```swift
import CryptoKit
import Foundation
import GRDB

public enum StoreFingerprinter {
    public static func fingerprint(_ db: Database) throws -> StoreFingerprint {
        let statements = try String.fetchAll(db, sql: """
            SELECT sql FROM sqlite_master
            WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
            ORDER BY type, name
            """)
        let normalized = statements
            .map { $0.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        // dbinfo is a key/value table; we do not know the exact key name, so look for anything version-like.
        var dbinfoVersion: String? = nil
        if try db.tableExists("dbinfo") {
            let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM dbinfo")
            if let row = rows.first(where: { (($0["key"] as String?) ?? "").lowercased().contains("version") }) {
                dbinfoVersion = row["value"].map { "\($0)" }
            }
        }
        return StoreFingerprint(schemaHash: hex,
                                dbinfoVersion: dbinfoVersion,
                                osVersion: ProcessInfo.processInfo.operatingSystemVersion)
    }
}
```

The last fingerprint is persisted in `capture_state.fingerprint`. When it changes (macOS update), `CaptureEngine` re-resolves the adapter and logs `fingerprint changed: <old8> → <new8>` (first 8 hex chars, no content).

### Decoding record.data (binary plist)

`RecordParser` decodes the bplist with `PropertyListSerialization`. Key names are ⚠️ observed, not documented; lookup is tolerant (several candidate keys per field, first non-empty wins) and every field is optional except bundle id and delivered date.

```swift
import Foundation

public struct AttachmentMeta: Codable, Hashable, Sendable {
    public var type: String; public var name: String?; public var size: Int?
}

public struct ParsedNotification: Sendable {
    public var bundleID: String
    public var uuid: UUID
    public var title: String?
    public var subtitle: String?
    public var body: String?
    public var sender: String?
    public var threadID: String?
    public var category: String?
    public var deliveredAt: Date
    public var presented: Bool
    public var attachments: [AttachmentMeta]
    public var deepLink: URL?
    public var userInfo: [String: String]
}

public enum RecordParserError: Error, Sendable {
    case notAPlist(recID: Int64)
    case missingDeliveredDate(recID: Int64)
}

public struct RecordParser: Sendable {
    public init() {}

    public func parse(_ raw: RawStoreRecord) throws -> ParsedNotification {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let root = try? PropertyListSerialization.propertyList(from: raw.plistData, options: [], format: &format),
              let dict = root as? [String: Any] else {
            throw RecordParserError.notAPlist(recID: raw.recID)
        }
        // ⚠️ Observed keys: top-level "app", "date"; "req" dict with "titl", "subt", "body", "iden", "cate", "thre", "atta"/"attachments", "usda".
        let req = (dict["req"] as? [String: Any]) ?? dict

        // Delivered date: prefer the SQL column; fall back to plist "date" (Cocoa reference seconds or NSDate).
        let deliveredAt: Date
        if let d = raw.deliveredDate {
            deliveredAt = d
        } else if let d = dict["date"] as? Date {
            deliveredAt = d
        } else if let s = dict["date"] as? Double {
            deliveredAt = Date(timeIntervalSinceReferenceDate: s)
        } else {
            throw RecordParserError.missingDeliveredDate(recID: raw.recID)
        }

        let userInfoRaw = (req["usda"] as? [String: Any]) ?? [:]
        let userInfo = userInfoRaw.reduce(into: [String: String]()) { acc, kv in
            if let s = kv.value as? String { acc[kv.key] = s }          // strings only; blobs are dropped
        }
        let attachmentsRaw = (req["atta"] as? [[String: Any]]) ?? (req["attachments"] as? [[String: Any]]) ?? []
        let attachments = attachmentsRaw.map { a in
            AttachmentMeta(type: (a["type"] as? String) ?? "file", name: a["name"] as? String, size: a["size"] as? Int)
        }

        return ParsedNotification(
            bundleID: (dict["app"] as? String) ?? raw.appIdentifier,
            uuid: raw.uuid,
            title: string(req, "titl", "title"),
            subtitle: string(req, "subt", "subtitle"),
            body: string(req, "body"),
            sender: string(req, "sender", "from"),
            threadID: string(req, "thre", "thread"),
            category: string(req, "cate", "category"),
            deliveredAt: deliveredAt,
            presented: raw.presented,
            attachments: attachments,
            deepLink: nil,                     // EnrichmentService fills this later from userInfo
            userInfo: userInfo)
    }

    /// Tolerant lookup: first candidate key with a non-empty string wins.
    private func string(_ d: [String: Any], _ keys: String...) -> String? {
        for k in keys {
            if let s = d[k] as? String, !s.isEmpty { return s }
        }
        return nil
    }
}
```

> ⚠️ **Warning:** `PropertyListSerialization` returns `Date` for bplist date objects and `Double` for numbers; a store may use either for `date`. The parser accepts both. Any new key we discover goes into `Tests/Fixtures/SystemStore/<version>/expected.json` first, then into the parser.

### Read-only snapshot open

Backglance never opens Apple's live file for writing, and never holds a long-lived handle on it. Each capture pass:

```
1. copy   db, db-wal  (NOT db-shm)  →  ~/Library/Application Support/Backglance/tmp/<uuid>/
2. open   the copy on a plain path with Configuration.readonly = true and PRAGMA query_only = 1
          → SQLite recovers the copied WAL and builds a fresh -shm beside it
          → fingerprint, probe, records
3. delete the snapshot directory (taking the -shm with it)
```

Two things this ordering gets right, both of which earlier drafts of this document and of [ARCHITECTURE.md](./ARCHITECTURE.md) got wrong:

- **No `immutable=1`.** `immutable=1` promises SQLite the file cannot change, and SQLite takes that as licence to skip WAL processing entirely — so the newest rows, which live in `db-wal`, become invisible with no error at all. Measured on macOS 26: a copy holding one checkpointed row and one WAL-only row returned only the checkpointed one. There is no checkpoint step to compensate, because there is nothing to compensate for: a plain read-only open recovers the WAL by itself.
- **`-shm` is not copied.** It is a live wal-index belonging to `usernoted`, and a stale one can point at WAL frames our copy does not contain. SQLite rebuilds it from the copied `-wal`. The rebuilt `-shm` lands inside Backglance's own `0700` snapshot directory, never Apple's, and `discard()` removes it with everything else.

Opening our own copy read-write to checkpoint it — which an earlier draft prescribed — is therefore unnecessary, and the `sqlite3_config(SQLITE_CONFIG_URI, …)` call that went with it is not callable from Swift at all: it is a variadic C function and is marked unavailable.

```swift
import Foundation
import GRDB

public enum StoreSnapshotError: Error, Sendable {
    case storeNotFound
    case permissionDenied(underlying: Error)
    case copyFailed(underlying: Error)
}

public struct StoreSnapshot: Sendable {
    public let directory: URL
    public let dbURL: URL

    /// Copies db + wal + shm into tmp/ and returns a snapshot handle. Caller must `dispose()`.
    public static func make(from store: URL) throws -> StoreSnapshot {
        let fm = FileManager.default
        guard fm.fileExists(atPath: store.path) else { throw StoreSnapshotError.storeNotFound }
        let dir = ArchivePaths.tmpDirectory.appendingPathComponent("snapshot-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for suffix in ["", "-wal"] {                       // never -shm: usernoted's live wal-index
                let src = URL(fileURLWithPath: store.path + suffix)
                if fm.fileExists(atPath: src.path) {
                    try fm.copyItem(at: src, to: URL(fileURLWithPath: dir.appendingPathComponent("db").path + suffix))
                }
            }
        } catch let e as NSError where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoPermissionError {
            try? fm.removeItem(at: dir)
            throw StoreSnapshotError.permissionDenied(underlying: e)   // → CaptureStatus.degraded(.noFullDiskAccess)
        } catch {
            try? fm.removeItem(at: dir)
            throw StoreSnapshotError.copyFailed(underlying: error)
        }
        return StoreSnapshot(directory: dir, dbURL: dir.appendingPathComponent("db"))
    }

    /// Step 2: open read-only on a plain path. No checkpoint step and no `immutable=1` —
    /// SQLite recovers the copied WAL itself, which is the only way the newest rows are
    /// visible. See "Read-only snapshot open" above.
    public func openReadOnly() throws -> DatabaseQueue {
        var config = Configuration()
        config.readonly = true
        config.label = "app.backglance.Backglance.store-snapshot"
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA query_only = 1")       // belt and braces
        }
        return try DatabaseQueue(path: dbURL.path, configuration: config)
    }

    public func dispose() {
        try? FileManager.default.removeItem(at: directory)
    }
}
```

Usage inside `CaptureEngine`:

```swift
func capturePass() async throws -> [RawStoreRecord] {
    let snapshot = try StoreSnapshot.make(from: try StoreLocation.current())
    defer { snapshot.dispose() }
    let db = try snapshot.openReadOnly()
    return try db.read { db in
        let fp = try StoreFingerprinter.fingerprint(db)
        guard let adapter = try StoreAdapterRegistry.resolve(fingerprint: fp, probeIn: db) else {
            throw CaptureError.unknownSchema(fp)
        }
        return try adapter.records(after: currentCursor, in: db)
    }
}
```

> ⚠️ **Warning:** Do not reintroduce a `wal_checkpoint` step or an `immutable=1` open here. They travel together — the checkpoint only exists to paper over the rows `immutable=1` hides — and dropping both is what makes a plain read-only open correct. A regression test in `BackglanceCaptureTests` asserts that a row living only in `db-wal` is visible through `StoreSnapshot.read`.

### Fixtures-based test strategy

A **fixture** is a synthetic copy of a system store used in tests. Fixtures are the only way we assert anything about the store in CI, because CI runners have no real store content and we would never commit a real one.

Layout:

```
Tests/Fixtures/SystemStore/
├── macOS14/
│   ├── store.db          # synthetic, generated by Scripts/make_fixture.sh
│   ├── manifest.json     # what this fixture claims to represent
│   └── expected.json     # ParsedNotification[] the adapter+parser must produce
├── macOS15/
│   └── (same three files)
└── macOS26/
    └── (same three files)
```

`manifest.json` schema:

```json
{
  "schema_version": 1,
  "macos": "26.5",
  "macos_major": 26,
  "adapter_id": "v26",
  "fingerprint": {
    "schemaHash": "3f1c…(64 hex)",
    "dbinfoVersion": "17"
  },
  "generated_by": "make_fixture.sh",
  "generator_version": "1.0.0",
  "seed": 20260817,
  "record_count": 250,
  "tables": ["dbinfo", "app", "record", "requests", "delivered", "displayed", "snoozed", "categories"],
  "known_differences_from_previous": "none observed",
  "verified_on": "2026-08-17",
  "notes": "Synthetic. Schema mirrors what StoreAdapterV26 expects; content is generated from the seed."
}
```

| Field | Meaning |
|---|---|
| `schema_version` | Version of the manifest format itself |
| `macos` / `macos_major` | The macOS release whose store layout this fixture imitates |
| `adapter_id` | Adapter that must resolve for this fixture |
| `fingerprint.schemaHash` | Expected `StoreFingerprint.schemaHash` for `store.db`; the test recomputes and compares |
| `seed` | Seed for the deterministic content generator |
| `record_count` | Number of rows in `record`; must equal `expected.json` length |
| `known_differences_from_previous` | Free text or `"none observed"`; copied into the per-version table below |
| `verified_on` | Date a maintainer last compared the fixture DDL to a real store's `sqlite_master` on that macOS |

`expected.json` is an array of objects with the `ParsedNotification` fields (`bundleID`, `uuid`, `title`, `subtitle`, `body`, `sender`, `threadID`, `category`, `deliveredAt` as Unix seconds, `presented`, `attachments`, `userInfo`). Content is obviously synthetic: bundle ids like `com.example.chat`, senders like `Alex Example <alex@example.com>`, phone numbers like `+1 555 0100`, and any code-like strings generated from the seed and shown redacted in prose.

How `Scripts/make_fixture.sh` builds a SYNTHETIC store (it never copies a real one):

```bash
#!/usr/bin/env bash
# make_fixture.sh --macos 26 --seed 20260817 --count 250 --out Tests/Fixtures/SystemStore/macOS26
# Builds a synthetic system store: DDL from Scripts/fixtures/schema_v<major>.sql (hand-maintained,
# derived from observation), rows generated by a small Swift tool with a seeded RNG.
set -euo pipefail

MACOS=""; SEED=1; COUNT=100; OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --macos) MACOS="$2"; shift 2 ;;
    --seed)  SEED="$2";  shift 2 ;;
    --count) COUNT="$2"; shift 2 ;;
    --out)   OUT="$2";   shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$MACOS" && -n "$OUT" ]] || { echo "usage: $0 --macos N --out DIR [--seed N] [--count N]" >&2; exit 2; }

SCHEMA="Scripts/fixtures/schema_v${MACOS}.sql"
[[ -f "$SCHEMA" ]] || { echo "no schema template for macOS $MACOS ($SCHEMA)" >&2; exit 1; }

mkdir -p "$OUT"
rm -f "$OUT/store.db" "$OUT/store.db-wal" "$OUT/store.db-shm"

# 1. Empty store with the observed DDL.
sqlite3 "$OUT/store.db" < "$SCHEMA"

# 2. Synthetic rows (apps, records with bplist `data`) + expected.json, from a seeded RNG.
#    FixtureGen is a tiny SwiftPM executable in Scripts/FixtureGen; it never reads ~/Library.
swift run --package-path Scripts/FixtureGen fixturegen \
  --db "$OUT/store.db" --seed "$SEED" --count "$COUNT" --expected "$OUT/expected.json"

# 3. Fingerprint + manifest.
HASH=$(sqlite3 "$OUT/store.db" \
  "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY type, name;" \
  | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/ $//' | shasum -a 256 | cut -d' ' -f1)
DBINFO=$(sqlite3 "$OUT/store.db" "SELECT value FROM dbinfo WHERE lower(key) LIKE '%version%' LIMIT 1;" || true)

cat > "$OUT/manifest.json" <<JSON
{
  "schema_version": 1,
  "macos": "${MACOS}",
  "macos_major": ${MACOS},
  "adapter_id": "v${MACOS}",
  "fingerprint": { "schemaHash": "${HASH}", "dbinfoVersion": "${DBINFO}" },
  "generated_by": "make_fixture.sh",
  "generator_version": "1.0.0",
  "seed": ${SEED},
  "record_count": ${COUNT},
  "known_differences_from_previous": "none observed",
  "verified_on": "$(date +%F)",
  "notes": "Synthetic. Never a copy of a real store."
}
JSON
echo "fixture written to $OUT (schemaHash ${HASH:0:8})"
```

> ℹ️ **Info:** The bash hash above and `StoreFingerprinter` must agree byte-for-byte on normalization (lowercase, collapse whitespace, join with a single space per statement, statements joined by newline). `Scripts/verify_fixture.sh` recomputes the hash with the Swift implementation via a test host and fails CI if the two ever diverge.

What the tests assert (`Tests/BackglanceCaptureTests/AdapterFixtureTests.swift`):

```swift
import XCTest
import GRDB
@testable import BackglanceCapture

final class AdapterFixtureTests: XCTestCase {
    struct Manifest: Decodable {
        struct FP: Decodable { var schemaHash: String; var dbinfoVersion: String? }
        var adapter_id: String; var fingerprint: FP; var record_count: Int; var macos_major: Int
    }

    func testEachFixtureResolvesParsesAndMatchesExpected() throws {
        let root = Fixtures.systemStore
        for dirName in ["macOS14", "macOS15", "macOS26"] {
            let dir = root.appendingPathComponent(dirName)
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
            let expected = try JSONDecoder().decode([ExpectedNotification].self, from: Data(contentsOf: dir.appendingPathComponent("expected.json")))

            var config = Configuration(); config.readonly = true
            let db = try DatabaseQueue(path: dir.appendingPathComponent("store.db").path, configuration: config)
            try db.read { db in
                var fp = try StoreFingerprinter.fingerprint(db)
                XCTAssertEqual(fp.schemaHash, manifest.fingerprint.schemaHash, "\(dirName): schema hash drifted")
                // Force the OS major to the fixture's so resolution is deterministic on any CI runner.
                fp = StoreFingerprint(schemaHash: fp.schemaHash, dbinfoVersion: fp.dbinfoVersion,
                                      osVersion: OperatingSystemVersion(majorVersion: manifest.macos_major, minorVersion: 0, patchVersion: 0))
                let adapter = try XCTUnwrap(try StoreAdapterRegistry.resolve(fingerprint: fp, probeIn: db), "\(dirName): no adapter")
                XCTAssertEqual(type(of: adapter).id, manifest.adapter_id)

                guard case .ok(let count) = try adapter.probe(db) else { return XCTFail("\(dirName): probe not ok") }
                XCTAssertEqual(count, manifest.record_count)

                let raws = try adapter.records(after: .start, in: db)
                XCTAssertEqual(raws.count, expected.count)
                let parsed = try raws.map { try RecordParser().parse($0) }
                for (p, e) in zip(parsed, expected) {
                    XCTAssertEqual(p.bundleID, e.bundleID); XCTAssertEqual(p.title, e.title)
                    XCTAssertEqual(p.body, e.body); XCTAssertEqual(p.presented, e.presented)
                    XCTAssertEqual(p.deliveredAt.timeIntervalSince1970, e.deliveredAt, accuracy: 0.001)
                }
            }
        }
    }
}
```

CI runs this on `macos-14`, `macos-15`, and `macos-26` runners (`.github/workflows/fixtures.yml`), and additionally, on each runner, computes the fingerprint of the runner's own (empty or near-empty) real store if FDA can be granted, comparing only the `schemaHash` against the fixture — never reading rows. If that comparison ever fails, the workflow opens an issue titled "Store schema drift on macOS X.Y" so a maintainer can update `schema_vN.sql`, regenerate the fixture, and add the new hash to the adapter.

### Per-version notes

Columns are left honest on purpose. "none observed" means we have not seen a difference, not that Apple guarantees there is none.

| macOS | Adapter | Fixture dir | Tables observed | Known differences vs. previous | Verify cadence |
|---|---|---|---|---|---|
| 14 (Sonoma) | `StoreAdapterV14` | `macOS14/` | `dbinfo, app, record, requests, delivered, displayed, snoozed, categories` | baseline for this project | verify at each point release |
| 15 (Sequoia) | `StoreAdapterV15` | `macOS15/` | same as 14 | none observed | verify at each point release |
| 26 (Tahoe) | `StoreAdapterV26` | `macOS26/` | same as 15 | none observed in dev testing (26.0–26.5) | verify at each point release |
| 27 (beta) | fingerprint check → V26 fallback | none yet | not yet examined | unknown — beta | re-check every beta seed; adapter finalized at GM |

> ⚠️ **Warning:** "same as 15" is a statement about our fixtures and the machines we tested on, nothing more.

### Never document the system store as stable API

Backglance does not, and will not, describe the system store as an API. Concretely:

- No public doc, README line, or release note may say "reads the notification database" without the words "undocumented" and "may change".
- No code outside `BackglanceCapture` may reference store table or column names.
- Every store-touching path is behind `StoreAdapter`; every adapter is backed by a fixture; every fixture has a `verified_on` date.
- When a macOS release changes the layout, the correct response is a new adapter (or a new fingerprint on an existing one) plus a new fixture — never a "quick fix" in `CaptureEngine`.
- Degraded mode is a feature: if the fingerprint is unknown and probing fails, Backglance keeps running, keeps the archive readable and searchable, and tells the user plainly that capture is paused until an update ships.

## Next Steps

- Capture pipeline and watcher timing: [../features/CAPTURE.md](../features/CAPTURE.md)
- Adapter and fixture maintenance per macOS release: [./OS_COMPATIBILITY_PLAYBOOK.md](./OS_COMPATIBILITY_PLAYBOOK.md)
- Internal APIs contributors call against the archive: [../api/API_DOCUMENTATION.md](../api/API_DOCUMENTATION.md)
- Retention, prune schedule, and archive maintenance jobs: [../operations/MAINTENANCE.md](../operations/MAINTENANCE.md)

## Related Documentation

- [./ARCHITECTURE.md](./ARCHITECTURE.md)
- [./TECH_STACK.md](./TECH_STACK.md)
- [./OS_COMPATIBILITY_PLAYBOOK.md](./OS_COMPATIBILITY_PLAYBOOK.md)
- [../api/API_DOCUMENTATION.md](../api/API_DOCUMENTATION.md)
- [../features/CAPTURE.md](../features/CAPTURE.md)
- [../features/SEARCH.md](../features/SEARCH.md)
- [../features/MISSED_DIGEST.md](../features/MISSED_DIGEST.md)
- [../features/PRIVACY_CONTROLS.md](../features/PRIVACY_CONTROLS.md)
- [../features/PERMISSIONS_PRIVACY.md](../features/PERMISSIONS_PRIVACY.md)
- [../features/CLOUDKIT_SYNC.md](../features/CLOUDKIT_SYNC.md)
- [../testing/TESTING.md](../testing/TESTING.md)
- [../operations/MAINTENANCE.md](../operations/MAINTENANCE.md)
- [../security/SECURITY.md](../security/SECURITY.md)
- [../deployment/PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md)
