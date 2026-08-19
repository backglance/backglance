-- Scripts/fixtures/schema_v15.sql — the macOS 15 (Sequoia) notification-store layout.
--
-- ⚠️ This is an OBSERVED layout, not an API, and this file is a reconstruction of the
-- layout documented in docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md#macos-15-sequoia--storeadapterv15
-- rather than a capture from a running macOS 15 machine. It is enough to exercise the
-- adapter, the parser and the whole capture pipeline, and it is honest about what it is.
--
-- To replace it with the real thing, run on a macOS 15 Mac with Full Disk Access granted
-- to the terminal:
--
--     Scripts/make_fixture.sh --os 15 --capture-schema
--
-- That reads `.schema` from the live store — DDL only, never a row — and rewrites this
-- file, after which the fixture's schema hash changes and every adapter that claims macOS
-- 15 needs its KnownFingerprints entry regenerated.
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
-- ⚠️ The one documented difference from Sonoma: Sequoia carries a composite index here
-- rather than a single-column one. Backglance queries neither — the difference exists in
-- the fingerprint, which is exactly the case the "reuse the adapter, add the hash" row of
-- the decision matrix is about.
CREATE INDEX record_delivered_date ON record (delivered_date, app_id);
