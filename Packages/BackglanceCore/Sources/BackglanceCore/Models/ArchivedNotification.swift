import Foundation
import GRDB

// MARK: - ArchivedNotification

/// One captured notification — maps `notifications` per
/// docs/architecture/DATABASE_SCHEMA.md#canonical-ddl.
///
/// > Important: This type deliberately has no `CustomStringConvertible` or
/// > `CustomDebugStringConvertible` conformance, and nothing in this file
/// > logs one. `title`, `subtitle`, `body`, and `sender` are notification
/// > content — Privacy Invariant #1 (see CLAUDE.md) is that content never
/// > reaches a log, and a convenience string description is exactly the
/// > kind of thing that ends up in one by accident (an unguarded
/// > `logger.debug("\(notification)")`). Log a `NotificationLogRef` (id,
/// > bundle id, lengths) instead.
///
/// > Note: `MutablePersistableRecord`, not `PersistableRecord` — see the
/// > equivalent note on ``AppRecord``. `PersistableRecord.didInsert(_:)` is
/// > non-mutating and would not write `id` back to the caller's variable.
public struct ArchivedNotification: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable,
    Sendable
{
    /// `'live'` (the store watcher) or `'import'` (`CaptureEngine.importExisting()`).
    /// `import` is a Swift keyword, hence `imports`; the raw value is what
    /// actually lands in the `source` column.
    public enum Source: String, Codable, Hashable, Sendable {
        case live
        case imports = "import"
    }

    /// Whether — and how — this row's text was redacted before insert.
    /// `.otp` is the only kind in v1.0; see `OTPRedactor`.
    public enum Redaction: String, Codable, Hashable, Sendable {
        case none
        case otp
    }

    public static let databaseTableName = "notifications"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    // MARK: - Associations

    /// The owning app. The foreign key (`notifications.app_id`) is declared
    /// in the DDL, so GRDB infers the join without an explicit column list.
    public static let app = belongsTo(AppRecord.self)

    /// The away session `deliveredAt` fell inside, if any. The foreign key
    /// (`notifications.away_session_id`, `ON DELETE SET NULL`) is declared
    /// in the DDL, so GRDB infers the join without an explicit column list.
    public static let awaySession = belongsTo(AwaySession.self)

    /// Redaction events recorded for this notification's text.
    /// `ON DELETE CASCADE` on `redactions.notification_id`.
    public static let redactions = hasMany(RedactionEvent.self)

    /// `nil` until the row is inserted; ``didInsert(_:)`` fills it from the
    /// autoincrement rowID.
    public var id: Int64?

    /// The store's `record.uuid` when present, else generated at capture.
    /// `UNIQUE` in the schema; `backglance://open?id=` resolves against it.
    public var uuid: String

    /// → `apps.id`, `ON DELETE CASCADE`.
    public var appId: Int64

    /// Text decoded from the store's bplist (`titl`/`subt`/`body`), after
    /// `OTPRedactor` if `redaction != .none`. Never logged — see the type-level note.
    public var title: String?
    public var subtitle: String?
    public var body: String?

    /// Best-effort sender (Messages contact/handle, Mail from-name).
    public var sender: String?

    /// The store's `thre` key; groups conversation threads in the timeline.
    public var threadId: String?

    /// The store's `cate` (UN category identifier).
    public var category: String?

    /// The store's `delivered_date`, already converted from the Cocoa
    /// reference date to Unix seconds by `RecordParser` — never a raw
    /// Cocoa-epoch number past that point.
    public var deliveredAt: UnixDate

    /// When Backglance wrote this row, independent of `deliveredAt` (capture
    /// can lag delivery, or `source == .imports` can backfill history).
    public var capturedAt: UnixDate

    public var source: Source = .live

    /// The store's own "a banner was shown" flag. `false` means the system
    /// did not present it (Focus, screen locked, …); feeds the missed digest.
    public var presented = true

    /// Set when `deliveredAt` fell inside an away session. `ON DELETE SET
    /// NULL`, so a pruned session does not take its notifications with it.
    public var awaySessionId: Int64?

    /// Resolved by `EnrichmentService` (`sms:`, `imessage:`, `message://`, `https://…`).
    public var deepLink: String?

    /// JSON array of attachment metadata (`type`, `name`, `size`) — never
    /// attachment bytes, per Privacy Invariant #1's spirit.
    public var attachmentsJson: String?

    public var redaction: Redaction = .none

    /// Cleared when the row scrolls into view in the popover or window.
    public var isRead = false

    /// User pin; pinned rows are exempt from retention pruning.
    public var isPinned = false

    /// Soft delete (user swipe/⌫); hard-pruned later by the retention job.
    public var isDeleted = false

    /// The store's `record.rec_id`, when known. Unique where non-null
    /// (`idx_notifications_store_rec`), so a re-import cannot duplicate a row.
    public var storeRecId: Int64?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Requests

public extension ArchivedNotification {
    /// The Column identifiers used below, spelled out once so the request
    /// helpers below don't repeat raw SQL column-name strings.
    ///
    /// Named `RequestColumns` rather than `Columns`: `TableRecord` reserves
    /// `Columns` as a nested-type hook it looks for by convention, so a
    /// `private enum Columns` here collides with that requirement and forces
    /// it public — this name sidesteps the collision instead of exposing an
    /// otherwise-internal implementation detail.
    private enum RequestColumns {
        static let id = Column("id")
        static let appId = Column("app_id")
        static let deliveredAt = Column("delivered_at")
        static let isDeleted = Column("is_deleted")
    }

    /// The `limit` most recently delivered, non-deleted notifications.
    ///
    /// Backs the popover's "recent" list, where a fixed-size snapshot is all
    /// that's needed — unlike ``page(after:limit:)``, there is no follow-up
    /// page, so an `OFFSET` is neither present nor needed here.
    static func recent(limit: Int) -> QueryInterfaceRequest<ArchivedNotification> {
        ArchivedNotification
            .filter(RequestColumns.isDeleted == false)
            .order(RequestColumns.deliveredAt.desc)
            .limit(limit)
    }

    /// One page of the timeline, ordered newest-first, using keyset
    /// (a.k.a. seek) pagination rather than `OFFSET`.
    ///
    /// `OFFSET` counts rows from the start of the result set on every call,
    /// so it has two problems for a live-updating timeline: it re-scans and
    /// discards `offset` rows each time (cost grows with page depth), and it
    /// is unstable under concurrent inserts — a notification arriving at the
    /// head shifts every row's position by one, which makes the next
    /// `OFFSET`-based page skip or repeat rows depending on the direction of
    /// the shift. Keyset pagination anchors each page to the last row
    /// actually returned (`after`) instead of a numeric position, so new
    /// rows at the head only ever affect a future first page — pages already
    /// requested keep pointing at the same rows.
    ///
    /// `delivered_at` alone is not a unique key (two notifications can share
    /// a timestamp), so the cursor and the ordering both carry `id` as a
    /// tiebreaker: `ORDER BY delivered_at DESC, id DESC` together with
    /// `(delivered_at, id) < (after.deliveredAt, after.id)` (expressed as the
    /// standard compound-key expansion below) give a total order that can
    /// neither skip nor repeat a row across pages, even if rows share a
    /// `delivered_at`. Pass `after: nil` for the first page.
    static func page(
        after cursor: (deliveredAt: UnixDate, id: Int64)?,
        limit: Int
    ) -> QueryInterfaceRequest<ArchivedNotification> {
        let base = ArchivedNotification
            .filter(RequestColumns.isDeleted == false)
            .order(RequestColumns.deliveredAt.desc, RequestColumns.id.desc)
            .limit(limit)

        guard let cursor else {
            return base
        }

        return base.filter(
            RequestColumns.deliveredAt < cursor.deliveredAt ||
                (RequestColumns.deliveredAt == cursor.deliveredAt && RequestColumns.id < cursor.id)
        )
    }

    /// The `limit` most recently delivered, non-deleted notifications for one
    /// app, ordered to match `idx_notifications_app_delivered` (`app_id,
    /// delivered_at DESC`) so the equality filter plus sort can both be
    /// served from that index without a separate sort step.
    static func forApp(_ appID: Int64, limit: Int) -> QueryInterfaceRequest<ArchivedNotification> {
        ArchivedNotification
            .filter(RequestColumns.appId == appID)
            .filter(RequestColumns.isDeleted == false)
            .order(RequestColumns.deliveredAt.desc)
            .limit(limit)
    }
}
