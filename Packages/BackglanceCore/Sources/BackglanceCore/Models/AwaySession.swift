import Foundation
import GRDB

// MARK: - AwaySession

/// A span of time the user was away from the Mac — locked, asleep, in a
/// Focus, presenting, or manually started — maps `away_sessions` per
/// docs/architecture/DATABASE_SCHEMA.md#canonical-ddl.
///
/// Notifications delivered while a session is open are linked to it via
/// `notifications.away_session_id`; `DigestEngine` uses that link (plus the
/// `presented = 0` signal) to build the "missed while away" set.
///
/// > Note: `MutablePersistableRecord`, not `PersistableRecord` — see the
/// > equivalent note on ``AppRecord``. `PersistableRecord.didInsert(_:)` is
/// > non-mutating and would not write `id` back to the caller's variable.
public struct AwaySession: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    /// Why the session started. Raw values are the archive column
    /// vocabulary (`away_sessions.reason`) — never a Swift case name change
    /// without a migration.
    public enum Reason: String, Codable, Hashable, Sendable {
        case locked
        case asleep
        case focus
        case presenting
        case manual
    }

    public static let databaseTableName = "away_sessions"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    // MARK: - Associations

    /// Notifications delivered while this session was open. `ON DELETE SET
    /// NULL` on `notifications.away_session_id`, so deleting a session never
    /// deletes the notifications it covered.
    public static let notifications = hasMany(ArchivedNotification.self)

    /// At most one digest is built per session (`digests.away_session_id`
    /// has no uniqueness constraint in the DDL, but the digest pipeline only
    /// ever writes one). `ON DELETE CASCADE`, so deleting a session takes
    /// its digest with it.
    public static let digest = hasOne(Digest.self)

    /// `nil` until the row is inserted; ``didInsert(_:)`` fills it from the
    /// autoincrement rowID.
    public var id: Int64?

    public var startedAt: UnixDate

    /// `nil` while the session is still open.
    public var endedAt: UnixDate?

    public var reason: Reason

    /// Whether the user has not yet returned. Equivalent to `endedAt ==
    /// nil`, spelled out for callers that just want a yes/no.
    public var isOpen: Bool {
        endedAt == nil
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
