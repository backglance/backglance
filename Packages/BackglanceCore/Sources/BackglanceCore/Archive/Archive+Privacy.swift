import Foundation
import GRDB

// MARK: - Per-app redaction

public extension Archive {
    /// Every app row, newest-noisiest first, for the per-app privacy lists.
    ///
    /// Ordered by notification count and then by bundle id: the apps a user wants to
    /// change a setting on are the ones that notify them, and a stable tiebreak keeps
    /// rows from swapping places under the cursor when two counts are equal.
    ///
    /// Fetched whole rather than paged: `apps` is a few hundred rows at most
    /// (see ``appsByID()``).
    func allApps() throws -> [AppRecord] {
        do {
            return try pool.read { db in
                try AppRecord
                    .order(Column("notification_count").desc, Column("bundle_id").asc)
                    .fetchAll(db)
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// Whether ``OTPRedactor`` is on for `bundleID`.
    ///
    /// An app with no row yet answers with the shipped default rather than `false`, so
    /// that the answer does not depend on whether Messages happens to have notified this
    /// user yet. The capture path does not call this — it already holds the `AppRecord`
    /// from the upsert — but the Settings pane and the tests do.
    func redactsOTP(bundleID: String) throws -> Bool {
        do {
            return try pool.read { db in
                guard let app = try AppRecord.filter(Column("bundle_id") == bundleID).fetchOne(db) else {
                    return RedactionPolicy.redactsByDefault(bundleID: bundleID)
                }
                return app.redactOtp
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// Turns one-time-code redaction on or off for one app.
    ///
    /// 🔒 Only ever affects notifications captured *after* the call. Turning it off
    /// cannot bring back a code that was already replaced, because the digits were
    /// replaced in memory before the insert and no copy was kept — the pane says so, and
    /// this method is not the place that could change it.
    ///
    /// Creates the app row when there is none, which is what lets the user switch
    /// redaction on for an app that has not notified them yet: the row carries the
    /// setting until the first notification arrives to fill in the rest of it. Such a row
    /// carries `notification_count = 0` and seen-at timestamps that
    /// ``recordNotification(_:appID:deliveredAt:)`` corrects on the first delivery.
    ///
    /// - Returns: the app row as it now stands.
    @discardableResult
    func setRedactsOTP(_ enabled: Bool, bundleID: String, now: Date = Date()) throws -> AppRecord {
        do {
            return try pool.write { db in
                var app = try Self.upsertApp(db, bundleID: bundleID, now: now, retention: nil)
                guard app.redactOtp != enabled else {
                    return app
                }
                app.redactOtp = enabled
                try app.update(db)
                return app
            }
        } catch {
            throw ArchiveError.writeFailed(
                table: AppRecord.databaseTableName,
                underlying: ArchiveError.detail(from: error)
            )
        }
    }
}

// MARK: - Exclusions

public extension Archive {
    /// The exclusion list as it stands: the shipped defaults, with this archive's
    /// decisions layered over them.
    ///
    /// 🔒 Read once per capture tick rather than once per record. The check itself has to
    /// run before every record is parsed (Privacy Invariant #3), and a database read per
    /// record would put a transaction between the store and the parser on the hot path —
    /// so the *snapshot* is what the engine holds, and it is refreshed at the top of each
    /// tick. The window that opens is one tick long, and it can only ever be the user
    /// having just excluded an app whose notification arrived moments earlier.
    func exclusionList() throws -> ExclusionList {
        do {
            return try pool.read { db in
                let rows = try AppRecord.fetchAll(db)
                // `bundle_id` is UNIQUE, so the duplicate case is unreachable; taking the
                // later row keeps the initializer total rather than trapping on a schema
                // that has been hand-edited.
                var overrides: [String: Bool] = [:]
                for row in rows {
                    overrides[row.bundleId] = row.isExcluded
                }
                return ExclusionList(overrides: overrides)
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// Excludes `bundleID`, or stops excluding it.
    ///
    /// Writing `false` for a shipped default is how a user opts back in: the row's `0`
    /// outranks the code's default, which is what makes "you may remove any of these"
    /// true rather than merely stated.
    ///
    /// Excluding an app does **not** delete what is already archived. That is a separate
    /// decision with a separate confirmation — someone excluding an app from here on is
    /// not necessarily asking to lose the last month of it — and it belongs to the
    /// Excluded Apps pane rather than to this method.
    ///
    /// - Returns: the app row as it now stands.
    @discardableResult
    func setExcluded(_ excluded: Bool, bundleID: String, now: Date = Date()) throws -> AppRecord {
        do {
            return try pool.write { db in
                var app = try Self.upsertApp(db, bundleID: bundleID, now: now, retention: nil)
                guard app.isExcluded != excluded else {
                    return app
                }
                app.isExcluded = excluded
                try app.update(db)
                return app
            }
        } catch {
            throw ArchiveError.writeFailed(
                table: AppRecord.databaseTableName,
                underlying: ArchiveError.detail(from: error)
            )
        }
    }

    /// Undoes every shipped default the user has switched off, and nothing else.
    ///
    /// "Restore defaults" means restoring the *defaults*, so an app the user added
    /// themselves stays excluded — they did not ask for it to be forgotten, and a button
    /// that quietly un-excluded a bank would be the worst possible surprise from a control
    /// labelled "restore".
    ///
    /// - Returns: how many rows changed.
    @discardableResult
    func restoreDefaultExclusions(now: Date = Date()) throws -> Int {
        let suppressed = try exclusionList().suppressedDefaults
        for entry in suppressed {
            try setExcluded(true, bundleID: entry.bundleID, now: now)
        }
        return suppressed.count
    }
}
