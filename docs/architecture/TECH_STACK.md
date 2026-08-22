# Backglance Tech Stack

Last Updated: 2026-08-18

This document explains what Backglance is built with and, more importantly, why. Every choice below was made for a small, native, privacy-first macOS menu bar utility that a solo developer has to ship in weeks and keep working across macOS releases. Where a choice was between two reasonable options (GRDB vs Core Data, Sparkle vs the Mac App Store, native vs Electron) the trade-offs are written down so nobody has to re-derive them. It also carries the version compatibility matrix, the dependency list with `Package.swift` excerpts, and the performance considerations that follow from the stack.

## Table of Contents

- [Stack at a Glance](#stack-at-a-glance)
- [Language and UI: Swift, SwiftUI + AppKit Hybrid](#language-and-ui-swift-swiftui--appkit-hybrid)
  - [Why a hybrid, not pure SwiftUI](#why-a-hybrid-not-pure-swiftui)
  - [Where the seam is](#where-the-seam-is)
- [Persistence: GRDB.swift over SQLite](#persistence-grdbswift-over-sqlite)
  - [Why not raw SQLite (sqlite3 C API)](#why-not-raw-sqlite-sqlite3-c-api)
  - [Why not Core Data](#why-not-core-data)
  - [Why not SwiftData](#why-not-swiftdata)
  - [What GRDB gives Backglance](#what-grdb-gives-backglance)
- [Full-Text Search: SQLite FTS5](#full-text-search-sqlite-fts5)
- [Semantic and Fuzzy Search: Ported from PasteShelf](#semantic-and-fuzzy-search-ported-from-pasteshelf)
  - [The engine that is ported](#the-engine-that-is-ported)
  - [What changed in the port: Core Data → GRDB](#what-changed-in-the-port-core-data--grdb)
  - [Fuzzy matching](#fuzzy-matching)
- [Distribution: Sparkle 2 + GitHub Releases + Homebrew Cask](#distribution-sparkle-2--github-releases--homebrew-cask)
  - [Why not the Mac App Store](#why-not-the-mac-app-store)
  - [Why Sparkle 2](#why-sparkle-2)
- [Why Not Electron or Tauri](#why-not-electron-or-tauri)
- [Version Compatibility Matrix](#version-compatibility-matrix)
- [Dependencies](#dependencies)
  - [Package.swift excerpts](#packageswift-excerpts)
  - [App target dependencies](#app-target-dependencies)
- [Performance Considerations](#performance-considerations)
- [Learning Resources](#learning-resources)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Stack at a Glance

| Layer | Choice | One-line reason |
|---|---|---|
| Language | Swift 5.10+ (language mode 5, Swift 6 toolchain warning-clean as a goal; manifests are tools-version 6.0) | Native, first-class on macOS, `Sendable`/actors for the capture pipeline |
| UI | SwiftUI for timeline / settings / onboarding / digest; AppKit for `NSStatusItem`, `NSPopover`, global hotkey, windows | SwiftUI is productive for content views; AppKit is still the only reliable way to own a menu bar item |
| Persistence | GRDB.swift 7.x over the system SQLite | Real SQL, FTS5, migrations, `ValueObservation`, no ORM opacity |
| Full-text search | SQLite FTS5 (external-content table) | Ships in the OS, sub-50 ms at 100k rows, prefix indexes, BM25 |
| Semantic search | Apple NaturalLanguage `NLEmbedding.sentenceEmbedding(for: .english)`, cosine top-K, brute force | On-device, no model download, no network; engine ported from PasteShelf |
| Fuzzy search | Levenshtein `FuzzyMatcher` (threshold 0.6) over FTS candidates | Typos in searches are common; ported from PasteShelf |
| Updates | Sparkle 2.7.x, EdDSA-signed appcast on GitHub Pages | The only network access in the app, and the user can turn it off |
| Distribution | GitHub Releases (Developer ID signed + notarized DMG) + Homebrew cask | FDA is incompatible with the App Sandbox, so the Mac App Store is not an option |
| Launch at login | `SMAppService.mainApp` | Modern API, no helper bundle |
| Hotkey | Carbon `RegisterEventHotKey` (`HotKeyCenter`), default ⌃⌥N | Still the dependable global-hotkey API on macOS |
| Logging | `os.Logger` + local rotating file (5 × 2 MB) | Unified logging for development, a plain file for user bug reports |
| Testing | XCTest, Swift Testing for new pure-logic tests, XCUITest for onboarding | Standard tooling, runs on GitHub-hosted runners |
| CI | GitHub Actions on `macos-14`, `macos-15`, `macos-26` | Free for open source; one runner per supported macOS major |

## Language and UI: Swift, SwiftUI + AppKit Hybrid

### Why a hybrid, not pure SwiftUI

Backglance's UI is a popover attached to a status item, one optional window, a settings window, an onboarding flow and a digest banner. SwiftUI is the right tool for the content of all of those: lazy timelines, forms, animations, dark/light adaptation, accessibility for free. But the *shell* around them still belongs to AppKit:

- `NSStatusItem` + `NSPopover` give exact control over positioning, transient behavior (close on click-outside), and the icon state (running / paused / degraded). SwiftUI's `MenuBarExtra(style: .window)` exists since macOS 13, but it does not let the app decide when the popover closes, does not expose the status button for badge drawing, and behaves differently across macOS 14–26 in ways that would cost more to work around than to avoid.
- A global hotkey (⌃⌥N) is a Carbon `RegisterEventHotKey` call. There is no SwiftUI equivalent.
- `LSUIElement = YES` apps have no Dock icon and no main window; window lifecycle for the timeline and settings windows is easier to reason about with `NSWindowController` than with `WindowGroup` scenes that assume a document-style app.
- Launch at login (`SMAppService`), the URL scheme handler and Sparkle all want an `NSApplicationDelegate`.

So the app target is an AppKit application (`AppDelegate.swift`, `StatusItemController.swift`, `HotKeyCenter.swift`) that hosts SwiftUI through `NSHostingController`. All views live in the `BackglanceUI` package and never import AppKit except through tiny `NSViewRepresentable` shims. The same `TimelineView` renders inside the popover, inside the timeline window and (v1.x) inside a WidgetKit timeline.

### Where the seam is

```
Backglance (app target, AppKit)
  AppDelegate ──▶ StatusItemController ──▶ NSPopover ──▶ NSHostingController(rootView: PopoverRoot())
                                                                          │
                                                                          ▼
                                                     BackglanceUI (SwiftUI package)
                                                       TimelineView · DigestView · SearchBar · SettingsViews
                                                                          │  @MainActor @Observable view models
                                                                          ▼
                                                     BackglanceCore / BackglanceSearch (GRDB ValueObservation)
```

Language mode is Swift 5 for v1.0 so contributors on Xcode 16.2 are not blocked by strict-concurrency errors in third-party code, but the packages compile warning-clean under the Swift 6 toolchain with `-strict-concurrency=complete`, and `CaptureEngine` is an actor from day one. Moving to language mode 6 is a v1.x housekeeping item, not a rewrite.

> 💡 **Tip:** If a SwiftUI behavior differs between macOS 14 and 26 (it will), fix it in `BackglanceUI` with `if #available` rather than pushing AppKit into the views. The AppKit shell is intentionally small (about six files) so it stays auditable.

## Persistence: GRDB.swift over SQLite

The archive is a single SQLite file at `~/Library/Application Support/Backglance/archive.sqlite` (WAL mode, `0600`, directory `0700`). Backglance also reads Apple's system store, which is itself SQLite. Choosing SQLite as the storage engine was never in question; the choice was how to talk to it.

### Why not raw SQLite (sqlite3 C API)

Talking to `sqlite3` directly from Swift works, and PasteShelf's fixture tooling does exactly that in a few places. For the archive it would mean hand-writing statement caching, row decoding, transaction helpers, a migration runner and change observation. Every one of those is a place to leak a statement or forget a `finalize`. GRDB is a thin, well-tested layer over the same C API with no hidden behavior: the SQL you write is the SQL that runs, and `EXPLAIN QUERY PLAN` still means something.

### Why not Core Data

Core Data was the obvious candidate because PasteShelf uses it, and its search engine was written against it. It was rejected for Backglance for four concrete reasons:

| Concern | Core Data | GRDB |
|---|---|---|
| FTS5 | Not exposed; needs a side table maintained by hand, or a second SQLite connection to the same file (unsupported) | First-class: `CREATE VIRTUAL TABLE ... USING fts5(...)` in a migration, `bm25()` in queries |
| Read-only, immutable, snapshot connections (for the system store) | Not the right tool; Core Data assumes it owns the file | `Configuration.readonly = true`, `?immutable=1` in the URI, `DatabaseQueue` per snapshot |
| Schema visibility | Generated tables (`ZNOTIFICATION`, `Z_PK`), migrations via mapping models | The DDL in [DATABASE_SCHEMA.md](./DATABASE_SCHEMA.md) is literally what is on disk; migrations are named Swift closures |
| Concurrency | `NSManagedObjectContext` per thread, faulting, merge policies | `DatabasePool` (WAL, concurrent readers, one writer), `Sendable` records, `async` reads |

The privacy posture also matters here: a user or auditor can open `archive.sqlite` with the `sqlite3` CLI and see plainly named tables. That is worth something for an app that claims to keep notification content local.

### Why not SwiftData

SwiftData is a Core Data wrapper with a nicer surface, and its minimum for macOS is 14, which matches the deployment target. It shares Core Data's limitations above (no FTS5, no read-only foreign-file access) and, on macOS 14 specifically, is missing several APIs that arrived in 15 and 26 (`#Index`, `#Unique`, history tracking). Building an app whose deployment target is 14 on SwiftData means writing around those gaps for two years. It was not a close call.

### What GRDB gives Backglance

- **`DatabasePool` for the archive** — WAL mode, many concurrent readers, one serialized writer. The capture loop writes in batches; the UI reads through `ValueObservation`, which re-runs a query only when the tables it touched change.
- **`DatabaseQueue` (read-only) for store snapshots** — one queue per copied snapshot, opened with `readonly = true` and `immutable=1`, discarded after the batch. Apple's live file is never opened for write. See [ARCHITECTURE.md](./ARCHITECTURE.md#watch-strategy-poll--dispatchsource--snapshot).
- **`DatabaseMigrator`** — migrations `v1_initial`, `v1_fts`, `v2_embeddings`, `v3_match_keys`, then the v1.x ones (`v4_saved_searches`, `v5_snoozes`, `v6_sync_metadata`) in `ArchiveMigrations.swift`, with `eraseDatabaseOnSchemaChange = true` only in DEBUG.
- **Record protocols** — models are `Codable, FetchableRecord, PersistableRecord`; no code generation, no `.xcdatamodeld`.
- **System SQLite** — GRDB links the SQLite that ships with macOS (FTS5, JSON1 and R*Tree are all compiled in on macOS 14+), so there is no bundled SQLite to keep patched. The optional v1.x SQLCipher build (`GRDB.swift/SQLCipher`) swaps in an encrypted SQLite behind the same API.

A minimal example of the pattern used everywhere in `BackglanceCore`:

```swift
import Foundation
import GRDB

public struct AppRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "apps"

    public var id: Int64?
    public var bundleId: String
    public var displayName: String?
    public var retention: String          // 'inherit' | '24h' | '7d' | '30d' | 'forever' | 'never'
    public var isExcluded: Bool
    public var isMuted: Bool
    public var redactOtp: Bool
    public var firstSeenAt: UnixDate
    public var lastSeenAt: UnixDate
    public var notificationCount: Int

    // GRDB maps camelCase ↔ snake_case with this one line.
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// Success path: upsert an app row inside the writer.
func upsertApp(bundleId: String, in pool: DatabasePool) async throws -> AppRecord {
    try await pool.write { db in
        if var existing = try AppRecord.filter(Column("bundle_id") == bundleId).fetchOne(db) {
            existing.lastSeenAt = UnixDate(Date())
            existing.notificationCount += 1
            try existing.update(db)
            return existing
        }
        var fresh = AppRecord(id: nil, bundleId: bundleId, displayName: nil, retention: "inherit",
                              isExcluded: false, isMuted: false, redactOtp: false,
                              firstSeenAt: UnixDate(Date()), lastSeenAt: UnixDate(Date()),
                              notificationCount: 1)
        try fresh.insert(db)
        return fresh
    }
}

// Error path: callers see a typed GRDB error, never a crash.
func safeUpsert(bundleId: String, in pool: DatabasePool) async -> AppRecord? {
    do {
        return try await upsertApp(bundleId: bundleId, in: pool)
    } catch let error as DatabaseError where error.resultCode == .SQLITE_FULL {
        // Disk full: surface via ArchiveHealth, keep the app alive.
        return nil
    } catch {
        return nil
    }
}
```

`UnixDate` is a small `DatabaseValueConvertible` wrapper that stores dates as REAL Unix seconds, so range indexes on `delivered_at` behave predictably and the CLI shows plain numbers.

## Full-Text Search: SQLite FTS5

Users search their archive the way they search mail: a couple of words, sometimes an app name, sometimes a date. FTS5 covers that without any external dependency:

- **External-content table** `notifications_fts(title, subtitle, body, sender)` with `content='notifications'` — no duplicated text on disk; three triggers (`notifications_ai/_ad/_au`) keep it in sync.
- **Tokenizer** `unicode61 remove_diacritics 2 tokenchars '@.-'` — "Muller" and "Müller" match each other, and `alex@example.com` stays one token.
- **Prefix indexes** `prefix='2 3'` — typing "inv" already narrows to "invoice" without a full scan.
- **BM25 ranking** and `highlight()`/`snippet()` come built in.
- **Latency** — FTS p95 < 50 ms at 100k notifications on an M1, well inside the popover budget.

Alternatives considered: `LIKE '%term%'` (no ranking, full scan, wrong on Unicode), Spotlight/`CSSearchableIndex` (would export notification content to the system index, which is exactly what a privacy-first archive must not do), and a bundled Tantivy/Lucene port (megabytes of dependency for a menu bar app). FTS5 is the whole answer for the keyword half of search.

## Semantic and Fuzzy Search: Ported from PasteShelf

### The engine that is ported

PasteShelf (a clipboard manager by the same developer) already has a working on-device semantic search stack. Backglance ports the *engine*, not the storage:

| PasteShelf type | Backglance home | What it does |
|---|---|---|
| `EmbeddingManager` | `BackglanceSearch/SemanticIndex.swift` | Wraps `NLEmbedding.sentenceEmbedding(for: .english)`, produces 512-dim `[Float]` per text, batches work in the background |
| `VectorSimilarityCalculator` | `BackglanceSearch/VectorSimilarity.swift` | Cosine similarity, brute-force top-K over all stored vectors |
| `SemanticSearchEngine` | `BackglanceSearch/SemanticIndex.swift` (`query(_:limit:)`) | Embed the query, rank candidates |
| `HybridSearchEngine` | `BackglanceSearch/HybridSearch.swift` | Merge FTS (0.4), semantic (0.5), fuzzy (0.3) scores into one ranked list |
| `FuzzyMatcher` | `BackglanceSearch/FuzzyMatcher.swift` | Levenshtein similarity, threshold 0.6 |

Why `NLEmbedding` and not a bundled transformer model: it is on-device, needs no download, is already on every supported macOS, produces good-enough sentence vectors for short notification text (title + body is rarely more than 200 characters), and keeps the app's network guarantee intact. It is English-only for sentence embeddings, which is why semantic search is an opt-in setting rather than the default and why FTS5 (which is language-agnostic) remains the primary path.

The core of the similarity code, unchanged in spirit from PasteShelf, uses Accelerate so a 100k brute-force scan stays under the hybrid budget:

```swift
import Accelerate
import Foundation

public enum VectorSimilarity {
    /// Cosine similarity of two equal-length vectors. Returns 0 for degenerate input.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "dimension mismatch")
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &na, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }

    /// Brute-force top-K. `candidates` are (id, vector); K is small (≤ 200) in practice.
    public static func topK(query: [Float], candidates: [(Int64, [Float])], k: Int) -> [(id: Int64, score: Float)] {
        var scored = candidates.map { (id: $0.0, score: cosine(query, $0.1)) }
        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(k))
    }
}
```

### What changed in the port: Core Data → GRDB

PasteShelf keeps vectors as a transformable attribute on an `NSManagedObject` and rebuilds an in-memory index at launch. Backglance stores them in the `embeddings` table (`notification_id`, `model`, `dims`, `vector BLOB`, `created_at`) and reads them with GRDB:

```swift
import Foundation
import GRDB
import NaturalLanguage

public struct EmbeddingRow: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "embeddings"
    public var notificationId: Int64
    public var model: String       // "nl.sentence.en.v1" — bump when Apple's model changes results
    public var dims: Int           // 512
    public var vector: Data        // dims × Float32, little-endian
    public var createdAt: Double

    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var floats: [Float] {
        vector.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

public actor SemanticIndex {
    private let pool: DatabasePool
    private let embedding: NLEmbedding?

    public init(pool: DatabasePool) {
        self.pool = pool
        self.embedding = NLEmbedding.sentenceEmbedding(for: .english)   // nil if the asset is unavailable
    }

    /// Index up to `batchSize` notifications that have no embedding yet. Called from a background task.
    public func indexPending(batchSize: Int = 50) async throws -> Int {
        guard let embedding else { return 0 }
        let pending: [(Int64, String)] = try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT n.id, COALESCE(n.title,'') || ' ' || COALESCE(n.body,'') AS text
                FROM notifications n
                LEFT JOIN embeddings e ON e.notification_id = n.id
                WHERE e.notification_id IS NULL AND n.is_deleted = 0 AND n.redaction = 'none'
                ORDER BY n.id LIMIT ?
                """, arguments: [batchSize])
            .map { ($0["id"] as Int64, $0["text"] as String) }
        }
        var rows: [EmbeddingRow] = []
        for (id, text) in pending {
            guard let v = embedding.vector(for: text) else { continue }   // e.g. empty text
            let floats = v.map(Float.init)
            let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
            rows.append(EmbeddingRow(notificationId: id, model: "nl.sentence.en.v1", dims: floats.count,
                                     vector: data, createdAt: Date().timeIntervalSince1970))
        }
        try await pool.write { db in
            for row in rows { try row.save(db) }
        }
        return rows.count
    }
}
```

Two deliberate differences from PasteShelf: redacted notifications (`redaction = 'otp'`) are never embedded, and vectors are stored once and read in one query at search time rather than kept resident, which keeps idle memory under the 60 MB budget. The hybrid weights (FTS 0.4, semantic 0.5, fuzzy 0.3) were tuned in PasteShelf on clipboard text and kept as-is for v1.0; they are constants in `HybridSearch` and are the first thing to revisit if search quality feels off.

### Fuzzy matching

`FuzzyMatcher` computes Levenshtein similarity (`1 - distance / max(len)`) between the query terms and candidate tokens returned by FTS5 prefix queries, keeping matches at or above 0.6. It never scans the whole archive: FTS produces the candidates, fuzzy re-ranks them. That keeps hybrid p95 under 250 ms even when the semantic branch is on.

## Distribution: Sparkle 2 + GitHub Releases + Homebrew Cask

### Why not the Mac App Store

Backglance reads `~/Library/Group Containers/group.com.apple.usernoted/db2/db`. That path is outside any container Backglance could be granted, and reading it requires the user to grant **Full Disk Access** in System Settings. Full Disk Access is incompatible with the App Sandbox, and the App Sandbox is mandatory on the Mac App Store. There is no entitlement to request and no review argument to make: the app cannot do its one job inside the sandbox. So Backglance is distributed outside the store, Developer ID signed and notarized, and says so plainly in onboarding.

Not being on the store also removes the incentive to add an in-app purchase or a subscription; Backglance is GPL-3.0 and free, and the distribution channel matches that.

### Why Sparkle 2

- **It is the only network access in the app**, and it is a single toggle in Settings ▸ Updates. When it is off, Backglance makes no network requests at all. This is documented as a guarantee in [../features/PERMISSIONS_PRIVACY.md](../features/PERMISSIONS_PRIVACY.md).
- **EdDSA (ed25519) signatures** on every update, verified against `SUPublicEDKey` in `Info.plist`; the private key lives only in the release workflow secret `SPARKLE_PRIVATE_KEY`.
- **Appcast on GitHub Pages** (`https://backglance.github.io/backglance/appcast.xml`, moving to `https://backglance.app/appcast.xml` after the domain is confirmed) — no server to run.
- **Sparkle 2.x is a modern SPM package**, works with a non-sandboxed app without an XPC service, supports delta updates and, if ever needed, channels (`beta`) for macOS-beta adapter builds.

The Homebrew cask (`brew install --cask backglance/tap/backglance`) is a convenience for people who already live in the terminal; it downloads the same notarized DMG that GitHub Releases serves. `Scripts/bump_cask.sh` and `.github/workflows/cask-bump.yml` keep it current. Details are in [../deployment/DEPLOYMENT_GUIDE.md](../deployment/DEPLOYMENT_GUIDE.md) and [../deployment/PACKAGING_NOTARIZATION.md](../deployment/PACKAGING_NOTARIZATION.md).

## Why Not Electron or Tauri

The question comes up because a cross-platform shell would make a Windows or Linux port cheap. It would not, because there is nothing to port: the product exists only because macOS discards notification history, and it depends on a macOS-only database, Full Disk Access, `NSStatusItem`, `NLEmbedding` and `SMAppService`. Beyond that:

| Concern | Electron | Tauri | Native Swift |
|---|---|---|---|
| Idle memory (budget: < 60 MB RSS) | 150–300 MB with a hidden window | 40–80 MB (WebKit) | 25–40 MB measured in dev builds |
| Idle CPU (budget: < 0.1 %) | Chromium timers make this hard | Achievable | Achievable |
| Menu bar popover fidelity | Custom HTML, no native `NSPopover` | Custom HTML | Native |
| Access to `NLEmbedding`, `SMAppService`, Carbon hotkeys, `DistributedNotificationCenter` | Via native addons | Via Rust plugins + Objective-C bridging | Direct |
| Binary size | ~200 MB | ~10 MB | ~8 MB (with Sparkle) |
| Signing / notarization / Sparkle | Possible, more moving parts | Possible | Standard |

For a utility that lives in the menu bar all day, idle footprint is the product. Native Swift is the only option that meets the budgets without effort.

## Version Compatibility Matrix

| Component | Minimum | Recommended / documented against | Notes |
|---|---|---|---|
| Swift language | Language mode 5, pinned per target with `.swiftLanguageMode(.v5)` | Swift 6.2 toolchain (Xcode 26.x) | Warning-clean with `-strict-concurrency=complete`; language mode 6 planned for v1.x |
| Package manifests | `swift-tools-version: 6.0` | SwiftPM 6.0+ (Xcode 16+) | Not a language-mode change: 6.0 is the first tools-version that can express `BackglanceCoreTests` depending on `BackglanceTestSupport`, which depends back on `BackglanceCore`. Under 5.10 SwiftPM refused the manifest as a cycle and `swift build --package-path Packages/BackglanceCore` did not work at all. Every target pins `.swiftLanguageMode(.v5)` so the tools-version bump changes nothing else. |
| Xcode | 16.2 | 26.2 | GRDB 7 requires the Swift 6 compiler (Xcode 16+); Xcode 26 needed for macOS 26 SDK features and the `macos-26` runner |
| macOS SDK | 15.x (Xcode 16.2) | 26.x | Deployment target stays 14.0 regardless of SDK |
| macOS deployment target | 14.0 (Sonoma) | — | `SMAppService`, `@Observable`, `MenuBarExtra` fixes, SwiftData baseline all need 14 |
| macOS runtime | 14, 15, 26 supported; 27 beta best-effort | 26.5 (primary dev target) | See [OS_COMPATIBILITY_PLAYBOOK.md](./OS_COMPATIBILITY_PLAYBOOK.md) |
| GRDB.swift | 7.0.0 | latest 7.x | `from: "7.0.0"`; system SQLite; `GRDB.swift/SQLCipher` optional for v1.x |
| Sparkle | 2.7.0 | latest 2.7.x | `from: "2.7.0"`; EdDSA keys; macOS 10.13+ runtime so no constraint for us |
| System SQLite (macOS 14 / 15 / 26) | 3.43 / 3.46 / 3.49 (approximate) | — | FTS5, JSON1 present on all; `unicode61 remove_diacritics 2` since 3.27 |
| GitHub Actions runners | `macos-14` (Xcode 16.2 selected), `macos-15` (Xcode 16.2 selected), `macos-26` (Xcode 26.x) | — | `DEVELOPER_DIR` pinned per runner in `ci.yml`; matrix fails the build if any leg fails |
| Architectures | Universal 2 (arm64 + x86_64) | Apple silicon primary | Intel best-effort on 14/15/26; macOS 27 is Apple silicon only |

> ℹ️ **Info:** "Recommended" moves with each Xcode release. The minimum is bumped only when a dependency forces it, and always in a minor version with a CHANGELOG entry.

## Dependencies

Backglance has exactly two third-party dependencies at build time. Everything else is an Apple framework.

| Dependency | Version | Where | Purpose | License |
|---|---|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.x | `BackglanceCore`, `BackglanceCapture`, `BackglanceSearch` | SQLite access, migrations, FTS5, observation | MIT |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.7.x | `Backglance` app target only | Updates | MIT |

Apple frameworks used, per package:

| Package | Frameworks |
|---|---|
| `BackglanceCore` | Foundation, GRDB, CryptoKit (fingerprint hashing shared type), LocalAuthentication (panic wipe), EventKit (v1.x snooze export), UserNotifications (snooze reminders) |
| `BackglanceCapture` | Foundation, GRDB, CryptoKit, AppKit (`NSWorkspace` for icons and app URLs) |
| `BackglanceSearch` | Foundation, GRDB, NaturalLanguage, Accelerate |
| `BackglanceUI` | SwiftUI, AppKit (shims only), Combine |
| `Backglance` (app) | AppKit, ServiceManagement, Carbon (hotkey), Sparkle, OSLog |

### Package.swift excerpts

Each package under `Packages/` is a standalone SPM package so it can be built and tested with `swift build` / `swift test` without opening the Xcode project. Local dependencies use `.package(path:)`.

> ⚠️ **Why the test targets are reached through symlinks.** SwiftPM refuses a target whose path
> escapes the package root (`target 'X' in package 'y' is outside the package root`). The test sources
> still live at the repository root, in `Tests/`, because `Backglance.xctestplan`, `ci.yml` and
> `Scripts/verify_fixture.sh` all address them there. Each package therefore carries one symlink per
> test target — `Packages/BackglanceCore/Tests/BackglanceCoreTests -> ../../../Tests/BackglanceCoreTests`.
> Nothing is duplicated: there is exactly one copy of every test file, at the root.
>
> The fixtures are *not* bundled as resources. Every test bundle is built twice — once by SwiftPM and
> once by the Xcode test target the test plan runs — and `Bundle.module` exists only in the SwiftPM
> build, so a resource lookup would not compile in Xcode. Tests reach `Tests/Fixtures/` through
> `BackglanceTestSupport.Fixtures`, which derives the path from its own `#filePath`; the
> `SharedFixtures` symlink inside each test target is `exclude`d from the manifest so SwiftPM does not
> warn about it. See [TESTING.md](../testing/TESTING.md).

`Packages/BackglanceCore/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BackglanceCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BackglanceCore", targets: ["BackglanceCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "BackglanceCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),   // warning-clean under Swift 6 toolchain
            ]
        ),
        .testTarget(
            name: "BackglanceCoreTests",
            dependencies: ["BackglanceCore"],
            path: "Tests/BackglanceCoreTests"
        ),
    ]
)
```

`Packages/BackglanceCapture/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BackglanceCapture",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BackglanceCapture", targets: ["BackglanceCapture"]),
    ],
    dependencies: [
        .package(path: "../BackglanceCore"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "BackglanceCapture",
            dependencies: [
                "BackglanceCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [
                .copy("Resources/KnownFingerprints.json"),   // regenerated by Scripts/verify_fixture.sh
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "BackglanceCaptureTests",
            dependencies: ["BackglanceCapture"],
            path: "Tests/BackglanceCaptureTests",
            resources: [
                .copy("Fixtures/SystemStore"),   // macOS14/, macOS15/, macOS26/ — synthetic only
            ]
        ),
    ]
)
```

`Packages/BackglanceSearch/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BackglanceSearch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BackglanceSearch", targets: ["BackglanceSearch"]),
    ],
    dependencies: [
        .package(path: "../BackglanceCore"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "BackglanceSearch",
            dependencies: [
                "BackglanceCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            linkerSettings: [
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("Accelerate"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "BackglanceSearchTests",
            dependencies: ["BackglanceSearch"],
            path: "Tests/BackglanceSearchTests"
        ),
    ]
)
```

> ✅ **Do:** Keep `from: "7.0.0"` and `from: "2.7.0"` (not `exact:`) so security fixes in GRDB and Sparkle arrive with `swift package update`. `Package.resolved` is committed, so builds are reproducible until someone deliberately updates.

### App target dependencies

The Xcode project (`Backglance.xcodeproj`) adds Sparkle through the SPM tab, plus the four local packages. Nothing else. `Info.plist` carries `SUFeedURL`, `SUPublicEDKey`, `LSUIElement = YES` and the `backglance://` URL type; `Backglance.entitlements` contains no sandbox key.

```xml
<!-- Backglance/Info.plist (excerpt) -->
<key>SUFeedURL</key>
<string>https://backglance.github.io/backglance/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>REPLACE_WITH_BASE64_ED25519_PUBLIC_KEY</string>
<key>SUEnableInstallerLauncherService</key>
<false/>
<key>LSUIElement</key>
<true/>
```

## Performance Considerations

The stack was chosen with the budgets in [../deployment/PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md) in mind; the table records which stack choice carries each budget.

| Budget | Stack choice that carries it |
|---|---|
| Idle CPU < 0.1 % | `DispatchSource` on the store's `-wal` file instead of a tight poll; 15 s fallback poll (60 s in Low Power Mode); 500 ms debounce; no Chromium |
| Idle memory < 60 MB RSS | Native AppKit shell; SwiftUI views unloaded when the popover closes; embeddings read per query, not resident |
| Popover first paint < 100 ms | `NSPopover` with a pre-warmed `NSHostingController`; first page of 200 rows via one indexed query on `delivered_at DESC` |
| Timeline scroll 60 fps at 100k | `LazyVStack` + pagination of 200; `ValueObservation` diffing on the main actor; icons from the on-disk cache |
| FTS p95 < 50 ms | FTS5 external-content table with prefix indexes; `bm25()` ranking; query built by `QueryParser` so filters hit `idx_notifications_app_delivered` |
| Hybrid p95 < 250 ms | vDSP cosine over BLOB-stored vectors; brute-force top-K bounded by candidate set; fuzzy runs on FTS candidates only |
| Import 10k store records < 10 s | One read-only snapshot per batch; adapter `SELECT ... LIMIT 500`; single `DatabasePool.write` per batch with prepared statements |
| Archive ~1 KB/notification | Text columns only; attachments as metadata JSON, never bytes; icons in a separate cache directory |

Two stack-level trade-offs worth knowing:

- **Brute-force semantic search does not scale forever.** At 100k notifications a query scans 100k × 512 floats (~200 MB read per query if the vectors are cold). It fits the v1.0 budget because semantic search is opt-in and most archives are far smaller under a 30-day retention default. If it ever matters, the fix is an approximate index (HNSW via a small SQLite extension or an in-memory graph), not a change of engine.
- **`NLEmbedding` throughput** is roughly 300–800 sentences/s on Apple silicon and lower on Intel. Background batches of 50 keep the main actor idle and stay under the CPU budget when averaged; the indexer pauses on battery low-power.

## Learning Resources

Apple:

- Swift concurrency (actors, `Sendable`, strict concurrency): https://developer.apple.com/documentation/swift/concurrency
- SwiftUI on macOS: https://developer.apple.com/documentation/swiftui
- AppKit `NSStatusItem`: https://developer.apple.com/documentation/appkit/nsstatusitem
- AppKit `NSPopover`: https://developer.apple.com/documentation/appkit/nspopover
- `NSHostingController`: https://developer.apple.com/documentation/swiftui/nshostingcontroller
- `SMAppService` (launch at login): https://developer.apple.com/documentation/servicemanagement/smappservice
- Carbon `RegisterEventHotKey`: https://developer.apple.com/documentation/carbon/1433053-registereventhotkey
- NaturalLanguage `NLEmbedding`: https://developer.apple.com/documentation/naturallanguage/nlembedding
- Accelerate vDSP: https://developer.apple.com/documentation/accelerate/vdsp
- `PropertyListSerialization`: https://developer.apple.com/documentation/foundation/propertylistserialization
- Notarizing macOS software: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Full Disk Access and TCC (user-facing): https://support.apple.com/guide/mac-help/mchl211c911f/mac

GRDB:

- README and guides: https://github.com/groue/GRDB.swift
- Migrations: https://swiftpackageindex.com/groue/GRDB.swift/documentation/grdb/migrations
- Concurrency (`DatabasePool`, `DatabaseQueue`): https://swiftpackageindex.com/groue/GRDB.swift/documentation/grdb/concurrency
- Full-text search: https://swiftpackageindex.com/groue/GRDB.swift/documentation/grdb/fulltextsearch
- `ValueObservation`: https://swiftpackageindex.com/groue/GRDB.swift/documentation/grdb/valueobservation
- SQLCipher build: https://github.com/groue/GRDB.swift#encryption

SQLite:

- FTS5: https://www.sqlite.org/fts5.html
- WAL mode: https://www.sqlite.org/wal.html
- URI filenames (`immutable=1`): https://www.sqlite.org/uri.html
- `PRAGMA secure_delete`: https://www.sqlite.org/pragma.html#pragma_secure_delete

Sparkle:

- Documentation home: https://sparkle-project.org/documentation/
- Publishing an update / appcast: https://sparkle-project.org/documentation/publishing/
- EdDSA signing: https://sparkle-project.org/documentation/#segue-for-security-concerns
- Sandboxing notes (why Backglance does not need the XPC services): https://sparkle-project.org/documentation/sandboxing/

Other:

- Homebrew cask cookbook: https://docs.brew.sh/Cask-Cookbook
- GitHub Actions macOS runner images: https://github.com/actions/runner-images
- PasteShelf (source of the ported search engine): https://github.com/pasteshelf/pasteshelf

## Next Steps

- Read [ARCHITECTURE.md](./ARCHITECTURE.md) for how the packages fit together and where the schema-adapter boundary sits.
- Read [DATABASE_SCHEMA.md](./DATABASE_SCHEMA.md) for the archive DDL, migrations and the observed system store layout.
- Read [OS_COMPATIBILITY_PLAYBOOK.md](./OS_COMPATIBILITY_PLAYBOOK.md) before touching anything under `BackglanceCapture/Adapters/`.
- Set up a build with [../getting-started/DEVELOPMENT_GUIDE.md](../getting-started/DEVELOPMENT_GUIDE.md).

## Related Documentation

- [ARCHITECTURE.md](./ARCHITECTURE.md)
- [DATABASE_SCHEMA.md](./DATABASE_SCHEMA.md)
- [OS_COMPATIBILITY_PLAYBOOK.md](./OS_COMPATIBILITY_PLAYBOOK.md)
- [../getting-started/SETUP_GUIDE.md](../getting-started/SETUP_GUIDE.md)
- [../getting-started/DEVELOPMENT_GUIDE.md](../getting-started/DEVELOPMENT_GUIDE.md)
- [../features/SEARCH.md](../features/SEARCH.md)
- [../features/PERMISSIONS_PRIVACY.md](../features/PERMISSIONS_PRIVACY.md)
- [../deployment/DEPLOYMENT_GUIDE.md](../deployment/DEPLOYMENT_GUIDE.md)
- [../deployment/PACKAGING_NOTARIZATION.md](../deployment/PACKAGING_NOTARIZATION.md)
- [../deployment/CI_CD.md](../deployment/CI_CD.md)
- [../deployment/PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md)
- [../security/SECURITY.md](../security/SECURITY.md)
- [../reference/FAQ.md](../reference/FAQ.md)
- [../../README.md](../../README.md)
