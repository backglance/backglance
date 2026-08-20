import Foundation

// MARK: - SearchQuery

/// What the user typed, plus how far to go looking.
///
/// One text field carries the whole grammar — `from:slack after:-7d invoice` —
/// because a row of dropdowns for the same thing is slower to use and harder to
/// remember. `QueryParser` is what turns it into filters and terms; nothing
/// downstream re-reads ``text``.
///
/// These three types live in `BackglanceCore` rather than in `BackglanceSearch`
/// on purpose: they are the *vocabulary* of a search, and the view layer has to
/// speak it to ask for one and to draw the answer. The engine that does the
/// searching stays in `BackglanceSearch`, which the UI never imports
/// (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction).
///
/// See docs/features/SEARCH.md#queryparser-grammar.
public struct SearchQuery: Sendable, Equatable {
    // MARK: Lifecycle

    public init(text: String, limit: Int = 200, mode: Mode = .hybrid) {
        self.text = text
        self.limit = limit
        self.mode = mode
    }

    // MARK: Public

    /// How much of the engine to run.
    public enum Mode: Sendable, Equatable {
        /// Full-text only: the branch that has to answer inside a keystroke.
        case ftsOnly

        /// FTS, then fuzzy and — when the user has turned it on — semantic.
        case hybrid
    }

    /// The raw text, grammar included.
    public var text: String

    /// The most hits worth returning. Two hundred is far more than anyone
    /// scrolls, and it bounds the fuzzy and semantic work that follows.
    public var limit = 200

    public var mode: Mode = .hybrid
}

// MARK: - SearchHit

/// One result: which notification, how well it matched, and why.
///
/// The row itself is deliberately absent. Search returns identifiers and
/// scores; the caller fetches the rows it is about to draw. That keeps a
/// hundred-hit search from decoding a hundred notifications the user will never
/// scroll to, and keeps notification text out of every layer that only needs to
/// rank things.
public struct SearchHit: Sendable, Equatable, Identifiable {
    // MARK: Lifecycle

    public init(notificationID: Int64, score: Double, snippet: String? = nil, sources: Set<Source>) {
        self.notificationID = notificationID
        self.score = score
        self.snippet = snippet
        self.sources = sources
    }

    // MARK: Public

    /// Which branch of the engine produced a hit. A result can come from more
    /// than one, and that agreement is what lifts it up the ranking.
    public enum Source: Sendable, Hashable {
        case fts
        case semantic
        case fuzzy
    }

    public let notificationID: Int64

    /// 0…1, weighted and normalized across the branches that matched.
    public let score: Double

    /// The FTS snippet, with the match markers still in it. Already-redacted
    /// text, because the snippet comes from the archive and the archive never
    /// held the original digits (Privacy Invariant #2).
    public let snippet: String?

    public let sources: Set<Source>

    public var id: Int64 {
        notificationID
    }
}

// MARK: - SearchError

/// The three ways a search can fail, and none of them is "no results".
///
/// Only a genuinely unreadable date is worth telling the user about, and even
/// that is an inline note under the field rather than an alert. A semantic
/// branch that fails is not an error at all — the hit simply lacks
/// ``SearchHit/Source/semantic``, and the user gets full-text results they can
/// still work with (docs/architecture/ARCHITECTURE.md#error-handling-patterns).
public enum SearchError: Error, Equatable, Sendable {
    /// A `before:`/`after:`/`on:` value that is neither a date nor an offset.
    case invalidQuery(String)

    /// `notifications_fts` is missing — only reachable mid-migration.
    case indexUnavailable

    /// The search was superseded by the next keystroke.
    case cancelled

    // MARK: Public

    /// One plain sentence, shown under the search field. Never contains the
    /// query text: a search string is notification content by another name.
    public var userMessage: String {
        switch self {
        case let .invalidQuery(reason):
            reason

        case .indexUnavailable:
            String(localized: "Search is still preparing. Try again in a moment.")

        case .cancelled:
            String(localized: "Search was cancelled.")
        }
    }

    /// Safe for the log: the case, never the query.
    public var logDescription: String {
        switch self {
        case .invalidQuery:
            "invalid query"

        case .indexUnavailable:
            "index unavailable"

        case .cancelled:
            "cancelled"
        }
    }
}
