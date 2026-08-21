# Search

Last Updated: 2026-08-18

This document specifies instant search in Backglance v1.0: full-text search over the archive with SQLite FTS5, a small query grammar for filters (`from:`, `sender:`, `before:`/`after:`/`on:`, `is:`, `has:`, quoted phrases, `-negation`), bm25 ranking with per-column weights, match highlighting, a fuzzy fallback for typos, and an opt-in semantic layer built on Apple's on-device `NLEmbedding`. The fuzzy and semantic engines are ported from PasteShelf's search stack (`FuzzyMatcher`, `SemanticSearchEngine`, `VectorSimilarityCalculator`, `HybridSearchEngine`); the storage side is GRDB, not Core Data. Everything runs locally against `~/Library/Application Support/Backglance/archive.sqlite`; nothing about a query ever leaves the machine.

## Table of Contents

- [Feature Overview](#feature-overview)
- [Architecture](#architecture)
- [Archive Tables Involved](#archive-tables-involved)
  - [FTS5 Table Design](#fts5-table-design)
  - [The Three Sync Triggers](#the-three-sync-triggers)
  - [The embeddings Table](#the-embeddings-table)
- [UI Components](#ui-components)
- [Business Logic](#business-logic)
  - [QueryParser Grammar](#queryparser-grammar)
  - [QueryParser Implementation](#queryparser-implementation)
  - [FTS Ranking and Highlighting](#fts-ranking-and-highlighting)
  - [Fuzzy Fallback](#fuzzy-fallback)
  - [Semantic Search](#semantic-search)
  - [What Semantic Search Cannot Do](#what-semantic-search-cannot-do)
  - [HybridSearch Merge](#hybridsearch-merge)
  - [Debounce and Cancellation](#debounce-and-cancellation)
- [Performance Targets](#performance-targets)
- [Redaction and Privacy](#redaction-and-privacy)
- [Edge Cases and Error Handling](#edge-cases-and-error-handling)
- [Testing Approach](#testing-approach)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Feature Overview

Search is the second thing people do with a notification archive, right after scrolling it. The v1.0 goals are narrow: results appear while you type, typos still find things, and a handful of filters cover the questions people actually ask ("what did Slack say last week", "that Messages thread from Ayşe", "did anything with a link come in while I was locked").

| Layer | v1.0 | Default | Where |
|---|---|---|---|
| Full-text (FTS5, prefix on last token) | ✅ | on, always | `BackglanceSearch/FTSIndex` |
| Filter grammar (`from:`, `sender:`, dates, `is:`, `has:`, phrases, `-neg`) | ✅ | on, always | `BackglanceSearch/QueryParser` |
| Fuzzy fallback (Levenshtein, threshold 0.6) | ✅ | on, only when FTS returns < 5 hits | `BackglanceSearch/FuzzyMatcher` |
| Semantic search (`NLEmbedding`, 512-dim, cosine) | ✅ | **off** — Settings ▸ Search ▸ "Semantic search" | `BackglanceSearch/SemanticIndex` |
| Hybrid merge (FTS 0.4 / semantic 0.5 / fuzzy 0.3) | ✅ | active whenever more than one layer produced hits | `BackglanceSearch/HybridSearch` |
| Saved searches / smart folders | v1.x | — | [SAVED_SEARCHES.md](./SAVED_SEARCHES.md) |
| `backglance://search?q=` URL scheme | ✅ | — | [EXPORT_AUTOMATION.md](./EXPORT_AUTOMATION.md) |

> ℹ️ **Info:** Search reads only Backglance's archive. It never queries Apple's system store; if a notification was never captured (see [CAPTURE.md](./CAPTURE.md)) it cannot be found here.

## Architecture

```
  ┌───────────────────────── BackglanceUI ──────────────────────────────┐
  │  SearchBar (TextField + FilterChips)                                │
  │     │ text changes                                                  │
  │     ▼                                                               │
  │  SearchViewModel (@MainActor)                                       │
  │     debounce 120 ms ── cancel previous Task ── run new Task         │
  └─────────────────────────────┬───────────────────────────────────────┘
                                │ HybridSearch.search(SearchQuery)
                                ▼
  ┌───────────────────────── BackglanceSearch ──────────────────────────┐
  │  QueryParser ──► ParsedQuery { ftsMatch, terms, filters, flags }    │
  │                                                                     │
  │      ┌────────────┐   ┌───────────────┐   ┌────────────────────┐    │
  │      │  FTSIndex  │   │ FuzzyMatcher  │   │   SemanticIndex    │    │
  │      │ MATCH+bm25 │   │ Levenshtein   │   │ NLEmbedding cosine │    │
  │      │ snippet()  │   │ on candidates │   │ over pre-filtered  │    │
  │      └─────┬──────┘   └──────┬────────┘   └─────────┬──────────┘    │
  │            │ rank list       │ rank list             │ rank list    │
  │            └────────────┬────┴───────────────────────┘              │
  │                         ▼                                           │
  │              HybridSearch (reciprocal-rank merge, weights)          │
  │                         │ [SearchHit]                               │
  └─────────────────────────┼───────────────────────────────────────────┘
                            ▼
  ┌───────────────────────── BackglanceCore ────────────────────────────┐
  │  Archive (GRDB DatabasePool, read replicas)                         │
  │   notifications ── notifications_fts (external content) ── embeddings│
  │   apps (from: resolution)   away_sessions (is:missed)               │
  └─────────────────────────────────────────────────────────────────────┘
```

Rows returned as `SearchHit` are resolved to `ArchivedNotification` in one batched `WHERE id IN (...)` fetch and rendered with the same `NotificationRow` the timeline uses ([TIMELINE.md](./TIMELINE.md)), with match ranges applied as an `AttributedString` overlay.

## Archive Tables Involved

| Table | Role in search |
|---|---|
| `notifications` | source rows; filters on `app_id`, `delivered_at`, `presented`, `away_session_id`, `deep_link`, `is_pinned`, `is_deleted` |
| `notifications_fts` | FTS5 external-content index over `title, subtitle, body, sender` |
| `apps` | resolves `from:slack` to `bundle_id = 'com.tinyspeck.slackmacgap'` by `display_name` or bundle id substring |
| `embeddings` | one 512-float vector per notification when semantic search is on |
| `away_sessions` | `is:missed` joins on `away_session_id` |
| `rules` | `is:vip` evaluates VIP rules over hits (rules are visual triage; there is no stored VIP column) |
| `saved_searches` (v1.x) | stores raw query strings, re-parsed on open |

The canonical DDL lives in [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md); the search-relevant parts are repeated below because the details matter.

### FTS5 Table Design

```sql
CREATE VIRTUAL TABLE notifications_fts USING fts5(
  title, subtitle, body, sender,
  content='notifications', content_rowid='id',
  tokenize = "unicode61 remove_diacritics 2 tokenchars '@.-'",
  prefix = '2 3'
);
```

Why each choice:

| Choice | Reason |
|---|---|
| External content (`content='notifications'`) | text is stored once, in `notifications`; the FTS table holds only the inverted index. Halves archive size versus a contentless-with-copy design and keeps `snippet()`/`highlight()` working because FTS5 reads the original columns through the content table. |
| `content_rowid='id'` | `notifications.id` is an `INTEGER PRIMARY KEY`, so it is the rowid; joins are `notifications_fts.rowid = notifications.id`. |
| `unicode61` | Unicode-aware tokenizer; case folding for Latin scripts. |
| `remove_diacritics 2` | full diacritic removal (Sequoia-era SQLite supports mode 2): `doğrulama` matches `dogrulama`, `Größe` matches `Grosse`? — no, see the ß note under [What Semantic Search Cannot Do](#what-semantic-search-cannot-do) and [Edge Cases](#edge-cases-and-error-handling); `ö` → `o` yes, `ß` stays `ß`. |
| `tokenchars '@.-'` | keeps `alex@example.com`, `v2.1.3`, `re-invoice`, `+1-555-0100` as single tokens so an email address or a version number is searchable as typed. The trade-off: `invoice-2026` will not match a bare `invoice` unless the prefix index catches it — it does for the first 2–3 characters, and full-token match works on the whole hyphenated token. |
| `prefix = '2 3'` | prefix indexes for 2- and 3-character prefixes make the as-you-type `"inv"*` query O(log n) instead of scanning the term dictionary. Longer prefixes fall back to term-dictionary range scans, which are still fast at 100k rows. |

Column order (`title, subtitle, body, sender`) is fixed because `bm25()` weights, `highlight()` and `snippet()` refer to columns by index (0–3).

### The Three Sync Triggers

External-content FTS5 tables do not update themselves. Three triggers, created in the `v1_fts` migration, keep the index in step with `notifications`. The `'delete'` command form is the documented FTS5 idiom: you must tell the index the *old* values so it can remove the right postings.

```sql
CREATE TRIGGER notifications_ai AFTER INSERT ON notifications BEGIN
  INSERT INTO notifications_fts(rowid, title, subtitle, body, sender)
  VALUES (new.id, new.title, new.subtitle, new.body, new.sender);
END;

CREATE TRIGGER notifications_ad AFTER DELETE ON notifications BEGIN
  INSERT INTO notifications_fts(notifications_fts, rowid, title, subtitle, body, sender)
  VALUES ('delete', old.id, old.title, old.subtitle, old.body, old.sender);
END;

CREATE TRIGGER notifications_au AFTER UPDATE OF title, subtitle, body, sender ON notifications BEGIN
  INSERT INTO notifications_fts(notifications_fts, rowid, title, subtitle, body, sender)
  VALUES ('delete', old.id, old.title, old.subtitle, old.body, old.sender);
  INSERT INTO notifications_fts(rowid, title, subtitle, body, sender)
  VALUES (new.id, new.title, new.subtitle, new.body, new.sender);
END;
```

Notes:

- `notifications_au` fires only on the four indexed columns. Marking read, pinning, soft-deleting or assigning `away_session_id` does not touch the index.
- Soft delete (`is_deleted = 1`) leaves the row in the index; every search query adds `AND n.is_deleted = 0`. The retention job's hard delete fires `notifications_ad` and removes postings.
- After a bulk import (`CaptureEngine.importExisting()`), `FTSIndex.optimize()` runs `INSERT INTO notifications_fts(notifications_fts) VALUES('optimize')` once, off the main actor.
- `FTSIndex.verify()` runs `INSERT INTO notifications_fts(notifications_fts) VALUES('integrity-check')` from Settings ▸ Advanced ▸ "Rebuild search index"; on failure it runs `'rebuild'`. This is the recovery path if the archive was ever edited outside Backglance.

The GRDB migration that creates all of this:

```swift
// Packages/BackglanceCore/Sources/BackglanceCore/Archive/ArchiveMigrations.swift (excerpt)
migrator.registerMigration("v1_fts") { db in
    try db.execute(sql: ftsTableSQL)      // the canonical CREATE VIRTUAL TABLE, verbatim
    try db.execute(sql: ftsTriggersSQL)   // notifications_ai / _ad / _au, written by hand
}
```

> ℹ️ **Info:** The migration issues the canonical DDL directly rather than going through
> GRDB's `create(virtualTable:using: FTS5())` builder. The builder cannot express
> `tokenchars`, so using it would mean creating the table, dropping it and recreating it
> with the SQL above — three statements to arrive at what one says exactly. Writing the
> three triggers by hand instead of `synchronize(withTable:)` follows from the same
> choice: they are named `notifications_ai/_ad/_au` rather than
> `__notifications_fts_ai/_ad/_au`, and the `'delete'` command form above is spelled out
> where a reader can check it against the FTS5 documentation.

### The embeddings Table

```sql
CREATE TABLE embeddings (
  notification_id INTEGER PRIMARY KEY REFERENCES notifications(id) ON DELETE CASCADE,
  model TEXT NOT NULL,        -- 'nl.sentence.en.v1'
  dims INTEGER NOT NULL,      -- 512
  vector BLOB NOT NULL,       -- 512 × Float32 little-endian = 2048 bytes
  created_at REAL NOT NULL
);
```

Created by migration `v2_embeddings`, which runs unconditionally; the table simply stays empty while semantic search is off. `ON DELETE CASCADE` is what makes "delete a notification, delete its vector" a database guarantee rather than an app-code promise.

## UI Components

| Component | Module | Notes |
|---|---|---|
| `SearchBar` | `BackglanceUI` | `TextField` with magnifier, clear button, filter-chip strip; `⌘F` focuses it in popover and window; `Esc` clears then closes |
| `FilterChip` | `BackglanceUI` | one per active filter (`from: Slack`, `after: 7 days`, `is: missed`); tapping removes it and rewrites the query text |
| `SearchResultsList` | `BackglanceUI` | `LazyVStack` of `NotificationRow` with `matchRanges` overlay; sections "Best matches" / "Similar" (semantic-only hits) |
| `SearchEmptyState` | `BackglanceUI` | three variants: no query yet (hint text with grammar examples), no results (offers to clear filters), semantic-off hint when the query looks like a natural-language sentence |
| `SemanticIndexProgress` | `BackglanceUI` | thin progress bar under the search bar while `EmbeddingIndexer` is running; "Indexing 3,120 of 41,000" |
| `SearchViewModel` | `BackglanceUI` | `@MainActor @Observable`; owns debounce, cancellation, `hits`, `error`, `isSearching` |

The empty-state hint text (verbatim in `Localizable.xcstrings`, key `search.hint`):

> Try `from:slack invoice`, `sender:"Ayşe" after:-7d`, `is:missed has:link`, or a sentence like "the message about the invoice" with Semantic search on.

Keyboard: `↑`/`↓` move selection, `↩` opens the notification (see [ACTIONS.md](./ACTIONS.md)), `⌘↩` opens the timeline scrolled to it ([TIMELINE.md](./TIMELINE.md)). VoiceOver labels are documented in [ACCESSIBILITY.md](../reference/ACCESSIBILITY.md).

## Business Logic

### QueryParser Grammar

`QueryParser` turns a single text field into a `SearchQuery`. It never rejects free text; only an unreadable date value produces an error, and that error is shown inline under the field rather than as an alert.

| Token | Meaning | Becomes |
|---|---|---|
| `from:<app>` | app by display name, bundle id, or unique substring (`from:slack`, `from:com.apple.MobileSMS`) | SQL filter `n.app_id IN (...)`; unresolvable app → zero results plus chip "No app matches 'xyz'" |
| `sender:<name>` | sender / contact where present (Messages, Mail, Slack DMs) | SQL filter on the `sender` column, not an FTS term — it never reaches `MATCH` |
| `thread:<id>` | exact thread, for "the rest of this conversation" | `n.thread_id = ?` |
| `before:<date>` | strictly before local midnight of that date | `n.delivered_at < ?` |
| `after:<date>` | on or after local midnight of that date | `n.delivered_at >= ?` |
| `on:<date>` | that local calendar day | `n.delivered_at >= day.start AND < day.end` |
| date forms | `2026-08-01`, `today`, `yesterday`, `-7d`, `-2w`, `-36h` (relative to now) | resolved with `Calendar.current`; day and week offsets snap to that day's local midnight, hour offsets are exact (`-36h` is a moment, not a day) |
| `is:unread` | not yet marked read | `n.is_read = 0` |
| `is:read` | marked read | `n.is_read = 1` |
| `is:missed` | arrived while away or store says not presented | `(n.away_session_id IS NOT NULL OR n.presented = 0)` |
| `is:pinned` | pinned by user | `n.is_pinned = 1` |
| `is:vip` | matches an enabled VIP rule | post-filter through `RulesEngine.evaluate` on hits ([RULES.md](./RULES.md)) |
| `has:link` | has a resolved deep link | `n.deep_link IS NOT NULL` |
| `has:attachment` | carries attachment metadata | `n.attachments_json IS NOT NULL` |
| `redacted:yes` | body held an OTP that was redacted before storage | `n.redaction = 'otp'`; any other value (`redacted:no`) has no recognized meaning and falls back to free text |
| `"quoted phrase"` | exact phrase in any indexed column | FTS phrase `"quoted phrase"` (internal quotes doubled) |
| `-word` / `-"a phrase"` | must not contain | FTS `NOT "word"`; if there are no positive terms, `rowid NOT IN (SELECT rowid FROM notifications_fts WHERE notifications_fts MATCH ...)` |
| anything else | free text | each token quoted, ANDed; the **last** free token gets a `*` prefix suffix so as-you-type works: `invoice "over"*` |
| unknown `key:value` | e.g. `re:invoice` | treated as a free-text token, not an error |

Combined example: `from:slack sender:"Ayşe" after:-7d is:missed -draft invoice over` becomes

```
appNameContains = "slack"
sender          = "Ayşe"
after           = 2026-08-10 00:00 local
flags           = {missed}
ftsMatch        = ("invoice" "over"*) NOT "draft"
terms           = ["invoice", "over"]        // fed to fuzzy + semantic
```

### QueryParser Implementation

`QueryParser` is a stateless `enum`, not a struct anyone constructs — there is nothing to configure, so `QueryParser.parse(_:now:calendar:)` is a static function. `now` and `calendar` are parameters rather than ambient state precisely so tests do not depend on when they run; the app calls it with its defaults.

The parser never rejects free text. A filter with a value it does not recognize (`is:archived`), or a key it has never heard of (`re:invoice`), degrades to a plain search term. The single exception is a `before:`, `after:` or `on:` value that is neither a date nor a relative offset, which throws `SearchError.invalidQuery` — a message that names the key and lists the accepted forms, and never echoes what the user typed.

```swift
// Packages/BackglanceSearch/Sources/BackglanceSearch/QueryParser.swift
public enum QueryParser {
    /// - Throws: `SearchError.invalidQuery` for an unreadable `before:`/`after:`/`on:`
    ///   value. Never for anything else.
    public static func parse(
        _ text: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> ParsedQuery
}
```

`SearchError` lives in `BackglanceCore` rather than here, alongside the `SearchQuery` and `SearchHit` types the UI passes around.

The result splits cleanly in two: free text on one side, typed filters on the other. Nothing in it is raw user text waiting to be spliced into a query string.

```swift
// Packages/BackglanceSearch/Sources/BackglanceSearch/ParsedQuery.swift
public struct ParsedQuery: Sendable, Equatable {
    public var ftsMatch: String?          // escaped FTS5 MATCH fragment; nil when the query is filters-only
    public var terms: [String]            // the same words unquoted, for fuzzy and semantic
    public var bundleIDs: Set<String>     // from:/app: values shaped like a bundle id
    public var appNameContains: String?   // from:/app: values that read as a display name
    public var sender: String?
    public var threadID: String?
    public var before: Date?
    public var after: Date?
    public var flags: Set<Flag>

    public enum Flag: Sendable, Equatable, CaseIterable {
        case unread, read, pinned, missed, vip, hasLink, hasAttachment, redacted
    }

    public var isNegationOnly: Bool
    public var isEmpty: Bool
}
```

Three details matter to callers, because they are where a caller gets it wrong:

- **`ftsMatch` means two different things.** With at least one positive term it is a complete match clause — `("invoice" "over"*) NOT "draft"` — bound directly as `notifications_fts MATCH ?`. With only negations (`-draft` and nothing else) FTS5 has no bare `NOT`, so `ftsMatch` carries just the excluded terms and the caller wraps it as `rowid NOT IN (SELECT rowid FROM notifications_fts WHERE notifications_fts MATCH ?)`. `isNegationOnly` is how the two are told apart.
- **`sender:` is a structured filter, not an FTS column filter.** It binds as a contains match on the `sender` column in `HybridSearch+Filters.swift` and never reaches the `MATCH` expression.
- **Dates resolve in three tiers** — named (`today`, `yesterday`), relative (`-7d`, `-2w`, `-36h`) and absolute (`yyyy-MM-dd`). Day and week forms snap to local midnight; hour forms are exact.

The tokenizer, the per-key dispatch and the FTS quoting are deliberately not reproduced here. `QueryParser.swift` is short enough to read, and `QueryParserTests.swift` is where the grammar's edge cases are pinned down — including the two easiest to trip over: a lone `-` produces no token at all, and a token that *starts* with a colon (`:foo`) is free text, so a filter can never have an empty key.

### FTS Ranking and Highlighting

`FTSIndex.search` runs a single statement. Column weights favour the title (3.0) and sender (2.0) over subtitle (1.5) and body (1.0): a query that matches a sender name or a title should outrank one that merely appears in a long body.

```swift
// Packages/BackglanceSearch/Sources/BackglanceSearch/FTSIndex.swift
public struct FTSHit: Sendable, Equatable {
    public let notificationID: Int64
    public let score: Double     // bm25: lower is better; negated before merge
    public let snippet: String   // contains U+E000/U+E001 markers around the match
}

public struct FTSIndex: Sendable {
    public static let markerOpen = "\u{E000}"
    public static let markerClose = "\u{E001}"

    public init(archive: Archive)

    /// `match` is a fully-built FTS5 `MATCH` expression from `QueryParser`.
    /// `filter` is the structured `WHERE` fragment from `HybridSearch+Filters`,
    /// applied inside this statement rather than as a second pass over the
    /// candidate ids.
    /// - Throws: `SearchError.indexUnavailable` if `notifications_fts` doesn't
    ///   exist yet (only reachable mid-migration).
    public func search(
        match: String,
        appIDs: [Int64] = [],
        filter: (sql: String, arguments: StatementArguments)? = nil,
        limit: Int = 200
    ) throws -> [FTSHit]

    public func rebuild() throws    // notifications_fts('rebuild'); after a bulk import
    public func optimize() throws   // notifications_fts('optimize'); after a big deletion batch
}
```

The snippet is taken from column `-1` — FTS5's "whichever column matched best" — rather than a fixed column, so a title-only match still gets a snippet instead of SQL `NULL`. See `FTSIndex.swift` for the full statement and `FTSIndexTests.swift` for the ranking, snippet and `indexUnavailable` assertions.

The private-use markers are converted to `AttributedString` emphasis ranges by `MatchHighlighter.attributed(_:open:close:)` in `Packages/BackglanceUI/Sources/BackglanceUI/Search/MatchHighlighter.swift`. An unbalanced open marker (a truncated snippet) still emphasizes to the end of the string rather than dropping text or crashing.

### Fuzzy Fallback

FTS5 prefix matching handles "I stopped typing early"; it does not handle "I typed it wrong". When FTS returns fewer than 5 hits and the query has at least one free term of length ≥ 3, `FuzzyMatcher` (ported from PasteShelf) runs Levenshtein similarity over a bounded candidate set: distinct `title` and `sender` values of the 5,000 most recent notifications that pass the same app/date filters. Similarity is `1 − distance / max(len)`; candidates at or above **0.6** are kept.

```swift
// Packages/BackglanceSearch/Sources/BackglanceSearch/FuzzyMatcher.swift
import Foundation

public struct FuzzyMatcher: Sendable {
    public var threshold: Double
    public init(threshold: Double = 0.6) { self.threshold = threshold }

    public struct Candidate: Sendable { public let id: Int64; public let text: String }
    public struct Match: Sendable { public let id: Int64; public let similarity: Double }

    public func matches(query: String, in candidates: [Candidate]) -> [Match] {
        let q = Array(query.lowercased().unicodeScalars)
        guard q.count >= 3 else { return [] }
        var out: [Match] = []
        out.reserveCapacity(64)
        for c in candidates {
            // Compare against each word and the whole string; keep the best.
            var best = 0.0
            for word in c.text.lowercased().split(separator: " ") {
                best = max(best, similarity(q, Array(word.unicodeScalars)))
                if best >= 1.0 { break }
            }
            if best >= threshold { out.append(Match(id: c.id, similarity: best)) }
        }
        return out.sorted { $0.similarity > $1.similarity }
    }

    func similarity(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Double {
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 1.0 }
        // Cheap early exit: length difference alone already breaks the threshold.
        if Double(abs(a.count - b.count)) / Double(maxLen) > (1.0 - threshold) { return 0.0 }
        return 1.0 - Double(levenshtein(a, b)) / Double(maxLen)
    }

    /// Two-row dynamic programming Levenshtein; O(a·b) time, O(b) memory.
    func levenshtein(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}
```

The 5,000-row cap keeps the worst case around 5,000 × (a few words) × (short Levenshtein) — well under 20 ms on Apple silicon; the cap is a constant in `HybridSearch.Limits.fuzzyCandidates` and is documented, not configurable in the UI.

### Semantic Search

Semantic search is **off by default** (Settings ▸ Search ▸ "Semantic search", `@AppStorage("search.semanticEnabled")`). Turning it on starts `EmbeddingIndexer`, which walks the archive newest-first in batches of 50, computes one vector per notification with `NLEmbedding.sentenceEmbedding(for: .english)` and stores it as a `Float32` BLOB. New notifications are embedded shortly after capture (same batcher, triggered by the archive's `ValueObservation` on inserts). Turning it off stops the indexer and offers "Delete embeddings (frees ~2 KB per notification)".

The text embedded is `[title, subtitle, body].compactMap { $0 }.joined(" · ")` **after** OTP redaction — the placeholder `[code redacted]` is what gets embedded, never a code.

```swift
// Packages/BackglanceSearch/Sources/BackglanceSearch/SemanticIndex.swift
import Foundation
import NaturalLanguage
import GRDB
import BackglanceCore

public struct SemanticHit: Sendable, Equatable {
    public let notificationID: Int64
    public let similarity: Double     // cosine, 1.0 = identical
}

public actor SemanticIndex {
    public static let modelID = "nl.sentence.en.v1"
    public static let dims = 512

    public enum SemanticError: Error, LocalizedError {
        case modelUnavailable
        case dimensionMismatch(expected: Int, got: Int)
        public var errorDescription: String? {
            switch self {
            case .modelUnavailable:
                return "The on-device English sentence model isn't available on this Mac. Semantic search is disabled; full-text search still works."
            case let .dimensionMismatch(e, g):
                return "Embedding model returned \(g) dimensions, expected \(e)."
            }
        }
    }

    private let archive: Archive
    private let embedding: NLEmbedding?

    public init(archive: Archive) {
        self.archive = archive
        self.embedding = NLEmbedding.sentenceEmbedding(for: .english)
    }

    public var isAvailable: Bool { embedding != nil }

    /// Query-side embedding. Throws when the model is missing so callers can fall back to FTS.
    public func embed(_ text: String) throws -> [Float] {
        guard let embedding else { throw SemanticError.modelUnavailable }
        guard let v = embedding.vector(for: text) else { return [] }   // empty text → no vector
        guard v.count == Self.dims else {
            throw SemanticError.dimensionMismatch(expected: Self.dims, got: v.count)
        }
        return v.map(Float.init)
    }

    /// Brute-force cosine over candidates pre-filtered by the same app/date predicates as FTS.
    public func search(queryVector: [Float], appIDs: [Int64], after: Date?, before: Date?,
                       candidateLimit: Int = 20_000, topK: Int = 50) async throws -> [SemanticHit] {
        guard queryVector.count == Self.dims else { return [] }
        let qNorm = norm(queryVector)
        guard qNorm > 0 else { return [] }

        return try await archive.reader.read { db in
            var sql = """
                SELECT e.notification_id AS id, e.vector AS vector
                FROM embeddings e
                JOIN notifications n ON n.id = e.notification_id
                WHERE n.is_deleted = 0 AND e.model = ? AND e.dims = ?
                """
            var args: StatementArguments = [Self.modelID, Self.dims]
            if !appIDs.isEmpty {
                sql += " AND n.app_id IN (" + appIDs.map { _ in "?" }.joined(separator: ",") + ")"
                args += StatementArguments(appIDs)
            }
            if let after  { sql += " AND n.delivered_at >= ?"; args += [after.timeIntervalSince1970] }
            if let before { sql += " AND n.delivered_at < ?";  args += [before.timeIntervalSince1970] }
            sql += " ORDER BY n.delivered_at DESC LIMIT ?"
            args += [candidateLimit]

            var hits: [SemanticHit] = []
            let cursor = try Row.fetchCursor(db, sql: sql, arguments: args)
            while let row = try cursor.next() {
                try Task.checkCancellation()
                let blob: Data = row["vector"]
                guard blob.count == Self.dims * MemoryLayout<Float>.size else { continue } // corrupt row: skip, not fail
                let sim = blob.withUnsafeBytes { raw -> Double in
                    let v = raw.bindMemory(to: Float.self)
                    var dot: Float = 0, n: Float = 0
                    for i in 0..<Self.dims { dot += v[i] * queryVector[i]; n += v[i] * v[i] }
                    return n > 0 ? Double(dot) / (Double(n.squareRoot()) * Double(qNorm)) : 0
                }
                if sim > 0.35 { hits.append(SemanticHit(notificationID: row["id"], similarity: sim)) }
            }
            hits.sort { $0.similarity > $1.similarity }
            return Array(hits.prefix(topK))
        }
    }

    private func norm(_ v: [Float]) -> Float { v.reduce(0) { $0 + $1 * $1 }.squareRoot() }
}
```

The 0.35 floor is a "don't show nonsense" cut-off found by trial against the seeded test archive; it is not user-facing.

The background indexer:

```swift
// Packages/BackglanceSearch/Sources/BackglanceSearch/EmbeddingIndexer.swift
import Foundation
import GRDB
import BackglanceCore

public actor EmbeddingIndexer {
    public struct Progress: Sendable, Equatable { public var done: Int; public var total: Int }

    private let archive: Archive
    private let index: SemanticIndex
    private var task: Task<Void, Never>?
    public private(set) var progress = Progress(done: 0, total: 0)
    private var continuation: AsyncStream<Progress>.Continuation?
    public nonisolated let progressStream: AsyncStream<Progress>

    public init(archive: Archive, index: SemanticIndex) {
        self.archive = archive
        self.index = index
        var c: AsyncStream<Progress>.Continuation?
        self.progressStream = AsyncStream { c = $0 }
        self.continuation = c
    }

    public func start() {
        guard task == nil else { return }
        task = Task(priority: .utility) { [weak self] in await self?.run() }
    }

    public func stop() { task?.cancel(); task = nil }

    private func run() async {
        do {
            let total = try await archive.reader.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM notifications n
                    LEFT JOIN embeddings e ON e.notification_id = n.id
                    WHERE n.is_deleted = 0 AND e.notification_id IS NULL
                    """) ?? 0
            }
            progress = Progress(done: 0, total: total)
            continuation?.yield(progress)

            while !Task.isCancelled {
                let batch = try await archive.reader.read { db in
                    try Row.fetchAll(db, sql: """
                        SELECT n.id, n.title, n.subtitle, n.body FROM notifications n
                        LEFT JOIN embeddings e ON e.notification_id = n.id
                        WHERE n.is_deleted = 0 AND e.notification_id IS NULL
                        ORDER BY n.delivered_at DESC LIMIT 50
                        """)
                }
                if batch.isEmpty { break }

                var rows: [(Int64, Data)] = []
                for r in batch {
                    let text = [r["title"] as String?, r["subtitle"] as String?, r["body"] as String?]
                        .compactMap { $0 }.joined(separator: " · ")
                    let vector = try await index.embed(text)
                    guard !vector.isEmpty else { continue }
                    rows.append((r["id"], vector.withUnsafeBufferPointer { Data(buffer: $0) }))
                }
                try await archive.writer.write { db in
                    for (id, blob) in rows {
                        try db.execute(sql: """
                            INSERT OR REPLACE INTO embeddings(notification_id, model, dims, vector, created_at)
                            VALUES (?, ?, ?, ?, ?)
                            """, arguments: [id, SemanticIndex.modelID, SemanticIndex.dims, blob, Date().timeIntervalSince1970])
                    }
                }
                progress.done += batch.count
                continuation?.yield(progress)
                try await Task.sleep(for: .milliseconds(20))   // yield to the capture path
            }
        } catch is CancellationError {
            Logger.search.info("Embedding indexer cancelled at \(self.progress.done)/\(self.progress.total)")
        } catch {
            Logger.search.error("Embedding indexer stopped: \(error.localizedDescription, privacy: .public)")
            // Semantic search stays 'enabled' in settings; the Settings row shows the error text
            // and a Retry button. FTS is unaffected.
        }
        task = nil
    }
}
```

> ⚠️ **Warning:** `NLEmbedding.sentenceEmbedding(for:)` returns `nil` on machines where the model asset is absent (fresh installs that have never downloaded language assets, some managed Macs). Backglance treats that as "semantic unavailable": the setting stays visible but disabled, with the `modelUnavailable` message under it, and every search silently runs FTS + fuzzy only.

### What Semantic Search Cannot Do

Honest limits, stated in Settings next to the toggle:

- **The model is English.** `NLEmbedding.sentenceEmbedding(for: .english)` is the only sentence-level model Apple ships that is broadly available on macOS 14+. Turkish, German and other non-English notification text gets *some* vector — the model tokenizes it — but the geometry is not meaningful. "fatura hakkındaki mesaj" will not reliably find "Fatura #2231 ödendi". For those queries the FTS layer carries the result; the hybrid merge already weights a strong FTS hit above a weak semantic one.
- **It does not understand your apps.** "the Slack thing from Ayşe" is better written as `from:slack sender:Ayşe`. The parser gives the semantic layer only the free-text words.
- **Short queries are noise.** Under three words the semantic layer is skipped entirely; cosine similarity between one-word vectors is not informative.
- **It is not a summarizer or a chat.** It ranks stored notifications; it does not generate text.
- **It costs disk.** ~2 KB per notification; 100k notifications ≈ 200 MB. Setting shows the live number.

See [INTERNATIONALIZATION.md](../reference/INTERNATIONALIZATION.md) for the broader language story.

### HybridSearch Merge

Ranking lists from the three layers are combined with reciprocal-rank fusion. Each layer contributes `weight × 1 / (k + rank)` with `k = 60` (the usual RRF constant) for every notification it returned; scores are summed per notification and the list is sorted descending, with the newest id breaking a tie. Weights are the PasteShelf values: **FTS 0.4, semantic 0.5, fuzzy 0.3**. Rank-based fusion is what lets a bm25 score (negative, unbounded), a cosine similarity (0…1) and a Levenshtein similarity (0…1) be merged without hand-tuned normalisers.

```swift
// Packages/BackglanceSearch/Sources/BackglanceSearch/HybridSearch.swift
public actor HybridSearch {
    public enum Limits {
        public static let fuzzyCandidates = 5_000
        public static let fuzzyTriggerBelow = 5
        public static let semanticMinWords = 3
        public static let rrfK = 60.0
        public static let weightFTS = 0.4, weightSemantic = 0.5, weightFuzzy = 0.3
    }

    public init(
        archive: Archive,
        semantic: SemanticIndex? = nil,
        fuzzy: FuzzyMatcher = FuzzyMatcher(),
        triage: any TriageEvaluating = NoTriage()
    )

    /// Parses `query.text`, then runs FTS, fuzzy (only when FTS came back
    /// thin) and — when `semanticEnabled` and the free text reads as a
    /// sentence — semantic, and fuses the branches.
    /// - Throws: `SearchError.invalidQuery` for an unreadable date, and
    ///   `SearchError.cancelled` when a later keystroke superseded this search.
    public func search(_ query: SearchQuery, semanticEnabled: Bool = false) async throws -> [SearchHit]

    /// Full text only, synchronously — what the timeline's search field calls
    /// while the user is still typing.
    nonisolated public func ftsOnly(_ query: SearchQuery, limit: Int = 200) throws -> [SearchHit]

    /// The merge itself: static and pure, so the arithmetic is testable
    /// without an archive, an index or an embedding model.
    static func fuse(fts: [FTSHit], fuzzy: [FuzzyMatcher.Match], semantic: [SemanticHit]) -> [SearchHit]
}
```

A `from:`/`app:` term that matches no known app is a deliberate zero results, not a dropped filter — showing everything when a filter matched nothing is the failure that makes people stop trusting a search box. The structured filters (`after`, `before`, `sender`, `thread`, flags) ride inside the same FTS statement rather than a second pass over the candidate ids — built by `HybridSearch+Filters.swift`, which exposes `filterSQL`, `filterFragment` and `fuzzyCandidateSQL` as pure `(sql, arguments)` builders. The semantic branch never throws: a failure there costs the hit its `.semantic` source, never the whole search.

`AppResolver.resolve(_:)` unions two passes: an exact match against every id in `bundleIDs`, and a case-insensitive substring match of `appNameContains` against `apps.display_name` OR `apps.bundle_id` — so `from:mail` returns both Mail and Airmail; users disambiguate with the bundle id.

The merge loop and the SQL builders are deliberately not reproduced here; `HybridSearchTests.swift` pins the fusion arithmetic (weights, rank order, tie-breaking) and `HybridSearch.swift` is short enough to read directly.

### Debounce and Cancellation

Search runs as you type. Two mechanisms keep it cheap: a 120 ms debounce so a fast typist triggers one query per pause rather than one per keystroke, and structured cancellation so a superseded query stops reading the archive.

```swift
// Packages/BackglanceUI/Sources/BackglanceUI/Search/SearchViewModel.swift
@MainActor @Observable
public final class SearchViewModel {
    public init(
        search: any SearchRunning,
        semanticEnabled: @escaping @Sendable () -> Bool = { false },
        debounce: Duration = .milliseconds(120)
    )

    public private(set) var hits: [SearchHit]
    public private(set) var isSearching: Bool
    public private(set) var inlineError: String?   // one sentence, never the query text

    /// Assigning schedules a search after `debounce`; it does not run one.
    public var text: String

    public func clear()             // what Esc does before it closes anything
    public func searchNow() async   // runs immediately, skipping the debounce — what ↩ does
}
```

`SearchRunning` is a one-method protocol (`search(_:semanticEnabled:) async throws -> [SearchHit]`) that `HybridSearch` conforms to; the view model depends on that protocol rather than importing `BackglanceSearch` directly, so `BackglanceUI` never imports the search engine (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction), and tests hand it a stub for determinism.

Sleeping happens before any work starts, which is what makes this a debounce rather than a throttle: a cancelled sleep throws before the search runs. After the search returns, cancellation is checked once more — a newer keystroke may have won while the archive was being read — so a superseded result is dropped rather than shown. `SearchViewModelTests.swift` covers both: one query per pause, and a stale result losing the race.

The `SearchBar` view is thin: a `TextField` bound to `viewModel.text`, a `ProgressView` when `isSearching` (delayed so a fast search never flickers one), the chip strip, and the inline error `Text` in the secondary colour.

## Performance Targets

Numbers from [PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md), measured on the CI `macos-26` runner with the 100k seeded archive:

| Path | Target (p95) | Notes |
|---|---|---|
| FTS only (`invoice`), 100k rows | < 50 ms | prefix index; `LIMIT 200` |
| FTS + filters (`from:slack after:-7d invoice`) | < 50 ms | filters ride `idx_notifications_app_delivered` |
| Fuzzy fallback | + < 20 ms | 5,000 candidates cap |
| Semantic, 20,000 candidates | < 150 ms | brute-force cosine, `Float32`, cursor read |
| Hybrid total | < 250 ms | fuzzy and semantic run concurrently after FTS |
| Embedding one batch of 50 | ~300–600 ms | Apple silicon; runs at `.utility` priority |

Reads use `DatabasePool` readers so a search never blocks capture writes. If FTS ever exceeds 50 ms at p95 the first suspects are a missing `'optimize'` after import and `is_deleted` rows piling up before the retention job — both visible in Settings ▸ Advanced ▸ Diagnostics ([MONITORING_LOGGING.md](../operations/MONITORING_LOGGING.md)).

## Redaction and Privacy

- **OTP placeholder is indexed as text.** After `OTPRedactor` runs, `body` contains the literal `[code redacted]`; the tokenizer splits it into `code` and `redacted`. Searching `code` or `redacted` finds the notification; searching for any digits cannot, because the digits were never written to `notifications`, `notifications_fts`, or `embeddings`. See [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md).
- **Embeddings live in the archive**, same file, same `0600` permissions, same FileVault coverage; nothing is uploaded and no model runs off-device.
- **Deleting a notification deletes its vector** via `ON DELETE CASCADE` on `embeddings.notification_id`; soft-deleted rows are excluded from candidates by `n.is_deleted = 0` until the retention job hard-deletes them.
- **Panic wipe** (`PanicWipe.execute()`) closes the pool and secure-deletes the archive including `notifications_fts` and `embeddings`; there is no separate vector file to forget.
- **Search text is not logged.** `os.Logger` messages carry counts and timings, never the query string or a snippet; the debug log at `~/Library/Logs/Backglance/backglance.log` follows the same rule.
- **Saved searches (v1.x)** store the raw query string in the archive; that string can contain a sender's name and is covered by the same wipe.

> 🔒 **Security:** The only network access in Backglance is the Sparkle updater. Search — including semantic search — makes zero network calls, and there is no telemetry about what people search for.

## Edge Cases and Error Handling

| Case | Behaviour |
|---|---|
| User types FTS operators (`AND`, `NEAR`, `(`, `*`, `:`) | every token is quoted (`ftsQuote`), so they are literal text. The only special characters are the leading `-`, the surrounding `"` and the recognised `key:` prefixes. |
| Unterminated quote (`"invoice over`) | treated as a phrase to end of input; no error |
| Very short query (1 character) | FTS prefix on 1 char is allowed by SQLite but skipped by Backglance: the parser still runs, `HybridSearch` returns `[]` and the empty state shows the hint. 2+ characters search normally (prefix index covers 2 and 3). |
| Only filters, no text (`is:missed from:slack`) | `filterOnly` path; ordered by `delivered_at DESC`, no snippets |
| Only negations (`-draft`) | `isNegationOnly` is true and `ftsMatch` carries just the excluded terms; the caller wraps it in a `NOT IN` subquery over the FTS table |
| `from:` matches nothing | zero results plus a chip reading "No app matches 'xyz'"; no error dialog |
| `before:` / `after:` unreadable | `SearchError.invalidQuery` shown inline; results from the previous good query stay on screen |
| `after:` later than `before:` | valid query, zero results; the empty state says "Date range is empty" |
| Turkish dotless ı / dotted İ | `unicode61` case-folds `I → i` and `İ → i̇` → (`remove_diacritics`) `i`, but **`ı` (U+0131) has no diacritic to remove and does not fold to `i`**. Typing `isik` will not match `ışık`; typing `ışık` matches exactly. Documented in Settings ▸ Search help and [INTERNATIONALIZATION.md](../reference/INTERNATIONALIZATION.md); the fuzzy layer usually rescues it (distance 1–2). |
| German ß | not decomposed by `remove_diacritics`; `strasse` does not match `Straße` in FTS. Fuzzy layer catches short cases. |
| Emoji-only notification text | tokenizer yields no tokens; the row is unsearchable by text but reachable through filters |
| Archive locked / busy (retention job mid-`VACUUM`) | GRDB throws `SQLITE_BUSY` after the 2 s busy timeout; view model shows the generic error and keeps the last results |
| FTS index corrupt (`integrity-check` fails) | Settings ▸ Advanced surfaces "Search index needs rebuilding"; `FTSIndex.rebuild()` runs `'rebuild'` in a background task with progress; searches during rebuild may return partial results and say so |
| `NLEmbedding` model unavailable | semantic layer disabled with message; toggle disabled; hybrid runs FTS + fuzzy |
| Embedding vector wrong length | row skipped; the indexer logs once and re-embeds that id on the next pass |
| Semantic on, indexer mid-run | results include only embedded rows; the progress bar explains why "Similar" is sparse |
| Query changes while a search runs | old `Task` cancelled; `Task.checkCancellation()` between stages and inside the semantic cursor loop; late results are discarded |
| 100k+ archive on Intel | FTS unchanged; semantic candidate cap (20,000) keeps hybrid under 400 ms — accepted as best-effort on Intel ([TECH_STACK.md](../architecture/TECH_STACK.md)) |

> ❌ **Don't:** interpolate user text into the MATCH string without `ftsQuote`. Even one bare token can raise `fts5: syntax error` and, worse, a bare `*` or `^` changes what the query means.

> ✅ **Do:** keep the fallback ordering — FTS first, then fuzzy only when thin, then semantic only when enabled and worthwhile. It is what keeps p95 predictable.

## Testing Approach

Search tests split by what they need: parser and fusion-arithmetic tests are pure Swift, no archive; the FTS, semantic and end-to-end tests run against a real `Archive(inMemory: true)`, because the behavior under test — bm25 weighting, snippet markers, cosine ranking — only exists once the underlying engine actually runs the query. Nothing here touches the user's archive or Apple's store.

- **`QueryParserTests.swift`** (`Tests/BackglanceSearchTests/Unit`) — every `key:value` filter, all three date tiers, phrases, negation, and `testInvalidDateThrowsWithoutEchoingTheQuery`, the one case that throws `SearchError.invalidQuery` and asserts the message never contains what the user typed.
- **`FTSIndexTests.swift`** (`Unit`) — a real in-memory archive. `testTitleOutranksBody` for the bm25 column weights, `testSnippetCarriesMatchMarkers`, `testDeletedRowsNeverReturned`, and `testMissingIndexThrowsIndexUnavailable` for the one error `FTSIndex.search` throws.
- **`HybridSearchTests.swift`** (`Integration`) — two halves: `HybridSearch.fuse` tested directly as pure arithmetic (weights, rank order, tie-breaking on id, `testNothingInNothingOut`), and `HybridSearch.search` tested end to end against a seeded archive (a free term, a filters-only query, a negation-only query, `testAnAppFilterThatMatchesNothingReturnsNothing`).
- **`SemanticIndexTests.swift`** / **`EmbeddingIndexerTests.swift`** (`Unit`) — `embeddableText` as pure string-joining logic, candidate queries asserted to apply the same `after`/`before`/app filters the full-text branch does, and ranking against precomputed vectors rather than a live model, so these do not depend on `NLEmbedding` being present on the runner.
- **`SearchViewModelTests.swift`** (`Tests/BackglanceUITests`) — the debounce (one search per pause, the last text typed wins), cancellation (`searchNow()` skips the wait, a cancelled search leaves no error), and every `emptyStateKind` case, all against a stub `SearchRunning`.
- **`SearchLatencyTests.swift`** (`Performance`) — the p95 budgets from [PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md), gated behind `BACKGLANCE_PERF=1` against a shared hundred-thousand-row archive, and skipped otherwise since runner variance would make the budget meaningless on an unstated machine.

The FTS5 sync triggers (insert/update/soft-delete/hard-delete keeping `notifications_fts` in step) are exercised alongside the rest of the archive in `Tests/BackglanceCoreTests`, not here — they are a property of the schema, not of search. CI runs the full suite on `macos-14`, `macos-15` and `macos-26` ([CI_CD.md](../deployment/CI_CD.md)); the perf suite runs only with `BACKGLANCE_PERF=1` set.

## Next Steps

- Read [TIMELINE.md](./TIMELINE.md) for how results reuse `NotificationRow` and how "Open in timeline" positions the scroll.
- Read [MISSED_DIGEST.md](./MISSED_DIGEST.md) for where `is:missed` gets its data (`away_session_id`, `presented`).
- v1.x follow-ups: saved searches and smart folders ([SAVED_SEARCHES.md](./SAVED_SEARCHES.md)), `SearchNotificationsIntent` for Shortcuts ([EXPORT_AUTOMATION.md](./EXPORT_AUTOMATION.md)).

## Related Documentation

- [TIMELINE.md](./TIMELINE.md) — row rendering, selection, pagination
- [MISSED_DIGEST.md](./MISSED_DIGEST.md) — away sessions and the `presented` flag behind `is:missed`
- [RULES.md](./RULES.md) — VIP rules used by `is:vip`
- [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md) — OTP redaction, retention, panic wipe
- [ACTIONS.md](./ACTIONS.md) — what happens when a result is opened
- [SAVED_SEARCHES.md](./SAVED_SEARCHES.md) — v1.x saved queries and smart folders
- [EXPORT_AUTOMATION.md](./EXPORT_AUTOMATION.md) — `backglance://search?q=` and Shortcuts intents
- [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md) — canonical DDL including `notifications_fts` and `embeddings`
- [TECH_STACK.md](../architecture/TECH_STACK.md) — GRDB 7.x, FTS5, NaturalLanguage, PasteShelf lineage
- [API_DOCUMENTATION.md](../api/API_DOCUMENTATION.md) — `HybridSearch`, `QueryParser`, `SearchQuery` signatures
- [PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md) — latency budgets and how they are measured
- [INTERNATIONALIZATION.md](../reference/INTERNATIONALIZATION.md) — tokenizer limits for Turkish/German, English-only embedding model
- [ACCESSIBILITY.md](../reference/ACCESSIBILITY.md) — keyboard and VoiceOver behaviour of the search bar
- [MONITORING_LOGGING.md](../operations/MONITORING_LOGGING.md) — what search logs (timings, never text)
- [TESTING.md](../testing/TESTING.md) — test targets, seeded archive helper, CI matrix
