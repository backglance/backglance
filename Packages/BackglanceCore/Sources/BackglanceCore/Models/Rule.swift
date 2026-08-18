import Foundation
import GRDB

// MARK: - Rule

/// A user-defined highlight, VIP, mute, or regex rule used to triage the
/// timeline — maps `rules` per docs/architecture/DATABASE_SCHEMA.md#canonical-ddl.
///
/// > ℹ️ **Info:** Rules are visual triage only. They do not change what
/// > macOS delivers, and they never call back into Notification Center. See
/// > docs/features/RULES.md.
///
/// > Note: `MutablePersistableRecord`, not `PersistableRecord` — see the
/// > equivalent note on ``AppRecord``. `PersistableRecord.didInsert(_:)` is
/// > non-mutating and would not write `id` back to the caller's variable.
public struct Rule: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    /// What the rule does when it matches.
    public enum Kind: String, Codable, Hashable, Sendable {
        /// Color the row.
        case highlight
        /// Pin to top / VIP-first in the digest.
        case vip
        /// Visually de-prioritize; capture is unaffected.
        case mute
        /// `pattern` is a regex source rather than a plain keyword.
        case regex
    }

    /// Which field(s) `pattern` is matched against.
    public enum MatchField: String, Codable, Hashable, Sendable {
        case any
        case title
        case body
        case sender
        case app
    }

    public static let databaseTableName = "rules"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    /// `nil` until the row is inserted; ``didInsert(_:)`` fills it from the
    /// autoincrement rowID.
    public var id: Int64?

    public var kind: Kind

    /// Keyword, sender, bundle id, or regex source, depending on `kind` and
    /// `matchField`.
    public var pattern: String

    public var matchField: MatchField = .any

    /// Restricts the rule to one app. `nil` means all apps. This is a soft
    /// reference by bundle id — no foreign key — so the rule survives the
    /// `apps` row being deleted.
    public var appBundleId: String?

    /// Highlight color token, e.g. `'amber'`, `'red'`, `'green'`, `'blue'`,
    /// `'purple'`.
    public var color: String?

    /// Higher wins when two highlight rules match the same notification.
    public var priority = 0

    /// Toggle without deleting.
    public var isEnabled = true

    public var createdAt: UnixDate

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
