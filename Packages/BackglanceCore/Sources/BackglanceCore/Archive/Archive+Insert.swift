import Foundation
import GRDB

public extension Archive {
    // MARK: - Apps

    /// Returns the `apps` row for `bundleID`, creating it if this is the first time
    /// the app has been seen.
    ///
    /// The row outlives the notifications it owns on purpose: it carries the user's
    /// per-app choices (retention, exclusion, mute, OTP redaction), so those survive
    /// even after retention has pruned every notification the app ever sent. Deleting
    /// an app row is therefore a deliberate act, not a side effect of pruning.
    ///
    /// `retention` is applied only when creating the row. An existing row's retention
    /// is the user's setting, and capture must never quietly overwrite it.
    @discardableResult
    func upsertApp(bundleID: String, now: Date, retention: AppRetention? = nil) throws -> AppRecord {
        try pool.write { db in
            try Self.upsertApp(db, bundleID: bundleID, now: now, retention: retention)
        }
    }

    // MARK: - Notifications

    /// Archives one notification, together with its redaction audit row, and updates
    /// the owning app's bookkeeping — all in a single transaction.
    ///
    /// The three writes belong together. A notification whose redaction row failed to
    /// land would be indistinguishable from one that was never redacted, and an app
    /// whose `notification_count` drifted from the rows it owns would misreport in
    /// Settings. `pool.write` gives them one transaction, so either all three happen
    /// or none do.
    ///
    /// `notification.appId` must already refer to a row — call
    /// ``upsertApp(bundleID:now:retention:)`` first. The app row is deliberately *not*
    /// created here: an app that turns out to be excluded should never reach this
    /// method at all, and the exclusion check runs against the app row.
    ///
    /// - Parameter redaction: the audit row to record, if `OTPRedactor` fired. Its
    ///   `notificationId` is filled in from the inserted row, so the caller does not
    ///   need to know the id in advance. It records *that* a redaction happened and
    ///   which pattern matched — never what was redacted (Privacy Invariant #2).
    /// - Throws: ``ArchiveError/duplicate`` when this notification is already
    ///   archived, matched on `uuid` or on `store_rec_id`. This is the normal outcome
    ///   of the first-launch import overlapping live capture, so callers advance the
    ///   cursor and move on rather than logging it as an error
    ///   (docs/architecture/ARCHITECTURE.md#error-handling-patterns).
    @discardableResult
    func insert(
        _ notification: ArchivedNotification,
        redaction: RedactionEvent? = nil
    ) throws -> ArchivedNotification {
        try pool.write { db in
            var stored = notification
            do {
                try stored.insert(db)
            } catch let error as DatabaseError where Self.isUniquenessViolation(error) {
                throw ArchiveError.duplicate
            } catch {
                throw ArchiveError.insertFailed(
                    uuid: UUID(uuidString: notification.uuid) ?? UUID(),
                    underlying: String(describing: error)
                )
            }

            guard let notificationID = stored.id else {
                throw ArchiveError.insertFailed(
                    uuid: UUID(uuidString: notification.uuid) ?? UUID(),
                    underlying: "insert did not yield a row id"
                )
            }

            if var redaction {
                redaction.notificationId = notificationID
                try redaction.insert(db)
            }

            try Self.recordNotification(db, appID: stored.appId, deliveredAt: stored.deliveredAt)
            return stored
        }
    }
}

// MARK: - Building blocks

private extension Archive {
    /// The `apps` upsert, scoped to an existing transaction.
    static func upsertApp(
        _ db: Database,
        bundleID: String,
        now: Date,
        retention: AppRetention?
    ) throws -> AppRecord {
        if let existing = try AppRecord.filter(Column("bundle_id") == bundleID).fetchOne(db) {
            return existing
        }

        var app = AppRecord(
            id: nil,
            bundleId: bundleID,
            displayName: nil,
            retention: retention ?? .inherit,
            isExcluded: false,
            isMuted: false,
            redactOtp: Self.redactsOTPByDefault(bundleID: bundleID),
            firstSeenAt: UnixDate(now),
            lastSeenAt: UnixDate(now),
            notificationCount: 0
        )
        try app.insert(db)
        return app
    }

    /// Widens the app's seen-at window and increments its denormalized count.
    ///
    /// `min`/`max` rather than plain assignment because import walks history in
    /// `rec_id` order, which is not delivery order — assigning would leave
    /// `last_seen_at` pointing at whichever row happened to be archived last.
    static func recordNotification(_ db: Database, appID: Int64, deliveredAt: UnixDate) throws {
        try db.execute(
            sql: """
            UPDATE apps
               SET notification_count = notification_count + 1,
                   first_seen_at = min(first_seen_at, ?),
                   last_seen_at = max(last_seen_at, ?)
             WHERE id = ?
            """,
            arguments: [deliveredAt, deliveredAt, appID]
        )
    }

    /// Messages and Mail carry one-time codes often enough that redaction is on for
    /// them from the first notification, before the user has had a chance to look at
    /// Settings. See docs/features/PRIVACY_CONTROLS.md.
    static func redactsOTPByDefault(bundleID: String) -> Bool {
        ["com.apple.MobileSMS", "com.apple.mail"].contains(bundleID)
    }

    /// Whether a database error is the archive saying "already have this one".
    ///
    /// Narrowed to uniqueness specifically: a foreign-key failure or a `NOT NULL`
    /// violation is a bug in the caller, and collapsing those into
    /// ``ArchiveError/duplicate`` would hide them, because `.duplicate` is the one
    /// error the capture pipeline deliberately swallows.
    static func isUniquenessViolation(_ error: DatabaseError) -> Bool {
        error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE ||
            error.extendedResultCode == .SQLITE_CONSTRAINT_PRIMARYKEY
    }
}
