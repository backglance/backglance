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
    // MARK: Lifecycle

    /// Builds a rule directly, rather than fetching one.
    ///
    /// A `public struct`'s synthesized memberwise initializer is `internal`, so without
    /// this one no module outside `BackglanceCore` could construct a `Rule` at all — and
    /// the Rules settings editor (BACKGLANCE-209) has to build an unsaved draft before it
    /// has ever touched the archive, the same way `RuleCompileError`'s own public
    /// initializer exists for cross-module test fixtures. `id` stays `nil` for that draft;
    /// ``didInsert(_:)`` fills it in once the row is actually inserted.
    public init(
        id: Int64? = nil,
        kind: Kind,
        pattern: String,
        matchField: MatchField = .any,
        appBundleId: String? = nil,
        color: String? = nil,
        priority: Int = 0,
        isEnabled: Bool = true,
        createdAt: UnixDate
    ) {
        self.id = id
        self.kind = kind
        self.pattern = pattern
        self.matchField = matchField
        self.appBundleId = appBundleId
        self.color = color
        self.priority = priority
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    // MARK: Public

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

    /// The id an unsaved editor draft evaluates as. Never a real archive id — `rules.id`
    /// is `INTEGER PRIMARY KEY AUTOINCREMENT`, so real ids start at 1 and this can never
    /// collide with one. `RulesEngine.compile(_:)` uses `rule.id ?? Rule.draftID` so a
    /// `RuleCompileError` for an unsaved draft still has somewhere to point. See
    /// docs/features/RULES.md#business-logic-rulesengine.
    public static let draftID: Int64 = -1

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
