import Foundation
import GRDB

/// One row per bundle identifier Backglance has ever captured a notification
/// from — maps `apps` per
/// docs/architecture/DATABASE_SCHEMA.md#canonical-ddl.
///
/// This row outlives its notifications: it carries the user's per-app
/// settings (retention override, exclusion, mute, OTP redaction), so those
/// choices are not lost when every notification for the app is pruned.
///
/// > Note: `MutablePersistableRecord`, not `PersistableRecord`. GRDB's
/// > `PersistableRecord.didInsert(_:)` is non-mutating (it exists for
/// > reference types); on a struct it silently fails to write `id` back to
/// > the caller's variable. `MutablePersistableRecord`'s `mutating func
/// > didInsert` is the variant that actually captures the rowID here.
public struct AppRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "apps"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    // MARK: - Associations

    /// This app's notifications. The foreign key (`notifications.app_id`,
    /// `ON DELETE CASCADE`) is declared in the DDL, so GRDB infers the join
    /// without an explicit column list.
    public static let notifications = hasMany(ArchivedNotification.self)

    /// `nil` until the row is inserted; ``didInsert(_:)`` fills it from the
    /// autoincrement rowID.
    public var id: Int64?

    /// The system store's `app.identifier`, e.g. `com.apple.MobileSMS`.
    /// `UNIQUE` in the schema; capture looks a row up by this before falling
    /// back to inserting a new one.
    public var bundleId: String

    /// Localized app name resolved by `EnrichmentService` at first sight and
    /// refreshed lazily; `nil` until then. Assigning it re-derives
    /// ``displayNameKey``.
    public var displayName: String? {
        didSet {
            displayNameKey = displayName?.matchKey
        }
    }

    /// ``displayName`` folded by ``Swift/String/matchKey`` — what `from:`
    /// compares against.
    ///
    /// SQLite's `lower()` folds A–Z and nothing else, so matching a
    /// Swift-folded needle against `lower(display_name)` missed every
    /// non-ASCII name: `from:isbank` did not find "İŞBANK". Both sides now
    /// fold the same way, in Swift.
    ///
    /// Derived, never passed in — see ``ArchivedNotification/senderKey``.
    public private(set) var displayNameKey: String?

    /// `.inherit` defers to the global default retention policy.
    public var retention: AppRetention = .inherit

    /// `true` = never store a notification from this app (Privacy Invariant
    /// #3: the exclusion check runs before the payload is decoded). Existing
    /// rows are hard-deleted the moment this flips to `true`.
    public var isExcluded = false

    /// Timeline de-prioritization only — capture is unaffected.
    public var isMuted = false

    /// Whether `OTPRedactor` runs on this app's notifications; `true` by
    /// default for `com.apple.MobileSMS` and `com.apple.mail`.
    public var redactOtp = false

    public var firstSeenAt: UnixDate
    public var lastSeenAt: UnixDate

    /// Denormalized live count, maintained by the insert/prune paths.
    /// `Archive.repairCounts()` recomputes it if it ever drifts.
    public var notificationCount = 0

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
