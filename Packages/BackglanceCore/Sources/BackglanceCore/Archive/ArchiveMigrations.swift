import Foundation
import GRDB

/// The archive's schema, expressed as an ordered chain of named migrations.
///
/// Every schema change the archive has ever undergone lives here, in registration
/// order, and that order is the schema's only source of truth at runtime — GRDB's
/// `DatabaseMigrator` decides what to apply, `schema_meta.archive_version` only
/// mirrors it for humans reading the file with `sqlite3`.
///
/// The SQL is the canonical DDL from
/// docs/architecture/DATABASE_SCHEMA.md#canonical-ddl, reproduced verbatim except
/// for statement ordering (see ``v1InitialSQL``). If the code and that document ever
/// disagree, one of them is a bug — they are changed together or not at all.
///
/// ## Rules for adding a migration
///
/// The full list is in docs/architecture/DATABASE_SCHEMA.md#rules-for-writing-migrations;
/// the two that matter most:
///
/// - **A shipped migration is never edited.** Its name and its SQL are frozen the
///   moment a build reaches a user's machine, because that user's archive already
///   records it as applied. Corrections are additive: register another migration.
/// - **Changes are additive.** New tables, new nullable columns, new indexes. Renaming
///   a column in place, or dropping a data-bearing table, breaks archives written by
///   older builds that a user may still downgrade to.
enum ArchiveMigrations {
    // MARK: Internal

    /// The archive version this build writes into `schema_meta.archive_version`.
    ///
    /// Bumped by the last migration registered below, and mirrored by
    /// ``BackglanceCore/archiveSchemaVersion``.
    static let currentArchiveVersion = 1

    /// The migrator applied by `Archive` when it opens a database.
    ///
    /// `eraseDatabaseOnSchemaChange` is DEBUG-only: while a migration is still being
    /// written, editing it in place is normal, and a developer wants a fresh archive
    /// rather than a half-applied one. In Release it must stay off — it would delete
    /// a user's archive on any schema mismatch.
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        #if DEBUG
            migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_initial") { db in
            try db.execute(sql: v1InitialSQL)
            try setArchiveVersion(db, 1)
        }

        migrator.registerMigration("v1_fts") { db in
            try db.execute(sql: ftsTableSQL)
            try db.execute(sql: ftsTriggersSQL)
            // Backfill for archives created before FTS existed. A no-op on a fresh
            // install, and the reason this is a separate migration from v1_initial:
            // the index is derived data, so it can always be rebuilt from
            // `notifications` rather than migrated.
            try db.execute(sql: "INSERT INTO notifications_fts(notifications_fts) VALUES ('rebuild')")
        }

        return migrator
    }

    /// Writes `schema_meta.archive_version`, which every migration that bumps the
    /// version calls as its last statement.
    ///
    /// Informational only: GRDB's `grdb_migrations` table is what actually decides
    /// whether a migration runs. This exists so that someone opening `archive.sqlite`
    /// in `sqlite3` can tell at a glance which release wrote it.
    static func setArchiveVersion(_ db: Database, _ version: Int) throws {
        try db.execute(
            sql: "INSERT INTO schema_meta(key, value) VALUES ('archive_version', ?) " +
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [String(version)]
        )
    }

    // MARK: Private

    /// The v1.0 schema: every table, index and constraint the archive ships with,
    /// minus `notifications_fts` (created by `v1_fts`, because the index is derived
    /// data that can be rebuilt) and minus the v1.x tables `saved_searches`,
    /// `snoozes` and `embeddings` (each arrives with the feature that needs it).
    ///
    /// Statements are ordered so that every foreign-key target exists before the
    /// table referencing it — `away_sessions` before `notifications`, in particular.
    /// SQLite tolerates a forward reference in `CREATE TABLE`, but only fails on it
    /// later at insert time, which would turn a schema mistake into a capture-time
    /// mystery.
    private static let v1InitialSQL = """
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

    CREATE TABLE away_sessions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      started_at REAL NOT NULL, ended_at REAL,
      reason TEXT NOT NULL                         -- 'locked' | 'asleep' | 'focus' | 'presenting' | 'manual'
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
      attachments_json TEXT,                       -- [{"type":"image","name":"…","size":1234}] metadata only
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
    """

    /// The FTS5 index backing search.
    ///
    /// External content (`content='notifications'`, `content_rowid='id'`) means the
    /// index stores postings only and reads the text back from `notifications` — no
    /// second copy of notification bodies on disk, which matters both for size and
    /// because a panic wipe then has one table to destroy rather than two.
    ///
    /// The tokenizer options are load-bearing, not defaults:
    /// `remove_diacritics 2` so "Ayşe" is found by typing "Ayse"; `tokenchars '@.-'`
    /// so email addresses, bundle ids and hyphenated names stay single tokens;
    /// `prefix '2 3'` so search-as-you-type has an index to hit from the second
    /// character. See docs/features/SEARCH.md#the-fts5-schema.
    private static let ftsTableSQL = """
    CREATE VIRTUAL TABLE notifications_fts USING fts5(
      title, subtitle, body, sender,
      content='notifications', content_rowid='id',
      tokenize = "unicode61 remove_diacritics 2 tokenchars '@.-'",
      prefix = '2 3'
    );
    """

    /// The three triggers that keep `notifications_fts` in step with `notifications`.
    ///
    /// An external-content FTS5 table does not update itself. The `'delete'` command
    /// form is the documented FTS5 idiom: the index has to be told the *old* column
    /// values so it can remove exactly the right postings — passing the new ones, or
    /// omitting them, silently corrupts the index.
    ///
    /// `notifications_au` fires only on the four indexed columns, so marking a row
    /// read, pinning it, soft-deleting it or assigning `away_session_id` never
    /// touches the index. Soft-deleted rows deliberately stay indexed; queries filter
    /// them with `AND n.is_deleted = 0`, and the retention job's hard delete fires
    /// `notifications_ad` to remove the postings for real.
    /// See docs/features/SEARCH.md#the-three-sync-triggers.
    private static let ftsTriggersSQL = """
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
    """
}
