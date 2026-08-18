import Foundation
import GRDB

// MARK: - Digest

/// The "missed while away" summary built for one `AwaySession` — maps
/// `digests` per docs/architecture/DATABASE_SCHEMA.md#canonical-ddl.
///
/// > Note: `MutablePersistableRecord`, not `PersistableRecord` — see the
/// > equivalent note on ``AppRecord``. `PersistableRecord.didInsert(_:)` is
/// > non-mutating and would not write `id` back to the caller's variable.
public struct Digest: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "digests"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    // MARK: - Associations

    /// The session this digest summarizes. `ON DELETE CASCADE`, so this
    /// digest cannot outlive the session it describes.
    public static let awaySession = belongsTo(AwaySession.self)

    /// The notifications selected into this digest, in display order.
    /// `ON DELETE CASCADE` on `digest_items.digest_id`.
    public static let items = hasMany(DigestItem.self)

    /// `nil` until the row is inserted; ``didInsert(_:)`` fills it from the
    /// autoincrement rowID.
    public var id: Int64?

    /// → `away_sessions.id`, `ON DELETE CASCADE`.
    public var awaySessionId: Int64

    public var createdAt: UnixDate

    /// Set once, the first time the digest is shown to the user. `nil`
    /// means it has never been shown; a digest is never shown a second
    /// time, so this column never reverts to `nil` once set.
    public var shownAt: UnixDate?

    /// Set once the user dismisses the digest.
    public var dismissedAt: UnixDate?

    /// Denormalized count of `items`.
    public var itemCount = 0

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - DigestItem

/// One notification selected into a `Digest`, with its display rank — maps
/// `digest_items` per docs/architecture/DATABASE_SCHEMA.md#canonical-ddl.
///
/// The primary key is the composite `(digest_id, notification_id)` declared
/// in the DDL, not a surrogate rowID, so this type has no `id` property and
/// is not `Identifiable`, and there is no `didInsert(_:)` to write one back.
public struct DigestItem: Codable, FetchableRecord, MutablePersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "digest_items"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    // MARK: - Associations

    /// → `digests.id`, `ON DELETE CASCADE`.
    public static let digest = belongsTo(Digest.self)

    /// → `notifications.id`, `ON DELETE CASCADE`.
    public static let notification = belongsTo(ArchivedNotification.self)

    public var digestId: Int64
    public var notificationId: Int64

    /// Display order within the digest: VIP first, then per-app grouping,
    /// then `delivered_at`.
    public var rank = 0
}
