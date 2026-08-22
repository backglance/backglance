import Foundation
import GRDB

// MARK: - ArchivedNotification

/// One captured notification — maps `notifications` per
/// docs/architecture/DATABASE_SCHEMA.md#canonical-ddl.
///
/// > 🔒 Important: this type's `description` is content-free, and it has one
/// > *for* that reason rather than despite it. `title`, `subtitle`, `body`
/// > and `sender` are notification content, and Privacy Invariant #1 (see
/// > CLAUDE.md) is that content never reaches a log. Leaving the conformance
/// > off does not prevent `logger.debug("\(notification)")` — it makes it
/// > worse: with no `description`, Swift falls back to reflecting the struct
/// > and prints every stored property, title and body included. A
/// > content-free description turns the same accident into a harmless line.
/// > The right thing to log is still a ``NotificationLogRef``; this is the
/// > floor under the mistake, not the intended path.
///
/// > Note: `MutablePersistableRecord`, not `PersistableRecord` — see the
/// > equivalent note on ``AppRecord``. `PersistableRecord.didInsert(_:)` is
/// > non-mutating and would not write `id` back to the caller's variable.
public struct ArchivedNotification: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable,
    Sendable
{
    // MARK: Lifecycle

    /// A row ready to insert.
    ///
    /// A public initializer because the capture layer builds these: a `public struct`'s
    /// memberwise initializer is internal, so without this one `BackglanceCapture` could
    /// not construct the very type it exists to produce.
    ///
    /// The defaults are the state a freshly captured notification is in — unread,
    /// unpinned, not deleted, unredacted, not attributed to an away session — so a caller
    /// names only what the store actually told it.
    public init(
        id: Int64? = nil,
        uuid: String,
        appId: Int64,
        title: String? = nil,
        subtitle: String? = nil,
        body: String? = nil,
        sender: String? = nil,
        threadId: String? = nil,
        category: String? = nil,
        deliveredAt: UnixDate,
        capturedAt: UnixDate,
        source: Source = .live,
        presented: Bool = true,
        awaySessionId: Int64? = nil,
        deepLink: String? = nil,
        attachmentsJson: String? = nil,
        redaction: Redaction = .none,
        isRead: Bool = false,
        isPinned: Bool = false,
        isDeleted: Bool = false,
        storeRecId: Int64? = nil
    ) {
        self.id = id
        self.uuid = uuid
        self.appId = appId
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.sender = sender
        senderKey = sender?.matchKey
        self.threadId = threadId
        self.category = category
        self.deliveredAt = deliveredAt
        self.capturedAt = capturedAt
        self.source = source
        self.presented = presented
        self.awaySessionId = awaySessionId
        self.deepLink = deepLink
        self.attachmentsJson = attachmentsJson
        self.redaction = redaction
        self.isRead = isRead
        self.isPinned = isPinned
        self.isDeleted = isDeleted
        self.storeRecId = storeRecId
    }

    // MARK: Public

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

    /// ``sender`` folded by ``Swift/String/matchKey`` — what `sender:` compares against.
    ///
    /// Stored rather than folded at query time because SQLite's `lower()` is ASCII-only:
    /// comparing a Swift-folded needle against `lower(sender)` silently missed every
    /// non-ASCII name, so `sender:ayse` did not find "AYŞE". Both sides now fold the same
    /// way, in Swift.
    ///
    /// Derived, never passed in: the initializer sets it from `sender`, `didSet` keeps it
    /// current, and decoding a row reads the stored column. It carries no information the
    /// row does not already hold, so it lives and dies with the row it belongs to.
    public private(set) var senderKey: String?

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

    /// Best-effort sender (Messages contact/handle, Mail from-name).
    ///
    /// Assigning it re-derives ``senderKey``, which is the only thing keeping the two in
    /// step on the thread-update path.
    public var sender: String? {
        didSet {
            senderKey = sender?.matchKey
        }
    }

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

// MARK: CustomStringConvertible, CustomDebugStringConvertible

extension ArchivedNotification: CustomStringConvertible, CustomDebugStringConvertible {
    /// What a bug report needs, and nothing a notification said.
    ///
    /// The same shape ``ParsedNotification`` uses, so a line about a record before and after
    /// it was archived reads the same way: a uuid prefix to correlate, the app row it belongs
    /// to, and the field lengths — "body 0 characters" versus "body 240 characters" is the
    /// difference between a parser bug and a display bug, and neither answer needs the body.
    public var logDescription: String {
        let lengths = "t=\(title?.count ?? 0) s=\(subtitle?.count ?? 0) b=\(body?.count ?? 0)"
        return "\(uuid.prefix(8)) app=\(appId) \(lengths) src=\(source.rawValue)"
    }

    public var description: String {
        logDescription
    }

    public var debugDescription: String {
        logDescription
    }
}
