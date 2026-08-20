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
  │  QueryParser ──► SearchQuery { matchExpression, filters, terms }    │
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
| `sender:<name>` | sender / contact where present (Messages, Mail, Slack DMs) | FTS column filter `sender:"name"*` |
| `before:<date>` | strictly before local midnight of that date | `n.delivered_at < ?` |
| `after:<date>` | on or after local midnight of that date | `n.delivered_at >= ?` |
| `on:<date>` | that local calendar day | `n.delivered_at >= day.start AND < day.end` |
| date forms | `2026-08-01`, `today`, `yesterday`, `-7d`, `-2w`, `-36h` (relative to now) | resolved with `Calendar.current` |
| `is:missed` | arrived while away or store says not presented | `(n.away_session_id IS NOT NULL OR n.presented = 0)` |
| `is:pinned` | pinned by user | `n.is_pinned = 1` |
| `is:vip` | matches an enabled VIP rule | post-filter through `RulesEngine.evaluate` on hits ([RULES.md](./RULES.md)) |
| `has:link` | has a resolved deep link | `n.deep_link IS NOT NULL` |
| `"quoted phrase"` | exact phrase in any indexed column | FTS phrase `"quoted phrase"` (internal quotes doubled) |
| `-word` / `-"a phrase"` | must not contain | FTS `NOT "word"`; if there are no positive terms, `rowid NOT IN (SELECT rowid FROM notifications_fts WHERE notifications_fts MATCH ...)` |
| anything else | free text | each token quoted, ANDed; the **last** free token gets a `*` prefix suffix so as-you-type works: `invoice "over"*` |
| unknown `key:value` | e.g. `re:invoice` | treated as a free-text token, not an error |

Combined example: `from:slack sender:"Ayşe" after:-7d is:missed -draft invoice over` becomes

```
apps      = ["com.tinyspeck.slackmacgap"]
after     = 2026-08-10 00:00 local
flags     = {missed}
MATCH     = sender:"Ayşe"* AND ("invoice" "over"*) NOT "draft"
freeTerms = ["invoice", "over"]        // fed to fuzzy + semantic
```

### QueryParser Implementation

```swift
// Packages/BackglanceSearch/Sources/BackglanceSearch/QueryParser.swift
import Foundation

public struct SearchQuery: Equatable, Sendable {
    public enum Flag: String, Sendable, CaseIterable { case missed, pinned, vip, hasLink }

    public var rawText: String
    public var matchExpression: String?      // full FTS5 MATCH string, nil when nothing to match
    public var negatedOnlyExpression: String? // used when there are negations but no positive terms
    public var appTerms: [String]            // unresolved "from:" values; AppResolver maps to app_id
    public var sender: String?
    public var after: Date?
    public var before: Date?
    public var flags: Set<Flag>
    public var freeTerms: [String]           // plain words for fuzzy + semantic
    public var phrases: [String]

    public var isEmpty: Bool {
        matchExpression == nil && negatedOnlyExpression == nil && appTerms.isEmpty
            && sender == nil && after == nil && before == nil && flags.isEmpty
    }
}

public struct QueryParser: Sendable {
    public struct Context: Sendable {
        public var now: Date
        public var calendar: Calendar
        public init(now: Date = Date(), calendar: Calendar = .current) {
            self.now = now
            self.calendar = calendar
        }
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case badDate(key: String, value: String)
        public var errorDescription: String? {
            switch self {
            case let .badDate(key, value):
                return "Couldn't read the date in \(key):\(value). Try 2026-08-01, today, yesterday or -7d."
            }
        }
    }

    private struct Token { var text: String; var isPhrase: Bool; var isNegated: Bool }

    public init() {}

    public func parse(_ input: String, context: Context = Context()) throws -> SearchQuery {
        var q = SearchQuery(rawText: input, matchExpression: nil, negatedOnlyExpression: nil,
                            appTerms: [], sender: nil, after: nil, before: nil,
                            flags: [], freeTerms: [], phrases: [])
        var positive: [String] = []          // already FTS-quoted
        var negative: [String] = []          // already FTS-quoted
        var lastFreeIndex: Int? = nil        // index into `positive` that gets the prefix star

        for tok in tokenize(input) {
            if tok.isPhrase {
                let quoted = ftsQuote(tok.text)
                if tok.isNegated { negative.append(quoted) } else { positive.append(quoted); q.phrases.append(tok.text) }
                continue
            }
            if let (key, value) = splitKeyValue(tok.text), !tok.isNegated {
                switch key {
                case "from":
                    q.appTerms.append(value)
                case "sender":
                    q.sender = value
                case "before":
                    q.before = try dayStart(of: value, key: key, context: context)
                case "after":
                    q.after = try dayStart(of: value, key: key, context: context)
                case "on":
                    let start = try dayStart(of: value, key: key, context: context)
                    q.after = start
                    q.before = context.calendar.date(byAdding: .day, value: 1, to: start)
                case "is":
                    switch value.lowercased() {
                    case "missed": q.flags.insert(.missed)
                    case "pinned": q.flags.insert(.pinned)
                    case "vip":    q.flags.insert(.vip)
                    default:       appendFree(tok.text)   // "is:foo" is just text
                    }
                case "has":
                    if value.lowercased() == "link" { q.flags.insert(.hasLink) } else { appendFree(tok.text) }
                default:
                    appendFree(tok.text)                    // unknown key → literal
                }
                continue
            }
            if tok.isNegated {
                negative.append(ftsQuote(tok.text))
            } else {
                appendFree(tok.text)
            }
        }

        func appendFree(_ text: String) {
            positive.append(ftsQuote(text))
            q.freeTerms.append(text)
            lastFreeIndex = positive.count - 1
        }

        // Prefix star on the last free (non-phrase) token so results appear as you type.
        if let i = lastFreeIndex, positive[i].count >= 2 { positive[i] += "*" }

        var parts: [String] = []
        if let s = q.sender { parts.append("sender:\(ftsQuote(s))*") }
        if !positive.isEmpty { parts.append("(" + positive.joined(separator: " ") + ")") }

        if !parts.isEmpty {
            var expr = parts.joined(separator: " AND ")
            for n in negative { expr += " NOT \(n)" }
            q.matchExpression = expr
        } else if !negative.isEmpty {
            q.negatedOnlyExpression = negative.joined(separator: " OR ")
        }
        return q
    }

    // MARK: - Helpers

    /// FTS5 string literal: wrap in double quotes, double any embedded quotes.
    /// Quoting every token is what makes user input immune to FTS5 syntax errors
    /// (bare `AND`, `(`, `:` or `*` would otherwise be interpreted).
    func ftsQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func splitKeyValue(_ s: String) -> (String, String)? {
        guard let colon = s.firstIndex(of: ":"), colon != s.startIndex else { return nil }
        let key = s[..<colon].lowercased()
        let value = String(s[s.index(after: colon)...])
        guard !value.isEmpty else { return nil }
        return (key, value)
    }

    private func dayStart(of raw: String, key: String, context: Context) throws -> Date {
        let cal = context.calendar
        let value = raw.lowercased()
        if value == "today" { return cal.startOfDay(for: context.now) }
        if value == "yesterday" {
            return cal.startOfDay(for: cal.date(byAdding: .day, value: -1, to: context.now)!)
        }
        // Relative: -7d, -2w, -36h (h keeps the exact offset; d/w snap to day start)
        if value.hasPrefix("-"), let unit = value.last, let n = Int(value.dropFirst().dropLast()) {
            switch unit {
            case "d": return cal.startOfDay(for: cal.date(byAdding: .day, value: -n, to: context.now)!)
            case "w": return cal.startOfDay(for: cal.date(byAdding: .day, value: -7 * n, to: context.now)!)
            case "h": return cal.date(byAdding: .hour, value: -n, to: context.now)!
            default: break
            }
        }
        // Absolute ISO date
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        if let d = f.date(from: value) { return cal.startOfDay(for: d) }
        throw ParseError.badDate(key: key, value: raw)
    }

    private func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var inQuotes = false
        var negated = false
        var startOfToken = true

        func flush(asPhrase: Bool) {
            let t = current.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { tokens.append(Token(text: t, isPhrase: asPhrase, isNegated: negated)) }
            current = ""; negated = false; startOfToken = true
        }

        for ch in s {
            if ch == "\"" {
                if inQuotes { flush(asPhrase: true); inQuotes = false }
                else { flush(asPhrase: false); inQuotes = true; startOfToken = false }
                continue
            }
            if inQuotes { current.append(ch); continue }
            if ch.isWhitespace { flush(asPhrase: false); continue }
            if ch == "-" && startOfToken && current.isEmpty { negated = true; startOfToken = false; continue }
            startOfToken = false
            current.append(ch)
        }
        flush(asPhrase: inQuotes)   // an unterminated quote is treated as a phrase to its end
        return tokens
    }
}
```

Two properties worth pointing out: a lone `-` (someone typing a hyphen) produces no token, and a token that *starts* with a colon (`:foo`) is free text, so `splitKeyValue` cannot produce an empty key.

### FTS Ranking and Highlighting

`FTSIndex.search` runs a single statement. Column weights favour the title (3.0) and sender (2.0) over subtitle (1.5) and body (1.0): a query that matches a sender name or a title should outrank one that merely appears in a long body.

```swift
// Packages/BackglanceSearch/Sources/BackglanceSearch/FTSIndex.swift
import Foundation
import GRDB
import BackglanceCore

public struct FTSHit: Sendable, Equatable {
    public let notificationID: Int64
    public let score: Double          // bm25: lower is better; negated before merge
    public let snippet: String        // contains U+E000/U+E001 markers around matches
}

public struct FTSIndex: Sendable {
    public static let markerOpen = "\u{E000}"
    public static let markerClose = "\u{E001}"

    private let archive: Archive
    public init(archive: Archive) { self.archive = archive }

    public func search(_ q: SearchQuery, appIDs: [Int64], limit: Int = 200) async throws -> [FTSHit] {
        guard let match = q.matchExpression else { return [] }
        return try await archive.reader.read { db in
            var sql = """
                SELECT n.id AS id,
                       bm25(notifications_fts, 3.0, 1.5, 1.0, 2.0) AS score,
                       snippet(notifications_fts, 2, char(57344), char(57345), '…', 12) AS snippet
                FROM notifications_fts
                JOIN notifications n ON n.id = notifications_fts.rowid
                WHERE notifications_fts MATCH ?
                  AND n.is_deleted = 0
                """
            var args: StatementArguments = [match]
            if !appIDs.isEmpty {
                sql += " AND n.app_id IN (" + appIDs.map { _ in "?" }.joined(separator: ",") + ")"
                args += StatementArguments(appIDs)
            }
            if let after = q.after  { sql += " AND n.delivered_at >= ?"; args += [after.timeIntervalSince1970] }
            if let before = q.before { sql += " AND n.delivered_at < ?";  args += [before.timeIntervalSince1970] }
            if q.flags.contains(.missed)  { sql += " AND (n.away_session_id IS NOT NULL OR n.presented = 0)" }
            if q.flags.contains(.pinned)  { sql += " AND n.is_pinned = 1" }
            if q.flags.contains(.hasLink) { sql += " AND n.deep_link IS NOT NULL" }
            sql += " ORDER BY score LIMIT ?"
            args += [limit]

            do {
                return try Row.fetchAll(db, sql: sql, arguments: args).map {
                    FTSHit(notificationID: $0["id"], score: $0["score"], snippet: $0["snippet"])
                }
            } catch let error as DatabaseError where error.resultCode == .SQLITE_ERROR
                        && (error.message ?? "").contains("fts5: syntax error") {
                // Should be unreachable because every token is quoted; if a future FTS5
                // build tightens the grammar we degrade to "no FTS hits" and let fuzzy run.
                Logger.search.error("FTS syntax error for quoted expression: \(error.message ?? "", privacy: .public)")
                return []
            }
        }
    }
}
```

`snippet(..., 2, ...)` picks column 2 (`body`) as the snippet source with up to 12 tokens of context; `highlight()` is used instead when the row renders the full title (`highlight(notifications_fts, 0, char(57344), char(57345))`). The private-use markers are converted to `AttributedString` ranges in `MatchHighlighter`:

```swift
// Packages/BackglanceUI/Sources/BackglanceUI/Search/MatchHighlighter.swift
import Foundation

enum MatchHighlighter {
    static func attributed(_ marked: String) -> AttributedString {
        var out = AttributedString()
        var buffer = ""
        var inMatch = false
        for ch in marked {
            switch ch {
            case "\u{E000}":
                out += AttributedString(buffer); buffer = ""; inMatch = true
            case "\u{E001}":
                var run = AttributedString(buffer)
                run.inlinePresentationIntent = .stronglyEmphasized
                out += run; buffer = ""; inMatch = false
            default:
                buffer.append(ch)
            }
        }
        if !buffer.isEmpty {
            var tail = AttributedString(buffer)
            if inMatch { tail.inlinePresentationIntent = .stronglyEmphasized } // unbalanced marker: still bold
            out += tail
        }
        return out
    }
}
```

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

Ranking lists from the three layers are combined with reciprocal-rank fusion. Each layer contributes `weight × 1 / (k + rank)` with `k = 60` (the usual RRF constant) for every notification it returned; scores are summed per notification and the list is sorted descending. Weights are the PasteShelf values: **FTS 0.4, semantic 0.5, fuzzy 0.3**. Rank-based fusion is what lets a bm25 score (negative, unbounded) and a cosine (0…1) and a Levenshtein similarity (0…1) be merged without hand-tuned normalisers.

```swift
// Packages/BackglanceSearch/Sources/BackglanceSearch/HybridSearch.swift
import Foundation
import GRDB
import BackglanceCore

public struct SearchHit: Sendable, Equatable, Identifiable {
    public enum Source: String, Sendable { case fts, fuzzy, semantic }
    public let notificationID: Int64
    public let score: Double
    public let sources: Set<Source>
    public let snippet: String?
    public var id: Int64 { notificationID }
}

public struct SearchOptions: Sendable {
    public var semanticEnabled: Bool
    public var limit: Int
    public init(semanticEnabled: Bool, limit: Int = 100) {
        self.semanticEnabled = semanticEnabled
        self.limit = limit
    }
}

public actor HybridSearch {
    public enum Limits {
        public static let fuzzyCandidates = 5_000
        public static let fuzzyTriggerBelow = 5
        public static let semanticMinWords = 3
        public static let rrfK = 60.0
        public static let weightFTS = 0.4, weightSemantic = 0.5, weightFuzzy = 0.3
    }

    private let archive: Archive
    private let fts: FTSIndex
    private let fuzzy: FuzzyMatcher
    private let semantic: SemanticIndex
    private let apps: AppResolver

    public init(archive: Archive, semantic: SemanticIndex) {
        self.archive = archive
        self.fts = FTSIndex(archive: archive)
        self.fuzzy = FuzzyMatcher()
        self.semantic = semantic
        self.apps = AppResolver(archive: archive)
    }

    public func search(_ q: SearchQuery, options: SearchOptions) async throws -> [SearchHit] {
        if q.isEmpty { return [] }
        let appIDs = try await apps.resolve(q.appTerms)
        if !q.appTerms.isEmpty && appIDs.isEmpty { return [] }   // "from:xyz" matched nothing
        try Task.checkCancellation()

        // 1. FTS (or the negation-only / filter-only path)
        let ftsHits: [FTSHit]
        if q.matchExpression != nil {
            ftsHits = try await fts.search(q, appIDs: appIDs)
        } else {
            ftsHits = try await filterOnly(q, appIDs: appIDs)
        }
        try Task.checkCancellation()

        // 2. Fuzzy, only when FTS came back thin and there is something to fuzz.
        async let fuzzyHits: [FuzzyMatcher.Match] = {
            guard ftsHits.count < Limits.fuzzyTriggerBelow,
                  let term = q.freeTerms.last, term.count >= 3 else { return [] }
            let candidates = try await self.fuzzyCandidates(q, appIDs: appIDs)
            return self.fuzzy.matches(query: term, in: candidates)
        }()

        // 3. Semantic, only when enabled, available and the free text is a sentence-ish thing.
        async let semanticHits: [SemanticHit] = {
            guard options.semanticEnabled, await self.semantic.isAvailable,
                  q.freeTerms.count >= Limits.semanticMinWords else { return [] }
            do {
                let vector = try await self.semantic.embed(q.freeTerms.joined(separator: " "))
                return try await self.semantic.search(queryVector: vector, appIDs: appIDs,
                                                      after: q.after, before: q.before)
            } catch let error as SemanticIndex.SemanticError {
                Logger.search.notice("Semantic layer skipped: \(error.localizedDescription, privacy: .public)")
                return []                                     // degrade, never fail the whole search
            }
        }()

        let (fz, sm) = try await (fuzzyHits, semanticHits)
        try Task.checkCancellation()

        var merged = fuse(fts: ftsHits, fuzzy: fz, semantic: sm)
        if q.flags.contains(.vip) { merged = try await applyVIPFilter(merged) }
        return Array(merged.prefix(options.limit))
    }

    // MARK: - Fusion

    func fuse(fts: [FTSHit], fuzzy: [FuzzyMatcher.Match], semantic: [SemanticHit]) -> [SearchHit] {
        struct Acc { var score = 0.0; var sources = Set<SearchHit.Source>(); var snippet: String? }
        var acc: [Int64: Acc] = [:]
        func add(_ id: Int64, rank: Int, weight: Double, source: SearchHit.Source, snippet: String? = nil) {
            var a = acc[id] ?? Acc()
            a.score += weight * (1.0 / (Limits.rrfK + Double(rank)))
            a.sources.insert(source)
            if a.snippet == nil { a.snippet = snippet }
            acc[id] = a
        }
        for (i, h) in fts.enumerated()      { add(h.notificationID, rank: i + 1, weight: Limits.weightFTS, source: .fts, snippet: h.snippet) }
        for (i, h) in semantic.enumerated() { add(h.notificationID, rank: i + 1, weight: Limits.weightSemantic, source: .semantic) }
        for (i, h) in fuzzy.enumerated()    { add(h.id, rank: i + 1, weight: Limits.weightFuzzy, source: .fuzzy) }
        return acc.map { SearchHit(notificationID: $0.key, score: $0.value.score, sources: $0.value.sources, snippet: $0.value.snippet) }
                  .sorted { $0.score == $1.score ? $0.notificationID > $1.notificationID : $0.score > $1.score }
    }

    // MARK: - Helpers

    private func filterOnly(_ q: SearchQuery, appIDs: [Int64]) async throws -> [FTSHit] {
        try await archive.reader.read { db in
            var sql = "SELECT n.id AS id FROM notifications n WHERE n.is_deleted = 0"
            var args = StatementArguments()
            if !appIDs.isEmpty {
                sql += " AND n.app_id IN (" + appIDs.map { _ in "?" }.joined(separator: ",") + ")"
                args += StatementArguments(appIDs)
            }
            if let after = q.after  { sql += " AND n.delivered_at >= ?"; args += [after.timeIntervalSince1970] }
            if let before = q.before { sql += " AND n.delivered_at < ?";  args += [before.timeIntervalSince1970] }
            if q.flags.contains(.missed)  { sql += " AND (n.away_session_id IS NOT NULL OR n.presented = 0)" }
            if q.flags.contains(.pinned)  { sql += " AND n.is_pinned = 1" }
            if q.flags.contains(.hasLink) { sql += " AND n.deep_link IS NOT NULL" }
            if let neg = q.negatedOnlyExpression {
                sql += " AND n.id NOT IN (SELECT rowid FROM notifications_fts WHERE notifications_fts MATCH ?)"
                args += [neg]
            }
            sql += " ORDER BY n.delivered_at DESC LIMIT 200"
            return try Row.fetchAll(db, sql: sql, arguments: args).map {
                FTSHit(notificationID: $0["id"], score: 0, snippet: "")
            }
        }
    }

    private func fuzzyCandidates(_ q: SearchQuery, appIDs: [Int64]) async throws -> [FuzzyMatcher.Candidate] {
        try await archive.reader.read { db in
            var sql = "SELECT id, title, sender FROM notifications WHERE is_deleted = 0"
            var args = StatementArguments()
            if !appIDs.isEmpty {
                sql += " AND app_id IN (" + appIDs.map { _ in "?" }.joined(separator: ",") + ")"
                args += StatementArguments(appIDs)
            }
            if let after = q.after  { sql += " AND delivered_at >= ?"; args += [after.timeIntervalSince1970] }
            if let before = q.before { sql += " AND delivered_at < ?";  args += [before.timeIntervalSince1970] }
            sql += " ORDER BY delivered_at DESC LIMIT ?"
            args += [Limits.fuzzyCandidates]
            var out: [FuzzyMatcher.Candidate] = []
            for row in try Row.fetchAll(db, sql: sql, arguments: args) {
                let id: Int64 = row["id"]
                if let t: String = row["title"]  { out.append(.init(id: id, text: t)) }
                if let s: String = row["sender"] { out.append(.init(id: id, text: s)) }
            }
            return out
        }
    }

    private func applyVIPFilter(_ hits: [SearchHit]) async throws -> [SearchHit] {
        let ids = hits.map(\.notificationID)
        let vipIDs = try await archive.reader.read { db -> Set<Int64> in
            let rules = try Rule.filter(Column("kind") == "vip" && Column("is_enabled") == true).fetchAll(db)
            let rows = try ArchivedNotification.filter(ids.contains(Column("id"))).fetchAll(db)
            var out = Set<Int64>()
            for n in rows where RulesEngine.evaluate(n, rules: rules).matchedRuleIDs.isEmpty == false {
                out.insert(n.id!)
            }
            return out
        }
        return hits.filter { vipIDs.contains($0.notificationID) }
    }
}
```

`AppResolver.resolve` (not shown in full) does a case-insensitive match of each `from:` term against `apps.display_name`, then `apps.bundle_id`, then `bundle_id LIKE '%term%'`; if a term matches more than one app, all matching ids are included (`from:mail` returns Mail and Airmail; users disambiguate with the bundle id).

### Debounce and Cancellation

Search runs as you type. Two mechanisms keep it cheap: a 120 ms debounce so a fast typist triggers one query per pause rather than one per keystroke, and structured cancellation so a superseded query stops reading the archive.

```swift
// Packages/BackglanceUI/Sources/BackglanceUI/Search/SearchViewModel.swift
import Foundation
import Observation
import BackglanceSearch
import BackglanceCore

@MainActor @Observable
public final class SearchViewModel {
    public var text = "" { didSet { schedule() } }
    public private(set) var hits: [SearchHit] = []
    public private(set) var isSearching = false
    public private(set) var inlineError: String?

    private let search: HybridSearch
    private let parser = QueryParser()
    private let semanticEnabled: () -> Bool
    private var task: Task<Void, Never>?

    public init(search: HybridSearch, semanticEnabled: @escaping () -> Bool) {
        self.search = search
        self.semanticEnabled = semanticEnabled
    }

    private func schedule() {
        task?.cancel()
        let snapshot = text
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(120))    // debounce; throws on cancel
                let q = try parser.parse(snapshot)
                self.inlineError = nil
                if q.isEmpty { self.hits = []; self.isSearching = false; return }
                self.isSearching = true
                let result = try await search.search(q, options: .init(semanticEnabled: semanticEnabled()))
                try Task.checkCancellation()                       // a newer query may have won
                self.hits = result
                self.isSearching = false
            } catch is CancellationError {
                // superseded; the newer task owns the UI now
            } catch let error as QueryParser.ParseError {
                self.inlineError = error.localizedDescription
                self.isSearching = false
            } catch {
                self.inlineError = "Search failed. Try again or rebuild the index in Settings ▸ Advanced."
                self.isSearching = false
                Logger.ui.error("Search failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
```

The `SearchBar` view is thin: a `TextField` bound to `viewModel.text`, a `ProgressView` when `isSearching` (delayed by 200 ms so fast searches never flicker), the chip strip and the inline error `Text` in the secondary colour.

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
| Only negations (`-draft`) | `negatedOnlyExpression` path; `NOT IN` subquery over the FTS table |
| `from:` matches nothing | zero results plus a chip reading "No app matches 'xyz'"; no error dialog |
| `before:` / `after:` unreadable | `ParseError.badDate` shown inline; results from the previous good query stay on screen |
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

All search tests live in `Tests/BackglanceSearchTests` and run against `Archive(inMemory: true)`; nothing touches the user's archive or Apple's store.

**Query parser table tests** (Swift Testing, pure logic):

```swift
import Testing
@testable import BackglanceSearch

@Suite struct QueryParserTests {
    let parser = QueryParser()
    let ctx = QueryParser.Context(now: Date(timeIntervalSince1970: 1_755_432_000), // 2026-08-17 12:00 UTC
                                  calendar: { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }())

    @Test(arguments: [
        ("invoice",                    "(\"invoice\"*)"),
        ("invoice over",               "(\"invoice\" \"over\"*)"),
        ("\"invoice over\"",           "(\"invoice over\")"),
        ("invoice -draft",             "(\"invoice\"*) NOT \"draft\""),
        ("sender:Ayşe invoice",        "sender:\"Ayşe\"* AND (\"invoice\"*)"),
        ("re:invoice",                 "(\"re:invoice\"*)"),
        ("a AND (b",                   "(\"a\" \"AND\" \"(b\"*)"),
        ("say \"hi\" there",           "(\"say\" \"hi\" \"there\"*)"),
    ])
    func matchExpression(input: String, expected: String) throws {
        #expect(try parser.parse(input, context: ctx).matchExpression == expected)
    }

    @Test func relativeDates() throws {
        let q = try parser.parse("after:-7d before:today", context: ctx)
        #expect(q.after == Date(timeIntervalSince1970: 1_754_784_000))  // 2026-08-10 00:00 UTC
        #expect(q.before == Date(timeIntervalSince1970: 1_755_388_800)) // 2026-08-17 00:00 UTC
    }

    @Test func badDateThrows() {
        #expect(throws: QueryParser.ParseError.badDate(key: "before", value: "soonish")) {
            _ = try parser.parse("before:soonish", context: ctx)
        }
    }

    @Test func negationOnly() throws {
        let q = try parser.parse("-draft -\"work in progress\"", context: ctx)
        #expect(q.matchExpression == nil)
        #expect(q.negatedOnlyExpression == "\"draft\" OR \"work in progress\"")
    }
}
```

**FTS ranking tests** with a seeded archive (`SeededArchive.make(count: 1_000, seed: 42)` in the test support target generates deterministic titles/bodies/senders across 12 synthetic apps; OTP-like bodies use `String(format: "%06d", rng.next() % 1_000_000)` and are run through `OTPRedactor` so the archive never contains a raw code):

```swift
import XCTest
import GRDB
@testable import BackglanceSearch
@testable import BackglanceCore

final class FTSRankingTests: XCTestCase {
    var archive: Archive!
    var search: HybridSearch!

    override func setUp() async throws {
        archive = try SeededArchive.make(count: 1_000, seed: 42)
        search = HybridSearch(archive: archive, semantic: SemanticIndex(archive: archive))
    }

    func testTitleMatchOutranksBodyMatch() async throws {
        // Seed guarantees: id 17 has "Invoice" in title only, id 18 has "invoice" in body only.
        let hits = try await search.search(try QueryParser().parse("invoice"), options: .init(semanticEnabled: false))
        let ids = hits.map(\.notificationID)
        XCTAssertLessThan(ids.firstIndex(of: 17)!, ids.firstIndex(of: 18)!)
    }

    func testRedactedCodeIsFindableByPlaceholderOnly() async throws {
        let placeholderHits = try await search.search(try QueryParser().parse("code redacted"), options: .init(semanticEnabled: false))
        XCTAssertFalse(placeholderHits.isEmpty)
        let digitHits = try await search.search(try QueryParser().parse("123456"), options: .init(semanticEnabled: false))
        XCTAssertTrue(digitHits.isEmpty)   // digits never entered the archive
    }

    func testFuzzyRescuesTypo() async throws {
        let hits = try await search.search(try QueryParser().parse("invoce"), options: .init(semanticEnabled: false))
        XCTAssertTrue(hits.contains { $0.sources.contains(.fuzzy) })
    }

    func testFTSLatencyAt100k() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BG_PERF"] == "1", "perf tests opt-in")
        let big = try SeededArchive.make(count: 100_000, seed: 7)
        let s = HybridSearch(archive: big, semantic: SemanticIndex(archive: big))
        let q = try QueryParser().parse("from:slack after:-7d invoice")
        measure(metrics: [XCTClockMetric()]) {
            let exp = expectation(description: "search")
            Task { _ = try await s.search(q, options: .init(semanticEnabled: false)); exp.fulfill() }
            wait(for: [exp], timeout: 5)
        }
    }
}
```

**Semantic tests** skip cleanly where the model is missing:

```swift
final class SemanticIndexTests: XCTestCase {
    func testSentenceQueryFindsParaphrase() async throws {
        let index = SemanticIndex(archive: try SeededArchive.make(count: 200, seed: 3))
        try XCTSkipUnless(await index.isAvailable, "NLEmbedding English sentence model not available on this runner")
        let v = try await index.embed("the message about the invoice being paid")
        let hits = try await index.search(queryVector: v, appIDs: [], after: nil, before: nil)
        XCTAssertTrue(hits.contains { $0.notificationID == 42 })   // seed 3: id 42 = "Your invoice #2231 has been settled"
    }
}
```

**Trigger tests** insert, update the body, soft-delete, hard-delete a row and assert `SELECT COUNT(*) FROM notifications_fts WHERE notifications_fts MATCH ?` at each step. **Cancellation tests** start a search on the 100k archive, cancel after 5 ms and assert the task finishes with `CancellationError` within 50 ms. CI runs the whole target on `macos-14`, `macos-15`, `macos-26` ([CI_CD.md](../deployment/CI_CD.md)); the perf test runs only on `macos-26` with `BG_PERF=1`.

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
