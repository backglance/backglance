import Foundation

// MARK: - ParsedQuery

/// The result of running one text field through `QueryParser.parse(_:)`.
///
/// Half of this is free text — ``ftsMatch``, the already-quoted FTS5 `MATCH`
/// fragment, and ``terms``, the same words unquoted for the fuzzy and
/// semantic layers. The other half is structured filters — ``bundleIDs``,
/// ``sender``, ``before``, and so on — each a typed value the caller binds
/// as a SQL statement argument. Nothing here is raw user text waiting to be
/// spliced into a query string: that is the whole point of running text
/// through a parser instead of building `WHERE` clauses by hand.
///
/// See docs/features/SEARCH.md#queryparser-grammar and
/// docs/api/API_DOCUMENTATION.md#queryparser-grammar.
public struct ParsedQuery: Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        ftsMatch: String? = nil,
        terms: [String] = [],
        bundleIDs: Set<String> = [],
        appNameContains: String? = nil,
        sender: String? = nil,
        threadID: String? = nil,
        before: Date? = nil,
        after: Date? = nil,
        flags: Set<Flag> = []
    ) {
        self.ftsMatch = ftsMatch
        self.terms = terms
        self.bundleIDs = bundleIDs
        self.appNameContains = appNameContains
        self.sender = sender
        self.threadID = threadID
        self.before = before
        self.after = after
        self.flags = flags
    }

    // MARK: Public

    /// One `is:`, `has:`, or `redacted:` filter. Each case maps to exactly
    /// one SQL predicate; see the grammar table in SEARCH.md for the mapping
    /// this type doesn't encode (the parser doesn't know the schema).
    public enum Flag: Sendable, Equatable, CaseIterable {
        case unread
        case read
        case pinned
        case missed
        case vip
        case hasLink
        case hasAttachment
        case redacted
    }

    /// The escaped FTS5 `MATCH` fragment built from bare words, phrases and
    /// negations — the only string here derived from user text, and already
    /// safe to bind. `nil` when the query has no free text or negation at
    /// all (a filters-only query like `from:slack is:pinned`).
    ///
    /// Two shapes, matching docs/features/SEARCH.md#queryparser-grammar:
    /// - With at least one positive term, this is a complete match clause,
    ///   e.g. `("invoice" "over"*) NOT "draft"` — bind directly as
    ///   `notifications_fts MATCH ?`.
    /// - With only negations (the query was e.g. `-draft`, nothing else),
    ///   this is the *inner* match for the excluded terms, e.g. `"draft"`.
    ///   FTS5 has no bare `NOT` operator, so the caller wraps it as
    ///   `rowid NOT IN (SELECT rowid FROM notifications_fts WHERE
    ///   notifications_fts MATCH ?)` instead of binding it directly.
    public var ftsMatch: String?

    /// The same free words and phrases as ``ftsMatch``, unquoted and
    /// unescaped, for `FuzzyMatcher` and `SemanticIndex` — neither of which
    /// touches SQL, so they want plain text rather than an FTS fragment.
    public var terms: [String]

    /// Exact bundle ids, from `from:`/`app:` values shaped like one
    /// (`from:com.tinyspeck.slackmacgap`). Bound as `app_id IN (...)`.
    public var bundleIDs: Set<String>

    /// A `from:`/`app:` value that reads as a display name rather than a
    /// bundle id (`from:slack`). Bound as a case-insensitive contains match
    /// on the app's display name. Only the most recent such value survives
    /// if the query names more than one — this is a single filter, not a
    /// list, because "from slack or from mail" isn't a form the grammar
    /// supports today.
    public var appNameContains: String?

    /// `sender:` — bound as a contains match on the `sender` column.
    public var sender: String?

    /// `thread:` — bound as an exact match on `thread_id`.
    public var threadID: String?

    /// `before:`/`on:` — strictly before local midnight of the resolved day.
    public var before: Date?

    /// `after:`/`on:` — on or after local midnight of the resolved day.
    /// `on:<date>` sets both ``after`` and ``before`` to bracket that one
    /// local day; there is no separate "on" field, since a day is just a
    /// pair of bounds once resolved.
    public var after: Date?

    public var flags: Set<Flag>
}
