-- Scripts/fixtures/schema_v14.sql — the macOS 14 (Sonoma) notification-store layout.
--
-- ⚠️ This is an OBSERVED layout, not an API, and this file is a reconstruction of the
-- layout documented in docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md#macos-14-sonoma--storeadapterv14
-- rather than a capture from a running macOS 14 machine. It is enough to exercise the
-- adapter, the parser and the whole capture pipeline, and it is honest about what it is.
--
-- To replace it with the real thing, run on a macOS 14 Mac with Full Disk Access granted
-- to the terminal:
--
--     Scripts/make_fixture.sh --os 14 --capture-schema
--
-- That reads `.schema` from the live store — DDL only, never a row — and rewrites this
-- file, after which the fixture's schema hash changes and every adapter that claims macOS
-- 14 needs its KnownFingerprints entry regenerated.
--
-- Columns Backglance reads are marked; the rest exist so the fixture has the same shape as
-- the real store, including columns the adapter deliberately ignores.

CREATE TABLE dbinfo (key TEXT PRIMARY KEY, value);

CREATE TABLE app (
    app_id INTEGER PRIMARY KEY,   -- read (join key)
    identifier TEXT,              -- read (bundle id)
    badge INTEGER
);

CREATE TABLE record (
    rec_id INTEGER PRIMARY KEY,   -- read (cursor, dedupe)
    app_id INTEGER,               -- read (join)
    uuid BLOB,                    -- read (16 raw bytes)
    data BLOB,                    -- read (binary plist payload)
    request_date REAL,            -- read (fallback delivery date)
    request_last_date REAL,
    delivered_date REAL,          -- read (Cocoa reference seconds)
    presented INTEGER,            -- read (banner was shown)
    style INTEGER,                -- carried, never branched on
    snooze_fire_date REAL
);

CREATE TABLE requests (record_id INTEGER, app_id INTEGER);
CREATE TABLE delivered (record_id INTEGER, app_id INTEGER);
CREATE TABLE displayed (record_id INTEGER, app_id INTEGER);
CREATE TABLE snoozed (record_id INTEGER, app_id INTEGER);
CREATE TABLE categories (category_id INTEGER PRIMARY KEY, identifier TEXT, app_id INTEGER);

CREATE INDEX record_app_id ON record (app_id);
CREATE INDEX record_delivered_date ON record (delivered_date);
