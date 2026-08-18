import Foundation
import GRDB

// MARK: - RedactionEvent

/// A record that a notification's text was redacted before it was ever
/// written to the archive — maps `redactions` per
/// docs/architecture/DATABASE_SCHEMA.md#canonical-ddl.
///
/// > 🔒 **Privacy (Invariant #2, see CLAUDE.md and
/// > docs/features/PRIVACY_CONTROLS.md):** This table never stores the
/// > original text or the code that was redacted. Redaction happens in
/// > memory, before the notification is inserted — `OTPRedactor` replaces
/// > the digits in place and only the redacted text ever reaches
/// > `ArchivedNotification`. This type deliberately has no property that
/// > could hold the original value, and nothing in this file logs one.
/// > Redaction is irreversible by design: there is no "undo" path, because
/// > there is nothing left anywhere in the archive to undo from.
public struct RedactionEvent: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    /// What kind of pattern was redacted. `.otp` is the only kind in v1.0.
    public enum Kind: String, Codable, Hashable, Sendable {
        case otp
    }

    public static let databaseTableName = "redactions"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    // MARK: - Associations

    /// The notification whose text this event redacted. `ON DELETE
    /// CASCADE`, so a redaction event never outlives the notification it
    /// describes.
    public static let notification = belongsTo(ArchivedNotification.self)

    /// `nil` until the row is inserted; ``didInsert(_:)`` fills it from the
    /// autoincrement rowID.
    public var id: Int64?

    /// → `notifications.id`, `ON DELETE CASCADE`.
    public var notificationId: Int64

    public var kind: Kind = .otp

    /// Which pattern fired, e.g. `otp.keyword.en`, `otp.keyword.tr`,
    /// `otp.keyword.de`, `otp.body-only`.
    public var patternId: String

    public var redactedAt: UnixDate

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
