import Foundation

// MARK: - RulesDocument

/// The `backglance.rules` v1 JSON envelope — what `RulesEngine.exportRules()` writes and
/// `RulesEngine.importRules(from:)` reads. See
/// docs/features/RULES.md#ui-components's "Import and export" subsection for the exact
/// contract and a worked example.
///
/// Deliberately a separate type from `Rule`, not `Rule` itself with a couple of fields
/// stripped by `CodingKeys`: `Rule.id` is an autoincrement rowID with meaning only inside
/// one archive, `Rule.createdAt` is when *this* archive first saw the rule, and neither
/// travels sensibly across a file — an id from one Mac would either collide with an
/// unrelated row on another or silently overwrite it, and a stamped `createdAt` would lie
/// about when the receiving archive actually adopted the rule. `RulesDocument.Entry`
/// carries only what actually defines a rule's behaviour, which is also exactly the triple
/// (`kind`, `pattern`, `matchField`) `RulesEngine.importRules(from:)` uses to recognise "this
/// rule already exists" on the way back in.
///
/// Keys are plain camelCase (`appBundleID`, not `app_bundle_id`) even though `Rule` itself
/// is a GRDB record that reads and writes snake_case columns
/// (`Rule.databaseColumnDecodingStrategy`/`databaseColumnEncodingStrategy`). Those two
/// encodings serve different audiences — one is the archive's on-disk column names, the
/// other is a file a user might open in a text editor or hand-edit — and `RulesDocument`
/// uses `JSONEncoder`/`JSONDecoder` with no key strategy at all, so its wire format is
/// simply this type's own Swift property names, matching the sample in RULES.md verbatim.
///
/// The same envelope shape (`format`, `version`, an entry array) is reused, with a
/// different `format` string and a sibling `savedSearches` key, by the `backglance.searches`
/// file described in docs/features/SAVED_SEARCHES.md#export-and-import — that type is a
/// different task's problem; this one only ever reads or writes `backglance.rules`.
public struct RulesDocument: Codable, Equatable, Sendable {
    // MARK: Lifecycle

    /// The general form, for tests that need to build a deliberately wrong envelope —
    /// a stale `version` or a `format` that isn't `backglance.rules` — to exercise
    /// `RulesEngine.importRules(from:)`'s validation. Every real export goes through
    /// `init(rules:)` instead, which can't help but stamp the current format and version.
    public init(format: String, version: Int, rules: [Entry]) {
        self.format = format
        self.version = version
        self.rules = rules
    }

    /// What `RulesEngine.exportRules()` actually builds: today's format id, today's
    /// version, and the rules themselves.
    public init(rules: [Entry]) {
        self.init(format: Self.currentFormat, version: Self.currentVersion, rules: rules)
    }

    // MARK: Public

    /// One rule, stripped of everything that is archive-local. See this type's own doc
    /// comment for why `id` and `createdAt` are absent.
    public struct Entry: Codable, Equatable, Sendable {
        // MARK: Lifecycle

        public init(
            kind: Rule.Kind,
            pattern: String,
            matchField: Rule.MatchField,
            appBundleID: String?,
            color: String?,
            priority: Int,
            isEnabled: Bool
        ) {
            self.kind = kind
            self.pattern = pattern
            self.matchField = matchField
            self.appBundleID = appBundleID
            self.color = color
            self.priority = priority
            self.isEnabled = isEnabled
        }

        /// Copies every field `RulesDocument` promises to carry out of an archived
        /// `Rule`, dropping `id` and `createdAt`. Used by `exportRules()` on every row it
        /// reads.
        public init(rule: Rule) {
            kind = rule.kind
            pattern = rule.pattern
            matchField = rule.matchField
            appBundleID = rule.appBundleId
            color = rule.color
            priority = rule.priority
            isEnabled = rule.isEnabled
        }

        // MARK: Public

        public var kind: Rule.Kind
        public var pattern: String
        public var matchField: Rule.MatchField
        public var appBundleID: String?
        public var color: String?
        public var priority: Int
        public var isEnabled: Bool

        /// Builds an unsaved `Rule` ready for `Rule.insert(db)` — `id` is `nil`, so the
        /// insert's `didInsert(_:)` fills it from the archive's own autoincrement rowID,
        /// and `createdAt` is `now`, the moment the importing archive adopted the rule,
        /// not whatever moment it was originally exported from another Mac at.
        public func rule(now: Date) -> Rule {
            Rule(
                id: nil,
                kind: kind,
                pattern: pattern,
                matchField: matchField,
                appBundleId: appBundleID,
                color: color,
                priority: priority,
                isEnabled: isEnabled,
                createdAt: UnixDate(now)
            )
        }
    }

    /// The only `format` value `importRules(from:)` accepts. Anything else — including
    /// `backglance.searches`, a file meant for a different importer entirely — throws
    /// `RulesError.importFormatMismatch(_:)` before a single entry is looked at.
    public static let currentFormat = "backglance.rules"

    /// The newest envelope version this build understands. `importRules(from:)` accepts
    /// this version or older (an older file just has nothing to say about a field this
    /// version added); anything newer throws `RulesError.importVersionUnsupported(_:)`
    /// rather than guessing at what a future field might mean.
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var rules: [Entry]
}
