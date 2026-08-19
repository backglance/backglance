import Foundation
import GRDB

// MARK: - Archive.InsertOutcome

public extension Archive {
    /// What became of one notification offered to the archive.
    enum InsertOutcome: Sendable, Equatable {
        /// A new row.
        case inserted(id: Int64)

        /// An existing row refreshed in place — the store rewrote a notification it had
        /// already delivered.
        case updated(id: Int64)

        /// Already archived. Not an error: the first-launch import and live capture
        /// overlap by design.
        case duplicate
    }

    /// Archives a notification, or refreshes the one it replaces.
    ///
    /// Two keys, checked in this order inside one transaction:
    ///
    /// 1. **`store_rec_id`** — the same store row seen twice: an import overlapping live
    ///    capture, or a crash between the inserts and the cursor write. Nothing is
    ///    written.
    /// 2. **`uuid`** — a *different* store row carrying a uuid the archive already has.
    ///    That is what a thread update looks like: Messages replaces the banner for a
    ///    conversation, Mail re-delivers an updated summary. The existing row is
    ///    refreshed and keeps its id, so it keeps its place in any digest that already
    ///    referenced it, its pin and its deletion.
    ///
    /// An update marks the row unread again only if the *text* changed. A notification
    /// re-delivered with the same words has nothing new to read, and making it unread
    /// would put a badge on the menu bar for something the user already saw.
    ///
    /// - Parameter redaction: the audit row to record, if the redactor fired. Recorded
    ///   only alongside an insert — an update's audit row would claim a second redaction
    ///   of the same notification.
    @discardableResult
    func insertOrUpdate(
        _ notification: ArchivedNotification,
        redaction: RedactionEvent? = nil
    ) throws -> InsertOutcome {
        try pool.write { db in
            if
                let storeRecID = notification.storeRecId,
                try ArchivedNotification.filter(Column("store_rec_id") == storeRecID).fetchCount(db) > 0
            {
                return .duplicate
            }

            if let existing = try ArchivedNotification.filter(Column("uuid") == notification.uuid).fetchOne(db) {
                return try Self.refresh(db, existing: existing, with: notification)
            }

            var stored = notification
            do {
                try stored.insert(db)
            } catch let error as DatabaseError where Self.isUniquenessViolation(error) {
                // Two writers racing on the same uuid. Whoever lost simply has nothing
                // to add — treat it as the duplicate it is rather than failing a batch.
                return .duplicate
            }

            guard let id = stored.id else {
                throw ArchiveError.insertFailed(
                    uuid: UUID(uuidString: notification.uuid) ?? UUID(),
                    underlying: "insert did not yield a row id"
                )
            }

            if var redaction {
                redaction.notificationId = id
                try redaction.insert(db)
            }
            try Self.recordNotification(db, appID: stored.appId, deliveredAt: stored.deliveredAt)
            return .inserted(id: id)
        }
    }
}

// MARK: - Refreshing an existing row

private extension Archive {
    /// Copies what the store re-delivered onto the row already there.
    ///
    /// Deliberately partial. `isPinned`, `isDeleted` and `awaySessionId` are the user's
    /// and the app's own bookkeeping, not the store's, and a re-delivered banner must not
    /// unpin a notification or resurrect a deleted one. The app's counters are left alone
    /// too: an update is not a new notification, and counting it would inflate the "most
    /// noisy apps" list every time Messages rewrote a thread.
    static func refresh(
        _ db: Database,
        existing: ArchivedNotification,
        with notification: ArchivedNotification
    ) throws -> Archive.InsertOutcome {
        guard let id = existing.id else {
            throw ArchiveError.insertFailed(
                uuid: UUID(uuidString: notification.uuid) ?? UUID(),
                underlying: "existing row has no id"
            )
        }

        let textChanged = existing.title != notification.title
            || existing.subtitle != notification.subtitle
            || existing.body != notification.body

        var updated = existing
        updated.title = notification.title
        updated.subtitle = notification.subtitle
        updated.body = notification.body
        updated.sender = notification.sender
        updated.threadId = notification.threadId
        updated.category = notification.category
        updated.deliveredAt = notification.deliveredAt
        updated.presented = notification.presented
        updated.deepLink = notification.deepLink
        updated.attachmentsJson = notification.attachmentsJson
        updated.redaction = notification.redaction
        updated.storeRecId = notification.storeRecId
        if textChanged {
            updated.isRead = false
        }

        // `notifications_au` keeps the FTS index in sync with this update.
        try updated.update(db)
        return .updated(id: id)
    }
}
