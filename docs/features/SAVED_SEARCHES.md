# Saved Searches & Smart Folders

Last Updated: 2026-08-18

> ℹ️ **Status:** Planned for v1.x — not in v1.0.

This document describes saved searches — a named query such as "all CI failures this week" that lives in the sidebar as a smart folder with a live count, can be pinned to the popover as a chip, and reuses the search query language from [SEARCH.md](./SEARCH.md). It also covers regex rules, which extend the v1.0 rules engine with `kind = 'regex'` so a saved search or a triage rule can match on a pattern instead of a keyword.

## Table of Contents

- [Feature Overview](#feature-overview)
- [Architecture](#architecture)
- [Archive Tables Involved](#archive-tables-involved)
- [Query Language Reuse](#query-language-reuse)
- [Regex Rules](#regex-rules)
- [Examples](#examples)
- [UI Components](#ui-components)
- [Business Logic](#business-logic)
- [Export and Import](#export-and-import)
- [Edge Cases and Error Handling](#edge-cases-and-error-handling)
- [Testing Approach](#testing-approach)
- [Related Documentation](#related-documentation)

## Feature Overview

| Capability | Detail |
|---|---|
| Save the current search | "Save Search…" button in the search bar; name + optional smart folder toggle |
| Smart Folders | Sidebar section in the full timeline window; each folder is a saved search with `is_smart_folder = 1` and a live count |
| Pin to popover | Up to 5 saved searches shown as chips under the popover search field; tapping applies the query |
| Live counts | `ValueObservation` on the archive re-runs the count when notifications change |
| Relative dates | `after:-7d`, `before:-1h`, `after:today` resolved at run time, so "this week" stays this week |
| Regex rules | `rules.kind = 'regex'` with `match_field`; used both by the rules engine and by `regex:` in queries |
| Manage | Rename, edit query, reorder (drag), delete; export/import as JSON alongside rules |

A saved search is just a stored query string. It never stores results, so retention and deletion apply as usual.

## Architecture

```
  Search bar ── "Save Search…" ──▶ SavedSearchEditor (name, query, smart folder?)
                                          │
                                          ▼
                                   SavedSearchStore (BackglanceCore)
                                     ├ CRUD on `saved_searches`
                                     ├ validate(query) via QueryParser
                                     └ counts(): ValueObservation ── Archive
                                          │
             ┌────────────────────────────┼──────────────────────────────┐
             ▼                            ▼                              ▼
   Sidebar "Smart Folders"        Popover chips (≤ 5 pinned)     Settings ▸ Searches
   name · live count              tap ▶ apply query              reorder / export / import
             │
             ▼
   HybridSearch.search(QueryParser.parse(query, now: Date()))   (BackglanceSearch)
```

Counting and searching share `QueryParser`, so a query that is valid in the search bar is valid as a saved search, and vice versa.

## Archive Tables Involved

```sql
CREATE TABLE saved_searches (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  query TEXT NOT NULL,                       -- raw query language string
  is_smart_folder INTEGER NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at REAL NOT NULL
);
```

Migration `v2_saved_searches`. Pinning to the popover is a `UserDefaults` array of ids (`savedSearches.pinnedIDs`) rather than a column, because it is a per-Mac display preference and should not travel with a JSON export or CloudKit sync.

Regex rules reuse the existing `rules` table (`kind = 'regex'`, `pattern` = regex source, `match_field` ∈ `any|title|body|sender|app`). No new columns.

```swift
import GRDB

public struct SavedSearch: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "saved_searches"
    public var id: Int64?
    public var name: String
    public var query: String
    public var isSmartFolder: Bool
    public var sortOrder: Int
    public var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, query, isSmartFolder = "is_smart_folder",
             sortOrder = "sort_order", createdAt = "created_at"
    }
}
```

## Query Language Reuse

Saved searches store the same string a user types in the search bar (grammar in [SEARCH.md](./SEARCH.md)):

```
from:github sender:"GitHub Actions" failed after:-7d
```

| Token | Meaning |
|---|---|
| `from:<bundle-or-name>` | app filter (bundle id or display-name prefix) |
| `sender:"..."` | exact sender |
| `after:-7d` / `before:-1h` / `after:today` / `after:2026-08-01` | **relative** dates are resolved against `now` at run time |
| `is:unread`, `is:pinned`, `has:link` | flags |
| `regex:/pattern/i` | inline regex on `title`, `body`, `sender` (see below) |
| bare words | FTS5 MATCH (prefix, diacritics-insensitive) |

`QueryParser.parse(_:now:)` takes an explicit `now` so counts and tests are deterministic. A saved search is re-parsed every time it runs; nothing about "-7d" is baked in at save time.

## Regex Rules

v1.0 rules match keywords, senders and bundle ids ([RULES.md](./RULES.md)). v1.x adds `kind = 'regex'`. The engine compiles each pattern once with Swift `Regex` and evaluates it under a **50 ms timeout** per notification, so a pathological pattern can slow a row down but never hang the timeline.

```swift
import Foundation

public enum RegexRuleError: Error, Equatable {
    case invalidPattern(String)
    case timedOut(ruleID: Int64)
}

public struct CompiledRegexRule: Sendable {
    public let ruleID: Int64
    public let matchField: String
    private let regex: Regex<AnyRegexOutput>

    public init(rule: Rule) throws {
        guard rule.kind == "regex" else { throw RegexRuleError.invalidPattern("kind must be regex") }
        do {
            regex = try Regex(rule.pattern).ignoresCase()
        } catch {
            throw RegexRuleError.invalidPattern(error.localizedDescription)
        }
        ruleID = rule.id ?? 0
        matchField = rule.matchField
    }

    /// Returns true on match, false on no match; throws on timeout so the caller can disable the rule.
    public func matches(_ n: ArchivedNotification, timeout: Duration = .milliseconds(50)) async throws -> Bool {
        let haystacks: [String] = switch matchField {
        case "title":  [n.title ?? ""]
        case "body":   [n.body ?? ""]
        case "sender": [n.sender ?? ""]
        case "app":    [n.bundleID]
        default:       [n.title, n.subtitle, n.body, n.sender].compactMap { $0 }
        }
        let regex = self.regex
        let work = Task.detached(priority: .userInitiated) {
            haystacks.contains { $0.firstMatch(of: regex) != nil }
        }
        let timer = Task { try await Task.sleep(for: timeout); work.cancel() }
        defer { timer.cancel() }
        let result = await work.value
        if work.isCancelled { throw RegexRuleError.timedOut(ruleID: ruleID) }
        return result
    }
}
```

`Regex` matching is not itself cancellable mid-search, so the timeout works by racing: if the timer wins, the detached task is marked cancelled and the result is discarded; `RulesEngine` then flags the rule as `is_enabled = 0` with a note in the rules list ("Disabled: pattern too slow"). Patterns are validated in the editor before saving; a pattern that fails to compile shows the error inline.

> ⚠️ **Warning:** Regex rules, like every rule, are visual triage only. They highlight, pin or mute rows in Backglance; they do not change what macOS delivers.

## Examples

| Name | Query | Notes |
|---|---|---|
| CI failures this week | `from:github sender:"GitHub Actions" failed after:-7d` | smart folder, pinned |
| Invoices | `regex:/invoice|receipt|fatura/i has:link after:-30d` | any app |
| Deliveries | `from:mail regex:/(out for|delivered|shipment)/i after:-14d` | |
| 2FA-related | `is:unread from:messages "[code redacted]"` | shows only redacted placeholders — the codes themselves were never stored (see [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md)) |
| Unread from people | `from:messages is:unread after:today` | |

The 2FA example exists to make a point: a saved search cannot leak an OTP because the archive never contained one.

## UI Components

- **`SmartFoldersSection`** (BackglanceUI, sidebar of the full window): `List` of saved searches with `is_smart_folder = 1`, name + trailing count badge, drag to reorder, context menu (Rename / Edit Query / Unpin / Delete).
- **`SavedSearchChips`** (popover): horizontal `ScrollView` of pinned searches under the search field; a chip shows name and count; long-press → "Unpin".
- **`SavedSearchEditor`** sheet: name field, query field with live validation (`QueryParser` errors shown under the field), "Show as Smart Folder" and "Pin to popover" toggles, a preview count.
- **Settings ▸ Searches:** full table, Export… / Import… buttons.

```swift
import SwiftUI
import GRDB
import BackglanceCore

struct SmartFoldersSection: View {
    @State private var folders: [SavedSearch] = []
    @State private var counts: [Int64: Int] = [:]
    @State private var loadError: String?
    let store: SavedSearchStore

    var body: some View {
        Section("Smart Folders") {
            if let loadError { Text(loadError).foregroundStyle(.secondary) }
            ForEach(folders) { folder in
                NavigationLink(value: folder) {
                    LabeledContent(folder.name) {
                        Text("\(counts[folder.id ?? 0, default: 0])")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .onMove { from, to in Task { try? await store.move(fromOffsets: from, toOffset: to) } }
        }
        .task {
            do {
                for try await snapshot in store.observeFoldersWithCounts() {
                    folders = snapshot.map(\.search)
                    counts = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.search.id ?? 0, $0.count) })
                }
            } catch {
                loadError = "Smart folders unavailable: \(error.localizedDescription)"
            }
        }
    }
}
```

## Business Logic

```swift
import Foundation
import GRDB
import BackglanceSearch

public enum SavedSearchError: Error, Equatable {
    case emptyName
    case invalidQuery(String)
    case notFound(Int64)
}

public struct SavedSearchSnapshot: Sendable { public let search: SavedSearch; public let count: Int }

public actor SavedSearchStore {
    private let archive: Archive
    private let parser: QueryParser

    public init(archive: Archive = .shared, parser: QueryParser = QueryParser()) {
        self.archive = archive
        self.parser = parser
    }

    @discardableResult
    public func create(name: String, query: String, smartFolder: Bool) async throws -> SavedSearch {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw SavedSearchError.emptyName }
        do {
            _ = try parser.parse(query, now: Date())          // validate before writing
        } catch {
            throw SavedSearchError.invalidQuery(error.localizedDescription)
        }
        return try await archive.pool.write { db in
            let nextOrder = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM saved_searches")) ?? 0
            let s = SavedSearch(id: nil, name: trimmed, query: query, isSmartFolder: smartFolder,
                                sortOrder: nextOrder, createdAt: Date())
            return try s.inserted(db)
        }
    }

    public func rename(_ id: Int64, to name: String) async throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw SavedSearchError.emptyName }
        try await archive.pool.write { db in
            guard var s = try SavedSearch.fetchOne(db, key: id) else { throw SavedSearchError.notFound(id) }
            s.name = name
            try s.update(db)
        }
    }

    public func delete(_ id: Int64) async throws {
        _ = try await archive.pool.write { db in try SavedSearch.deleteOne(db, key: id) }
    }

    public func move(fromOffsets: IndexSet, toOffset: Int) async throws {
        try await archive.pool.write { db in
            var all = try SavedSearch.order(Column("sort_order")).fetchAll(db)
            all.move(fromOffsets: fromOffsets, toOffset: toOffset)
            for (i, var s) in all.enumerated() { s.sortOrder = i; try s.update(db) }
        }
    }

    /// Live folder list with counts. Re-emits when saved_searches or notifications change.
    public nonisolated func observeFoldersWithCounts() -> AsyncThrowingStream<[SavedSearchSnapshot], Error> {
        let parser = self.parser
        let observation = ValueObservation.tracking { db -> [SavedSearchSnapshot] in
            let folders = try SavedSearch.filter(Column("is_smart_folder") == true)
                .order(Column("sort_order")).fetchAll(db)
            return try folders.map { folder in
                let plan = try parser.parse(folder.query, now: Date())
                let count = try Int.fetchOne(db, sql: plan.countSQL, arguments: plan.arguments) ?? 0
                return SavedSearchSnapshot(search: folder, count: count)
            }
        }
        return AsyncThrowingStream { continuation in
            let cancellable = observation.start(in: archive.pool, scheduling: .async(onQueue: .main),
                                                onError: { continuation.finish(throwing: $0) },
                                                onChange: { continuation.yield($0) })
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }
}
```

`QueryPlan.countSQL` is the same `SELECT COUNT(*)` the search engine uses for its result count; regex tokens are applied as a post-filter, so a `regex:` folder count is computed by streaming ids through `CompiledRegexRule` (bounded to the query's date window; the sidebar shows "≈" when the window is open-ended and the count is capped at 1 000).

## Export and Import

Settings ▸ Searches ▸ Export writes `backglance-searches.json`; the same file format is used by Rules export ([RULES.md](./RULES.md)) so both can be shared in one file.

```json
{
  "format": "backglance.searches",
  "version": 1,
  "savedSearches": [
    { "name": "CI failures this week",
      "query": "from:github sender:\"GitHub Actions\" failed after:-7d",
      "isSmartFolder": true, "sortOrder": 0 }
  ],
  "rules": [
    { "kind": "regex", "pattern": "invoice|receipt|fatura", "matchField": "any",
      "appBundleID": null, "color": "amber", "priority": 0, "isEnabled": true }
  ]
}
```

Import validates every query and every regex before writing anything; on the first failure it reports the offending entry and imports nothing (all-or-nothing in one transaction). Duplicates by exact `name` are skipped with a summary ("3 imported, 1 skipped").

## Edge Cases and Error Handling

| Case | Behavior |
|---|---|
| Invalid query typed in editor | Save disabled; parser error shown under the field. Stored queries are always re-validated on load; a query that stops parsing after an upgrade shows "Needs attention" in the sidebar with an Edit button. |
| Slow regex | 50 ms timeout per notification; rule auto-disabled with a visible reason; folder count shows "—". |
| Catastrophic pattern like `(a+)+$` | Same path; the editor also runs a 200 ms compile-and-probe against a 2 KB synthetic string before allowing save. |
| App referenced by `from:` no longer installed / no rows | Query still runs; count 0. Bundle ids resolve against `apps.bundle_id`, not the file system. |
| App excluded after saving | Folder count drops to 0 as rows are pruned; no special handling. |
| More than 5 pinned | Editor toggle disabled with "Unpin another search first". |
| Rename to empty | `SavedSearchError.emptyName`. |
| Deleting a folder while it is selected | Sidebar selection falls back to "All". |
| Import file from newer version | `version > 1` rejected with a clear message. |
| Panic wipe | Saved searches are part of the archive and are wiped too (documented in [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md)). |

## Testing Approach

- **`SavedSearchStoreTests`** (`BackglanceCoreTests`): create/rename/delete/move against `Archive(inMemory: true)`; assert `sort_order` is contiguous after `move`.
- **Relative dates:** parse `after:-7d` with two different injected `now` values and assert the resulting bound shifts.
- **Live counts:** insert three matching notifications, start `observeFoldersWithCounts()`, insert a fourth, assert the stream emits `4`; delete one, assert `3`.
- **Regex:** table tests for `CompiledRegexRule` — match by field, invalid pattern → `invalidPattern`, and a deliberately slow pattern under a 5 ms test timeout → `timedOut`.
- **Import/export round-trip:** export → import into a fresh archive → equal set of searches and rules; a corrupted entry → nothing imported.
- **Redaction invariant:** the "2FA-related" example query over a fixture containing redacted rows returns rows whose body equals `[code redacted]` — no digits.
- **UI:** XCUITest: save a search from the search bar, see it in Smart Folders with the expected count, pin it, see the chip in the popover.

## Related Documentation

- [SEARCH.md](./SEARCH.md) — query grammar, `QueryParser`, `HybridSearch`
- [RULES.md](./RULES.md) — v1.0 rules; `kind = 'regex'` extension and shared JSON export
- [TIMELINE.md](./TIMELINE.md) — sidebar and popover layout
- [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md) — redaction, exclusion, wipe
- [EXPORT_AUTOMATION.md](./EXPORT_AUTOMATION.md) — `backglance://search?q=` can open a saved query
- [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md) — `saved_searches`, `rules`, migration `v2_saved_searches`
- [API_DOCUMENTATION.md](../api/API_DOCUMENTATION.md) — `SavedSearchStore`, `CompiledRegexRule`
- [PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md) — count query budgets
- [TESTING.md](../testing/TESTING.md)
- [ROADMAP.md](../reference/ROADMAP.md)
