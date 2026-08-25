CREATE TABLE dbinfo (key VARCHAR, value VARCHAR);
CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR, badge INTEGER NULL);
CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB, request_date REAL, request_last_date REAL, delivered_date REAL, presented Bool, style INTEGER, snooze_fire_date REAL);
CREATE TABLE requests (app_id INTEGER PRIMARY KEY, list BLOB);
CREATE TABLE delivered (app_id INTEGER PRIMARY KEY, list BLOB);
CREATE TABLE displayed (app_id INTEGER PRIMARY KEY, list BLOB);
CREATE TABLE snoozed (app_id INTEGER PRIMARY KEY, list BLOB);
CREATE TABLE categories (app_id INTEGER PRIMARY KEY, categories BLOB);
CREATE TRIGGER app_deleted AFTER DELETE ON app
BEGIN
    DELETE FROM record WHERE app_id=old.app_id;
    DELETE FROM requests WHERE app_id=old.app_id;
    DELETE FROM delivered WHERE app_id=old.app_id;
    DELETE FROM displayed WHERE app_id=old.app_id;
    DELETE FROM snoozed WHERE app_id=old.app_id;
    DELETE FROM categories WHERE app_id=old.app_id;
END;
