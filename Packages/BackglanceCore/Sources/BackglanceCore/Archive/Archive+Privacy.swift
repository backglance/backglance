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
    /// row carries `notification_count = 0` and seen-at timestamps that
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
