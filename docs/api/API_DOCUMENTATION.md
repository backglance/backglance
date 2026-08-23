# API Documentation

Last Updated: 2026-08-18

Backglance has **no network API**. There is no server, no REST endpoint, no account, no webhook, and nothing listens on a port; the only network access the app ever makes is the Sparkle updater, which the user can switch off. What Backglance does have is three programmable surfaces, and this document describes all of them: the `backglance://` URL scheme (v1.0), Shortcuts App Intents (v1.x, planned), and the Swift APIs of the four packages (`BackglanceCore`, `BackglanceCapture`, `BackglanceSearch`, `BackglanceUI`) that contributors code against. For every module API you get the purpose, the real Swift signature, its threading / actor isolation, the errors it throws, a success and an error path, and a stability level.

## Table of Contents

- [There Is No Network API](#there-is-no-network-api)
- [Automation Surfaces at a Glance](#automation-surfaces-at-a-glance)
- [URL Scheme `backglance://`](#url-scheme-backglance)
  - [Routes](#routes)
  - [Examples with `open`](#examples-with-open)
  - [Error behavior](#error-behavior)
  - [Security properties](#security-properties)
- [Shortcuts / App Intents (v1.x, planned)](#shortcuts--app-intents-v1x-planned)
  - [Intents](#intents)
  - [`NotificationEntity`](#notificationentity)
  - [`GetMissedDigestIntent`](#getmisseddigestintent)
  - [`ExportNotificationsIntent`](#exportnotificationsintent)
  - [Intent error behavior](#intent-error-behavior)
- [Module APIs: Conventions](#module-apis-conventions)
- [BackglanceCapture](#backglancecapture)
  - [`CaptureEngine`](#captureengine)
  - [`StoreAdapter`](#storeadapter)
  - [`RecordParser`](#recordparser)
  - [`EnrichmentService`](#enrichmentservice)
- [BackglanceCore](#backglancecore)
  - [`Archive`](#archive)
  - [`RetentionPolicy` and `RetentionJob`](#retentionpolicy-and-retentionjob)
  - [`OTPRedactor`](#otpredactor)
  - [`RulesEngine`](#rulesengine)
  - [`DigestEngine`](#digestengine)
  - [`ExportService`](#exportservice)
  - [`PanicWipe`](#panicwipe)
- [BackglanceSearch](#backglancesearch)
  - [`SearchQuery` and `SearchHit`](#searchquery-and-searchhit)
  - [`QueryParser` grammar](#queryparser-grammar)
  - [`HybridSearch`](#hybridsearch)
- [Public API Stability Policy](#public-api-stability-policy)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## There Is No Network API

> ℹ️ **Info:** Backglance is a local-only macOS menu bar utility. It does not expose HTTP, gRPC, WebSocket, XPC-to-other-apps, or an AppleScript dictionary. If you were looking for a way to query the archive from another machine: there isn't one, by design. Export a CSV/JSON file (see [EXPORT_AUTOMATION.md](../features/EXPORT_AUTOMATION.md)) and move that.

What exists instead:

| Surface | Audience | Ships in | Can it return notification content? |
|---|---|---|---|
| `backglance://` URL scheme | scripts, launchers (Raycast, Alfred), other apps | v1.0 (`search`, `open`, `digest`, `pause`, `resume`); v1.x (`export`) | **No** — URLs only drive the UI |
| Shortcuts App Intents | Shortcuts users | v1.x (planned) | Yes, as `NotificationEntity`, in-process, by the user's explicit shortcut |
| Swift package APIs | contributors, the app target, tests | v1.0 | Yes — this is the app's own code |

The AppleScript/JXA dictionary is deliberately not planned; the reasoning is in [EXPORT_AUTOMATION.md](../features/EXPORT_AUTOMATION.md#applescript).

## Automation Surfaces at a Glance

```
  Terminal / Raycast / Alfred / other apps
        │  open "backglance://search?q=invoice"
        ▼
  ┌──────────────────────────────────────────────────────────────┐
  │  Backglance.app (LSUIElement, not sandboxed)                  │
  │                                                              │
  │  NSAppleEventManager kAEGetURL ──▶ URLRoute.parse            │
  │                                     │ URLRoute               │
  │  Shortcuts ─────▶ App Intents ──┐   ▼                        │
  │  (v1.x)           NotificationEntity  AppCoordinator.perform │
  │                                 │   │                        │
  │                                 ▼   ▼                        │
  │   ┌──────────────┐  ┌──────────────────┐  ┌───────────────┐  │
  │   │BackglanceCore│  │BackglanceCapture │  │BackglanceSearch│ │
  │   │ Archive      │◀─│ CaptureEngine    │  │ HybridSearch  │  │
  │   │ ExportService│  │ StoreAdapter…    │  │ QueryParser   │  │
  │   └──────────────┘  └──────────────────┘  └───────────────┘  │
  └──────────────────────────────────────────────────────────────┘
        ▲                       ▲
        │ archive.sqlite        │ read-only snapshot of Apple's store (⚠️ undocumented)
```

No arrow leaves the machine.

## URL Scheme `backglance://`

`Info.plist` registers `backglance` under `CFBundleURLTypes`; `AppDelegate` installs `URLSchemeHandler` for `kInternetEventClass` / `kAEGetURL`. If the app is not running, macOS launches it and delivers the URL after `applicationDidFinishLaunching`. The parser and route enum are shown in full in [EXPORT_AUTOMATION.md](../features/EXPORT_AUTOMATION.md#url-scheme); the table below is the contract.

The work is split across two files, and the seam matters. `URLRoute` and `URLRouteError` — the route enum, the bounds, and `URLRoute.parse(_:)` — live in `BackglanceCore` (`Automation/URLRoute.swift`); `URLSchemeHandler` in `Backglance/App/` is only the `NSAppleEventManager` registration and the dispatch to AppKit surfaces. That is not tidiness: no test bundle in this project has a `TEST_HOST`, so app-target code cannot be unit-tested at all, and the security properties below are all *parser* properties. `URLRouteTests` in `BackglanceCoreTests` is what makes them assertions rather than assertions of intent.

### Routes

| Route | Parameters | Effect | Since | Stability |
|---|---|---|---|---|
| `backglance://search?q=<urlencoded>` | `q` required, non-empty, truncated at 512 characters. Full [`QueryParser` grammar](#queryparser-grammar) is accepted. | Opens the popover with the search bar prefilled and the search running. | v1.0 | Stable |
| `backglance://open?id=<uuid>` | `id` required, an RFC 4122 UUID (`notifications.uuid`, the same value exported as `uuid`). | Opens the timeline window and reveals that notification; if it is not in the archive, shows a "Not in the archive" toast. | v1.0 | Stable |
| `backglance://digest` | — | Shows the latest digest, or the "Nothing missed" state. | v1.0 | Stable |
| `backglance://pause?minutes=<n>` | `minutes` optional, integer 1…10080 (one week). Omitted = pause indefinitely. | `CaptureEngine.pause(until:)`; status item shows the paused state. | v1.0 | Stable |
| `backglance://resume` | — | `CaptureEngine.resume()`. Notifications delivered while paused are not back-filled. | v1.0 | Stable |
| `backglance://export?from=YYYY-MM-DD&to=YYYY-MM-DD&format=csv\|json` | `from`, `to` required (local calendar days, `to` inclusive); `format` optional, default `csv`. | Opens `ExportSheet` **prefilled**. Nothing is written until the user presses **Export…**; default location `~/Downloads`. | v1.x | Evolving |

Unknown hosts (`backglance://anything-else`) and unknown query parameters are handled differently on purpose: an unknown host is an error; an unknown parameter is ignored so that future parameters degrade gracefully on older versions.

### Examples with `open`

```bash
# Search — always URL-encode the query. `from:` and `before:` are part of the grammar.
open "backglance://search?q=invoice"
open "backglance://search?q=from%3Aslack%20before%3A2026-08-01%20invoice"

# Reveal one notification by its uuid (for example from a JSON export)
open "backglance://open?id=6F9619FF-8B86-D011-B42D-00C04FC964FF"

# What did I miss?
open "backglance://digest"

# Pause for the length of a meeting, then resume
open "backglance://pause?minutes=45"
open "backglance://resume"

# v1.x — opens the export sheet prefilled; still asks before writing
open "backglance://export?from=2026-08-01&to=2026-08-17&format=json"
```

A small helper for `zsh` users who want a shorter spelling; it does the URL-encoding with Python's standard library so no extra tools are needed:

```bash
# ~/.zshrc
bg() {
  local q
  q="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(" ".join(sys.argv[1:])))' "$@")"
  open "backglance://search?q=${q}"
}
# usage: bg from:mail after:-7d "flight confirmation"
```

Raycast and Alfred both accept `open "backglance://…"` as a script action; there is no dedicated extension in v1.0.

### Error behavior

Every failure ends in the same two places: a toast in the app and one content-free line in the log. Nothing partial happens, and the process never exits because of a bad URL.

| Situation | Behavior | Log line (`category: automation`) |
|---|---|---|
| Unknown host | toast "Couldn't open link" | `bad url route: unknownHost("…")` |
| Missing required parameter (`q`, `id`, `from`, `to`) | toast | `bad url route: missingParameter("q")` |
| Malformed parameter (`id` not a UUID, `minutes` out of 1…10080, `from` after `to`) | toast | `bad url route: invalidParameter("minutes")` |
| `open?id=` for a uuid not in the archive | timeline window opens, toast "Not in the archive" | `open: uuid not found` (uuid is logged; it carries no content) |
| App is capturing in degraded mode (no FDA) | `search`, `open`, `digest`, `export` still work on what was captured; `pause`/`resume` change status but nothing is being captured | none |
| `export` while another export sheet is open | queued behind the open sheet, not started in parallel | none |
| Archive being wiped or migrated | toast "Backglance is busy, try again in a moment" | `route deferred: archive unavailable` |

The caller of `open` gets no exit code that reflects the outcome. `open` returns 0 as soon as Launch Services has delivered the event, so scripts cannot branch on "did the notification exist"; that is a limit of the URL-scheme model, and one reason the Shortcuts intents exist for anything that needs a return value.

### Security properties

> 🔒 **Security:** The URL scheme is a one-way door into the UI. It cannot read the archive, cannot delete, and cannot bypass a confirmation.

- **No content leaves via URL.** There are no `x-callback-url` style `x-success=` parameters and there never will be: a route can *show* something in Backglance, it cannot *return* text to the calling app. `search` opens the popover; it does not hand the results back.
- **No destructive route.** There is no `wipe`, `delete`, `mark-read`, `set-retention` or similar. `PanicWipe` is reachable only from Settings ▸ Privacy (typed confirmation) and the optional global hotkey.
- **Nothing is written without confirmation.** `export` opens the sheet with fields prefilled; the file is written only after the user presses **Export…**, into the location the user picks (default `~/Downloads`), with `0600` permissions.
- **Bounded input.** `q` is cut at 512 characters, `minutes` at 10080; parameters are read through `URLComponents`, never string-spliced into SQL. The FTS `MATCH` string is built by `QueryParser`, which quotes user terms.
- **No content in logs.** The handler logs the *failure kind*, never the query string.
- **Any local process can call it.** That is inherent to URL schemes on macOS. The routes are designed so that the worst an unfriendly local process can do is open the popover, pause capture, or pop an export sheet — all visible, all reversible.

## Shortcuts / App Intents (v1.x, planned)

> ℹ️ **Status:** Planned for v1.x — not in v1.0.

App Intents compile into the app target (`Backglance/Intents/`), so they run **in-process** and use `Archive.shared`, `CaptureEngine.shared` (installed by `AppDelegate` at launch) and `HybridSearch.shared` directly. Shortcuts launches Backglance if needed. `NotificationEntity`, `SearchNotificationsIntent` and `PauseCaptureIntent` are listed in full in [EXPORT_AUTOMATION.md](../features/EXPORT_AUTOMATION.md#shortcuts-app-intents); the remaining ones are below.

### Intents

| Intent | Parameters | Returns | Opens app? |
|---|---|---|---|
| `SearchNotificationsIntent` | `query: String`, `limit: Int = 25` (1…500), `sinceDays: Int?` | `[NotificationEntity]` + dialog | no |
| `GetMissedDigestIntent` | — | `[NotificationEntity]` from the latest digest + dialog | no |
| `ExportNotificationsIntent` | `from: Date`, `to: Date`, `format: ExportFormatEnum` | `IntentFile` | **yes** (`openAppWhenRun = true`, confirmation sheet) |
| `PauseCaptureIntent` | `minutes: Int?` (1…10080) | dialog | no |
| `SnoozeNotificationIntent` | `notification: NotificationEntity`, `until: Date` | dialog | no |

### `NotificationEntity`

`NotificationEntity` is the only entity type. Its `id` is the notification `uuid` string (the same value `backglance://open?id=` accepts and the export writes), so a shortcut can pass results into `open` URLs. Properties: `appName`, `title`, `body`, `deliveredAt`, `missed`. Redacted notifications come back with `[code redacted]` in place of the code, exactly like the timeline. There is no property carrying the original OTP because the original was never stored.

`NotificationEntityQuery.entities(for:)` resolves by uuid; `suggestedEntities()` returns the ten most recent notifications so the Shortcuts editor has something to show.

### `GetMissedDigestIntent`

```swift
// Backglance/Intents/GetMissedDigestIntent.swift
import AppIntents
import BackglanceCore

struct GetMissedDigestIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Missed Digest"
    static var description = IntentDescription("Returns the notifications from your latest Backglance digest.")

    func perform() async throws -> some IntentResult & ReturnsValue<[NotificationEntity]> & ProvidesDialog {
        // Latest digest, or nil if no away session has produced one yet.
        guard let digest = try Archive.shared.lastDigest(), let digestID = digest.id else {
            return .result(value: [], dialog: "Nothing missed.")
        }
        let items = try Archive.shared.digestNotifications(digestID: digestID)   // ranked
        let apps = try Archive.shared.appsByID()
        let entities = items.map { NotificationEntity($0, appName: apps[$0.appId]?.displayName ?? "") }
        let count = entities.count
        let dialog: IntentDialog = count == 0
            ? "Nothing missed."
            : "You missed \(count) notification\(count == 1 ? "" : "s")."
        return .result(value: entities, dialog: dialog)
    }
}
```

### `ExportNotificationsIntent`

```swift
// Backglance/Intents/ExportNotificationsIntent.swift
import AppIntents
import BackglanceCore

enum ExportFormatEnum: String, AppEnum {
    case csv, json
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Export Format"
    static var caseDisplayRepresentations: [ExportFormatEnum: DisplayRepresentation] = [
        .csv: "CSV", .json: "JSON",
    ]
    var format: ExportFormat { self == .csv ? .csv : .json }
}

struct ExportNotificationsIntent: AppIntent {
    static var title: LocalizedStringResource = "Export Notifications"
    static var openAppWhenRun = true      // the confirmation sheet is not optional

    @Parameter(title: "From") var from: Date
    @Parameter(title: "To") var to: Date
    @Parameter(title: "Format", default: .csv) var format: ExportFormatEnum

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let request = ExportRequest(from: from, to: to, format: format.format)
        // ExportCoordinator shows ExportSheet prefilled and resumes when the user
        // presses Export… (returns the written URL) or dismisses (throws .cancelled).
        let url = try await ExportCoordinator.shared.runConfirmed(request)
        let data = try Data(contentsOf: url)
        return .result(value: IntentFile(data: data, filename: url.lastPathComponent))
    }
}
```

### Intent error behavior

| Situation | What Shortcuts sees |
|---|---|
| Empty query | `needsValueError` prompt "What should Backglance search for?" |
| Archive unavailable (wipe or migration in progress) | `ArchiveError.unavailable` rethrown as `LocalizedError` "Backglance is busy, try again in a moment." |
| Export sheet dismissed | `ExportError.cancelled` → "Export cancelled." — the shortcut stops cleanly, no file written |
| Search backend degraded (semantic index missing) | falls back to FTS + fuzzy silently; no error |
| Snooze target already fired or deleted | "That notification is no longer available." |

Intents never log the query, the entity contents or file paths inside `~`.

## Module APIs: Conventions

The following sections describe the Swift APIs of the packages under `Packages/`. They are what the app target, the widgets extension (v1.x) and the tests import. Every symbol carries a stability level:

| Level | Meaning |
|---|---|
| **Stable** | Part of the package's public contract. Changed only with a package major bump (see [policy](#public-api-stability-policy)) and a CHANGELOG entry. |
| **Evolving** | Public, used by the app, but the signature may still change in a minor bump. Prefer wrapping it in your own code. |
| **Internal** | `internal`/`package` access or `public` only for `@testable`-free tests. No promise at all. |

Common conventions:

- **Concurrency.** Anything that touches the system store lives inside the `CaptureEngine` actor. `Archive` is `Sendable` and safe from any actor: reads run on GRDB reader connections, writes are serialized by `DatabasePool`. UI-facing models are `@MainActor`. Nothing in the packages calls `DispatchQueue.main`.
- **Errors.** One typed error enum per module: `CaptureError`, `ArchiveError`, `SearchError`, `ExportError`. Errors carry identifiers and reasons, never notification content. Expected outcomes (unknown schema, no rows, no digest yet) are *values*, not thrown errors.
- **Dates.** Swift `Date` in APIs; Unix seconds `REAL` in the archive via the `UnixDate` `DatabaseValueConvertible` wrapper. The store's Cocoa-epoch values are converted by `RecordParser` and never leak past it.
- **Content in logs.** No public API logs a title, body, sender, or query. Log messages carry counts, ids, durations, error kinds.

> ⚠️ **Warning:** Everything under `BackglanceCapture` that touches Apple's store rides an **undocumented system database**. Column names may change in any macOS release; the fingerprint + adapter + fixture strategy exists for that reason. The *Swift* API surface described here is stable; what it reads underneath is not.

## BackglanceCapture

Reads Apple's Notification Center store (the system store, `~/Library/Group Containers/group.com.apple.usernoted/db2/db`) from a read-only copied snapshot, parses records, redacts, enriches, and inserts into the archive.

### `CaptureEngine`

**Purpose.** The single owner of capture: adapter resolution, cursor, status, the wake loop, first-launch import. **Stability: Stable** (public methods and `CaptureStatus`), constructor **Evolving**.

```swift
public actor CaptureEngine {
    public private(set) var status: CaptureStatus            // .running / .paused(until:) / .degraded(DegradedReason) / .stopped
    public nonisolated let statusStream: AsyncStream<CaptureStatus>

    public init(archive: Archive,
                watcher: StoreWatcher,
                redactor: OTPRedactor = .default,
                exclusions: ExclusionList,
                enrichment: EnrichmentService)

    public func start() async                    // bootstrap or degrade, then follow watcher.wakes
    public func stop()
    public func pause(until date: Date?)         // nil = indefinitely; auto-resumes at `date`
    public func resume() async                   // fast-forwards the cursor; paused-time notifications are not back-filled
    @discardableResult
    public func importExisting() async throws -> Int   // first-launch import; rows tagged source = 'import'
}
```

**Isolation.** Actor. `statusStream` is `nonisolated` so the status item can `for await` it from the main actor. `StoreWatcher` events are hopped into the actor with `Task { await engine.storeDidChange() }`.

**Errors.** `start()`, `pause`, `resume` never throw: failures become `status = .degraded(reason)`. `importExisting()` throws `CaptureError` (`.degraded(.storeNotFound)` when no adapter is resolved, `.snapshotFailed`, `.readFailed`). Per-record failures inside a batch are logged by `rec_id` and skipped; they never fail the call.

```swift
// Success path: wire the engine at launch (AppDelegate)
let engine = CaptureEngine(archive: .shared,
                           watcher: StoreWatcher(),
                           exclusions: ExclusionList.default,
                           enrichment: EnrichmentService())
Task {
    await engine.start()
    for await status in engine.statusStream {
        await MainActor.run { statusItem.render(status) }
    }
}

// Error path: import on first launch, degrade visibly instead of alerting
Task {
    do {
        let count = try await engine.importExisting()
        logger.notice("imported \(count, privacy: .public)")
    } catch let error as CaptureError {
        // e.g. .degraded(.noFullDiskAccess) — the status item already shows it
        logger.error("import skipped: \(error.logDescription, privacy: .public)")
    }
}
```

### `StoreAdapter`

**Purpose.** One adapter per store schema fingerprint / macOS major. Contributors adding macOS support implement this protocol. **Stability: Stable** (protocol), adapters themselves **Evolving** (they follow Apple).

```swift
public protocol StoreAdapter: Sendable {
    static var id: String { get }                        // "v14", "v15", "v26"
    static var supportedOS: ClosedRange<Int> { get }     // major versions
    static func matches(_ fp: StoreFingerprint) -> Bool
    func probe(_ db: Database) throws -> ProbeResult
    func records(after cursor: StoreCursor, in db: Database) throws -> [RawStoreRecord]   // ≤ 500 per call
    func cursor(for record: RawStoreRecord) -> StoreCursor
}

public enum ProbeResult: Sendable, Equatable {
    case ok(recordCount: Int)
    case unknownSchema(details: String)
    case permissionDenied
    case missingTables([String])
}

public enum StoreAdapterRegistry {
    public static func resolve(fingerprint: StoreFingerprint) -> (any StoreAdapter)?
    public enum Resolution: Sendable { case adapter(any StoreAdapter), degraded(reason: DegradedReason) }
    public static func resolve(fingerprint: StoreFingerprint, probing db: Database) -> Resolution
}
```

**Isolation.** Adapters are value types with no state; every call receives a GRDB `Database` that belongs to a read-only `?immutable=1` snapshot. They are only ever called from inside `CaptureEngine`.

**Errors.** `probe` returns `ProbeResult` for expected outcomes and throws only on I/O (`DatabaseError`). `records(after:in:)` throws `DatabaseError` on read failure; the engine maps that to `CaptureError.readFailed`.

```swift
// Success path: resolve and read a page (as the engine does)
let snapshot = try StoreSnapshot.take(of: StoreLocation.current())
defer { snapshot.discard() }
let fp = try snapshot.read { db in try StoreFingerprint.compute(db) }
switch StoreAdapterRegistry.resolve(fingerprint: fp, probing: try snapshot.database()) {
case .adapter(let adapter):
    let page = try snapshot.read { db in try adapter.records(after: .start, in: db) }
    print("page of \(page.count) records")
case .degraded(let reason):
    // Error path: unknown schema on a new macOS beta → degraded, not crashed
    print("degraded: \(reason)")     // e.g. .unknownSchema(fp)
}
```

> ⚠️ **Warning:** `RawStoreRecord` mirrors the observed `record` table (`rec_id`, `app_id`, `uuid`, `data`, `delivered_date`, `presented`, `style`). This is what we have observed, not an API. Column names may change in any macOS release; the fingerprint + adapter + fixture strategy exists for that reason.

### `RecordParser`

**Purpose.** Decodes `RawStoreRecord.plistData` (binary plist) into a `ParsedNotification`. **Stability: Stable** (signature), key mapping **Evolving** (⚠️ undocumented keys `app`, `date`, `req.titl/subt/body/iden/cate/thre`, `atta`, `usda`).

```swift
public struct RecordParser: Sendable {
    public init()
    public func parse(_ raw: RawStoreRecord) throws -> ParsedNotification
}
```

**Isolation.** Pure, `Sendable`, safe anywhere. **Errors.** `CaptureError.parseFailed(recID:reason:)` when the plist does not decode or has no `req` dictionary. Missing optional keys are not errors — a notification with only a body is valid.

```swift
let parser = RecordParser()
do {
    let n = try parser.parse(raw)          // success: title/subtitle/body may each be nil
    print(n.bundleID, n.deliveredAt)       // deliveredAt converted from Cocoa epoch
} catch CaptureError.parseFailed(let recID, let reason) {
    logger.error("skip rec \(recID, privacy: .public): \(reason, privacy: .public)")   // no content
}
```

### `EnrichmentService`

**Purpose.** Adds the app icon (cached under `~/Library/Application Support/Backglance/icons/`) and resolves a deep link from `userInfo` (Messages `sms:`/`imessage:`, Mail `message://`, Slack/Discord URLs when present). **Stability: Evolving.**

```swift
public final class EnrichmentService: Sendable {
    public init(iconCache: IconCache = .default, resolvers: [any DeepLinkResolver] = DeepLinkResolvers.builtIn)
    public func enrich(_ n: ParsedNotification) async -> ParsedNotification   // never throws; returns input unchanged on failure
    public func icon(for bundleID: String) async -> NSImage?
}
```

**Isolation.** `Sendable` class; `enrich` awaits `NSWorkspace` on the main actor internally. **Errors.** None thrown by design — a missing icon or unresolvable link is not a reason to lose a notification.

```swift
let enriched = await enrichment.enrich(parsed)
if let link = enriched.deepLink { print("opens with", link.scheme ?? "-") }   // success
else { print("no deep link; Open in App falls back to activating the app") }  // soft failure
```

## BackglanceCore

Models, the archive, migrations, retention, redaction, rules, digests, away sessions, export and panic wipe. Depends only on GRDB and Foundation.

### `Archive`

**Purpose.** The one door to `archive.sqlite`. Wraps a GRDB `DatabaseWriter` — a `DatabasePool` on disk (WAL, `0600`, directory `0700`), a `DatabaseQueue` in memory for tests — runs migrations `v1_initial` … `v6_sync_metadata`, and offers typed reads/writes. **Stability: Stable** for `read`/`write`/`insert`/`upsertApp`/lookup methods; `pool` **Evolving** (exposed for `ValueObservation` and streaming reads).

```swift
public final class Archive: Sendable {
    public static let shared: Archive                     // ~/Library/Application Support/Backglance/archive.sqlite
    public init(inMemory: Bool) throws                    // full migration chain against :memory:
    public init(path: String) throws

    /// `DatabasePool` on disk, `DatabaseQueue` in memory (tests). Both are `DatabaseWriter`.
    public var pool: any DatabaseWriter

    // Generic access
    public func read<T: Sendable>(_ body: @Sendable (Database) throws -> T) async throws -> T
    public func write<T: Sendable>(_ body: @Sendable (Database) throws -> T) async throws -> T
    public func writeInTransaction<T>(_ body: (Database) throws -> T) throws -> T   // long imports

    // Typed helpers used by capture, intents and UI. Every parameter is a Core type:
    // ParsedNotification, StoreCursor and StoreFingerprint belong to BackglanceCapture,
    // which depends on Core, so they cannot appear here.
    @discardableResult
    public func upsertApp(bundleID: String, now: Date, retention: AppRetention? = nil) throws -> AppRecord
    @discardableResult
    public func insert(_ n: ArchivedNotification, redaction: RedactionEvent? = nil) throws -> ArchivedNotification
    @discardableResult
    public func insertOrUpdate(_ n: ArchivedNotification, redaction: RedactionEvent? = nil) throws -> InsertOutcome
    public func notification(id: Int64) throws -> ArchivedNotification
    public func notifications(ids: [Int64]) async throws -> [(notification: ArchivedNotification, appName: String)]
    public func notifications(uuids: [UUID]) async throws -> [(notification: ArchivedNotification, appName: String)]
    public func recentNotifications(limit: Int) async throws -> [(notification: ArchivedNotification, appName: String)]
    public func countNotifications(includingDeleted: Bool) throws -> Int

    // Digests. Reads are synchronous like the rest of the archive's typed helpers;
    // `Archive+Digest.swift` has the full set (docs/features/MISSED_DIGEST.md#digestview).
    public func pendingDigest() throws -> Digest?            // newest with dismissed_at IS NULL
    public func lastDigest() throws -> Digest?               // newest, whatever its state
    public func awaySession(id: Int64) throws -> AwaySession?
    public func digestNotifications(digestID: Int64) throws -> [ArchivedNotification]   // in rank order
    public func deliveryDates(inAwaySession sessionID: Int64) throws -> [Date]
    @discardableResult
    public func markDigestShown(_ id: Int64, at date: Date) throws -> Bool   // once only
    @discardableResult
    public func dismissDigest(_ id: Int64, at date: Date) throws -> Bool     // once only
    @discardableResult
    public func markRead(ids: [Int64]) throws -> Int

    // capture_state, as opaque values. BackglanceCapture puts the typed accessors on top.
    public func captureState(_ key: CaptureStateKey) throws -> String?
    public func setCaptureState(_ value: String?, for key: CaptureStateKey) throws
    public func captureStateJSON<Value: Decodable>(_ key: CaptureStateKey, as type: Value.Type) throws -> Value?
    public func setCaptureStateJSON(_ value: some Encodable, for key: CaptureStateKey) throws
    public func adapterID() throws -> String?
    public func saveAdapterID(_ adapterID: String) throws
    public func lastImportDate() throws -> Date?
    public func saveLastImport(_ date: Date) throws
}
```

> ℹ️ **Info:** The capture-shaped API is split across the module boundary, because the dependency direction is one-way ([ARCHITECTURE.md](../architecture/ARCHITECTURE.md#dependency-graph)). `BackglanceCore` takes `ArchivedNotification` and stores capture bookkeeping as opaque JSON; `BackglanceCapture` adds `extension Archive` with `loadCursor()` / `saveCursor(_:)` / `clearCursor()` / `loadFingerprint()` / `saveFingerprint(_:)` and the `ArchivedNotification(parsed:appID:storeRecID:source:capturedAt:)` conversion from a `ParsedNotification`. See [CAPTURE.md](../features/CAPTURE.md#cursor-persistence).

**Isolation.** `Sendable`; call from any actor. Async `read`/`write` are non-blocking; the synchronous variants (`insert`, `upsertApp`, `notification(id:)`) are meant for the capture actor and tests. On disk, where `pool` is a `DatabasePool`, `pool.read` snapshots are consistent even while capture inserts; in-memory it is a `DatabaseQueue`, which serialises reads against writes instead — same code path, no WAL.

> ℹ️ **Info:** `pool` is typed `any DatabaseWriter`, not `DatabasePool`, so the in-memory `DatabaseQueue` behind `Archive(inMemory:)` and the on-disk `DatabasePool` share one code path. Every `Archive` method goes through `pool.read { }` / `pool.write { }`, which both types provide. See [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md#migration-strategy).

**Errors.** `ArchiveError`: `.openFailed`, `.migrationFailed`, `.duplicate` (uuid or `store_rec_id` already archived), `.insertFailed`, `.integrityCheckFailed`, `.observationFailed`, `.wipeIncomplete`, plus `.unavailable` while a wipe or migration holds the pool. GRDB `DatabaseError` from custom `read`/`write` bodies passes through unchanged.

```swift
// Success path (test): in-memory archive, insert, count
let archive = try Archive(inMemory: true)
let now = Date(timeIntervalSince1970: 1_755_421_200)
let app = try archive.upsertApp(bundleID: "com.example.demo", now: now)
_ = try archive.insert(ArchivedNotification.stub(appID: app.id, deliveredAt: now))
XCTAssertEqual(try archive.countNotifications(includingDeleted: false), 1)

// Error path: duplicate store_rec_id is an expected outcome during import + live overlap.
// In BackglanceCapture, where ParsedNotification lives:
let row = ArchivedNotification(parsed: parsed, appID: app.id!, storeRecID: 4_242,
                               source: .live, capturedAt: now)
_ = try archive.insertOrUpdate(row)                       // .inserted(id:)
if case .duplicate = try archive.insertOrUpdate(row) {
    // advance the cursor silently — not an error
}
```

> ✅ **Do:** use `ValueObservation.tracking { db in … }.values(in: archive.pool)` for anything the UI shows live. It delivers on the main actor without hand-written locking.

> ❌ **Don't:** open `archive.sqlite` with a second `DatabaseQueue` in the same process. Two connections with WAL work, but the migrator, the FTS triggers and the wipe all assume one pool.

### `RetentionPolicy` and `RetentionJob`

**Purpose.** Retention is a global default (`days30`) with per-app override in `apps.retention` (`'inherit'` means "use global"). `RetentionJob` soft-deletes and later hard-prunes. **Stability: Stable** (`RetentionPolicy` raw values are the archive column vocabulary), `RetentionJob` **Evolving**.

```swift
public enum RetentionPolicy: String, Codable, CaseIterable, Sendable {
    case hours24 = "24h", days7 = "7d", days30 = "30d", forever, never
    public var interval: TimeInterval?     // nil for .forever and .never
}

public struct RetentionJob: Sendable {
    public struct Result: Equatable, Sendable { public var softDeleted: Int; public var hardPruned: Int }
    public init(archive: Archive, defaultPolicy: RetentionPolicy, clock: @escaping @Sendable () -> Date = Date.init)
    @discardableResult
    public func run() throws -> Result       // one write transaction; safe to call every hour
}
```

**Isolation.** Synchronous, runs inside one `archive.write`; the app schedules it from a background `Task` hourly and on wake. **Errors.** `ArchiveError` / `DatabaseError` from the write; nothing else.

```swift
let job = RetentionJob(archive: archive, defaultPolicy: .days30, clock: { now })
do {
    let r = try job.run()
    logger.notice("retention: soft \(r.softDeleted, privacy: .public) hard \(r.hardPruned, privacy: .public)")
} catch {
    logger.error("retention failed: \(String(describing: error), privacy: .public)")   // next hour retries
}
```

`.never` (do not store this app) is enforced *before insert* by `ExclusionList`, not by the job; the job only handles rows that exist.

### `OTPRedactor`

**Purpose.** Replace one-time codes with `[code redacted]` in memory before insert; on by default for `com.apple.MobileSMS` and `com.apple.mail`. **Stability: Stable.**

```swift
public struct OTPRedactor: Sendable {
    public static let `default`: OTPRedactor          // EN/TR/DE keyword sets, 4–8 digit codes
    public init(patterns: [OTPPattern], enabledBundleIDs: Set<String>)
    public func redact(_ n: ParsedNotification) -> (ParsedNotification, RedactionEvent?)
}
```

**Isolation.** Pure value, `Sendable`. **Errors.** None; a non-match returns the input and `nil`.

```swift
let (clean, event) = OTPRedactor.default.redact(parsed)
if let event {
    // success: body now contains "[code redacted]"; event.kind == "otp", event.patternID e.g. "otp.keyword.en"
    try archive.insert(clean, redaction: event, storeRecID: raw.recID, source: .live)
} else {
    // not an OTP, or app not enabled for redaction — stored as parsed
    try archive.insert(clean, redaction: nil, storeRecID: raw.recID, source: .live)
}
```

> 🔒 **Security:** The original digits never reach the archive, the FTS index, the log, or a `RedactionEvent`. Redaction cannot be undone because there is nothing to undo it from.

### `RulesEngine`

**Purpose.** Visual triage: highlight colour, pin, mute. Rules never change what macOS delivers. **Stability: Stable** (`evaluate`, `Triage`), rule compilation **Evolving**.

```swift
public struct Triage: Equatable, Sendable {
    public var highlight: HighlightColor?
    public var pinned: Bool
    public var muted: Bool
    public var matchedRuleIDs: [Int64]
}

public final class RulesEngine: @unchecked Sendable {
    public init(archive: Archive)

    // Instance surface: holds the compiled rule snapshot and a bounded per-row triage cache,
    // refreshed by a ValueObservation on `rules` and `apps`.
    public func evaluate(_ n: ArchivedNotification) -> Triage
    public func setAppMuted(bundleID: String, muted: Bool) async throws     // throws RulesError.unknownApp

    // Pure statics: no state, safe to call from anywhere, used by the digest and search paths.
    public static func evaluate(_ n: ArchivedNotification, rules: [Rule], bundleID: String? = nil) -> Triage
    public static func evaluate(_ n: ArchivedNotification, compiled: CompiledRules, bundleID: String? = nil) -> Triage   // hot path
    public static func compile(_ rules: [Rule]) -> (CompiledRules, [RuleCompileError])          // bad regex → skipped + reported
}
```

> ℹ️ **Info:** The statics are pure and the instance exists only to own the compiled snapshot and triage cache that `TimelineStore` and `NotificationActionHandler` share. `bundleID` is optional because `ArchivedNotification` stores `app_id`, not a bundle identifier; when it is `nil`, app-scoped rules are skipped rather than guessed. See [`../features/RULES.md`](../features/RULES.md).

**Isolation.** The statics are pure and `Sendable`; the instance guards its snapshot with a lock and is callable from any isolation. The timeline calls `evaluate` on the main actor per row. **Errors.** `evaluate` never throws. An invalid `regex` rule is dropped from `CompiledRules` and surfaced in Settings ▸ Rules via `RuleCompileError`. `setAppMuted` throws `RulesError.unknownApp` when no row matched.

```swift
let (compiled, problems) = RulesEngine.compile(rules)
for p in problems { logger.notice("rule \(p.ruleID, privacy: .public) skipped: \(p.message, privacy: .public)") }
let triage = RulesEngine.evaluate(notification, compiled: compiled)
row.background = triage.highlight?.color ?? .clear    // success: amber for a matched "invoice" rule
```

### `DigestEngine`

**Purpose.** Builds a `Digest` at away-session end from notifications with `delivered_at` inside the session or `presented == false`; grouped by app, VIP first. **Stability: Evolving** (thresholds may move; the `Digest`/`DigestItem` models are Stable).

```swift
public struct DigestEngine: Sendable {
    public struct Options: Sendable {
        public var minimumSessionDuration: TimeInterval = 300      // 5 min
        public var maximumItems: Int = 200
        public init() {}
    }
    public init(archive: Archive, options: Options = Options())
    /// Returns nil when the session is shorter than the threshold or has 0 notifications (auto-suppressed).
    public func build(session: AwaySession) async throws -> Digest?
    public func markShown(_ digest: Digest) async throws
    public func dismiss(_ digest: Digest) async throws
}
```

**Isolation.** `Sendable`; `build` reads and writes through `archive`. Called by `AwaySessionTracker` when a session ends. **Errors.** `ArchiveError` / `DatabaseError`. "No digest" is `nil`, not an error.

```swift
if let digest = try await DigestEngine(archive: .shared).build(session: ended) {
    await MainActor.run { banner.show(digest) }        // one banner per away session, never nagging
} else {
    // < 5 min or nothing missed — stay quiet
}
```

### `ExportService`

**Purpose.** Streams CSV or JSON for a date range or selection. Full listing in [EXPORT_AUTOMATION.md](../features/EXPORT_AUTOMATION.md#business-logic). **Stability: Stable** (`ExportRequest`, `ExportFormat`, `export(_:to:progress:)`), output columns **Stable** once v1.0 ships.

```swift
public final class ExportService: Sendable {
    public init(archive: Archive)
    /// Returns rows written. Streams from one read snapshot; deletes the partial file on failure.
    public func export(_ request: ExportRequest, to url: URL,
                       progress: (@Sendable (Int) -> Void)? = nil) async throws -> Int
}
```

**Isolation.** Any actor; runs inside `pool.read`; honours `Task` cancellation. **Errors.** `ExportError.invalidRange`, `.rangeTooLarge(days:)`, `.cancelled`, `.io(String)`.

```swift
let service = ExportService(archive: .shared)
do {
    let n = try await service.export(ExportRequest(from: from, to: to, format: .json), to: url)
    print("wrote \(n) rows")
} catch ExportError.cancelled {
    // user cancelled; partial file already removed
} catch ExportError.io(let msg) {
    // e.g. "No space left on device"
    presentToast(msg)
}
```

### `PanicWipe`

**Purpose.** Destroy the archive and every derived file, then recreate an empty archive. **Stability: Stable** (`execute`), the exact list of paths **Evolving** as features add caches.

```swift
public enum PanicWipe {
    public struct Options: Sendable, Equatable {
        public var forgetPerAppSettings: Bool          // default false: exclusions and overrides survive
        public init(forgetPerAppSettings: Bool = false)
    }
    public struct Report: Sendable, Equatable { public var removed: [String]; public var failed: [String] }
    /// Secure-deletes every table, unlinks archive + -wal + -shm, icons/, tmp/; recreates an empty archive
    /// at the same path and swaps it in behind the same `Archive` object — references stay valid.
    /// The caller is responsible for pausing capture, the typed "wipe" confirmation and Touch ID (LAContext).
    @MainActor
    @discardableResult
    public static func execute(archive: Archive, options: Options = Options()) async throws -> Report
}
```

**Isolation.** `@MainActor` because it replaces the writer behind `Archive.shared` and every writer must be stopped first — pausing capture is the caller's, since `BackglanceCore` cannot see `BackglanceCapture`. **Errors.** `ArchiveError.wipeIncomplete(remaining:)` when any file could not be removed; the archive is still recreated first, so the app stays usable.

```swift
do {
    await capture.pause()                                  // the caller stops the writers
    let report = try await PanicWipe.execute(archive: .shared)
    await capture.resume()
    logger.notice("wipe removed \(report.removed.count, privacy: .public) paths")
} catch ArchiveError.wipeIncomplete(let remaining) {
    presentAlert("Some files couldn't be removed. See the log for details.")   // remaining is in the log, not the alert
}
```

## BackglanceSearch

FTS5 (`notifications_fts`, `unicode61 remove_diacritics 2 tokenchars '@.-'`, `prefix='2 3'`), Levenshtein fuzzy matching, optional on-device `NLEmbedding` semantic index, merged by `HybridSearch`. Ported from PasteShelf's search engine; storage is GRDB, not Core Data.

### `SearchQuery` and `SearchHit`

**Stability: Stable.**

```swift
public struct SearchQuery: Sendable, Equatable {
    public var text: String                       // raw user text, grammar included
    public var limit: Int = 200
    public var mode: Mode = .hybrid
    public enum Mode: Sendable { case ftsOnly, hybrid }
    public init(text: String, limit: Int = 200, mode: Mode = .hybrid)
}

public struct SearchHit: Sendable, Equatable, Identifiable {
    public var id: Int64 { notificationID }
    public let notificationID: Int64
    public let score: Double                      // 0…1, weighted FTS 0.4 / semantic 0.5 / fuzzy 0.3, normalized
    public let snippet: String?                   // FTS snippet(), already redacted text
    public let sources: Set<Source>
    public enum Source: Sendable { case fts, semantic, fuzzy }
}
```

### `QueryParser` grammar

`QueryParser.parse(_:) throws -> ParsedQuery` splits the text into free terms (FTS `MATCH`) and structured filters (SQL `WHERE`). **Stability: Stable** for the tokens below; new tokens may be added in a minor bump.

| Token | Example | Meaning |
|---|---|---|
| bare word | `invoice` | FTS term, prefix-matched (`invoice*`) |
| `"phrase"` | `"flight confirmation"` | FTS phrase |
| `-term` | `-newsletter` | exclude term (`NOT`) |
| `from:` / `app:` | `from:slack`, `app:com.tinyspeck.slackmacgap` | app by display name (case-insensitive contains) or exact bundle id |
| `sender:` | `sender:alice` | `sender` column contains |
| `thread:` | `thread:abc123` | exact `thread_id` |
| `before:` | `before:2026-08-01`, `before:today` | `delivered_at <` start of that local day |
| `after:` | `after:2026-08-01`, `after:-7d` | `delivered_at >=` start of day |
| `on:` | `on:2026-08-01`, `on:yesterday` | that local calendar day; sets both `after` (start of day) and `before` (start of next day) |
| `is:` | `is:unread`, `is:read`, `is:pinned`, `is:missed`, `is:vip` | flags (`is_read`, `is_pinned`, `away_session_id IS NOT NULL`, VIP rule match) |
| `has:` | `has:link`, `has:attachment` | `deep_link IS NOT NULL`, `attachments_json IS NOT NULL` |
| `redacted:` | `redacted:yes` | `redaction = 'otp'` |

`before:`, `after:`, and `on:` all accept the same set of date forms: an absolute `yyyy-MM-dd`; the named days `today` and `yesterday`; and a relative offset from `now` — `-Nd` (days), `-Nw` (weeks), or `-Nh` (hours). Day and week offsets snap to that day's local midnight; hour offsets are exact (`-36h` is a moment, not a day).

Rules: tokens are separated by whitespace; a `key:` with an unknown key, or a known key with a value it doesn't recognize (e.g. `is:archived`), is treated as a bare word rather than an error; an unbalanced quote runs to the end of the text. Only the free terms go into `MATCH`, quoted with FTS5 double-quote escaping, so user input never reaches SQL as raw text.

```swift
public struct ParsedQuery: Sendable, Equatable {
    public var ftsMatch: String?                  // nil when there are no free terms (filters only)
    public var terms: [String]                    // for fuzzy + semantic
    public var bundleIDs: Set<String>
    public var appNameContains: String?
    public var sender: String?
    public var threadID: String?
    public var before: Date?
    public var after: Date?
    public var flags: Set<Flag>
    public enum Flag: Sendable { case unread, read, pinned, missed, vip, hasLink, hasAttachment, redacted }
}

public enum QueryParser {
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) throws -> ParsedQuery
}
```

**Errors.** `SearchError.invalidQuery(String)` only for a `before:`/`after:`/`on:` value that is neither a recognized date form nor a relative offset. Everything else parses to *something*.

```swift
let q = try QueryParser.parse("from:slack before:2026-08-01 invoice")
// q.appNameContains == "slack", q.before == 2026-08-01 00:00 local, q.ftsMatch == "(\"invoice\"*)"

do { _ = try QueryParser.parse("before:whenever soon") }
catch SearchError.invalidQuery(let why) { print(why) }
// "before: use yyyy-MM-dd, today, yesterday, or a relative offset like -7d, -2w, -36h."
```

### `HybridSearch`

**Purpose.** Runs FTS, then fuzzy and (if enabled) semantic scoring on the candidate set, merges by weighted score. **Stability: Stable** (`search`), `ftsOnly` and `shared` **Evolving**.

```swift
public actor HybridSearch {
    public static let shared: HybridSearch                       // app instance over Archive.shared
    public init(archive: Archive, semantic: SemanticIndex? = nil, fuzzy: FuzzyMatcher = FuzzyMatcher(threshold: 0.6))
    public func search(_ q: SearchQuery) async throws -> [SearchHit]
    public nonisolated func ftsOnly(_ q: SearchQuery, limit: Int) throws -> [SearchHit]   // sync, main-actor safe under 50 ms budget
}
```

**Isolation.** Actor. Serializes searches so a fast typist does not fan out ten concurrent embeddings; each call checks `Task.isCancelled` between stages, and `SearchModel` cancels the previous task per keystroke. **Errors.** `SearchError.invalidQuery`, `.indexUnavailable` (FTS table missing — only during migration), `.cancelled`. A semantic failure is *not* thrown: the result simply lacks `.semantic` in `sources`.

```swift
// Success path
let hits = try await HybridSearch.shared.search(SearchQuery(text: "from:mail after:-7d receipt", limit: 50))
let rows = try await Archive.shared.notifications(ids: hits.map(\.notificationID))

// Error path
do {
    _ = try await HybridSearch.shared.search(SearchQuery(text: "before:soon"))
} catch SearchError.invalidQuery(let reason) {
    searchBar.showInlineError(reason)          // no alert, no log of the query text
}
```

Latency budgets are FTS p95 < 50 ms and hybrid p95 < 250 ms at 100k notifications; see [PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md).

## Public API Stability Policy

The four packages are versioned **together, and independently from the app**. The app follows its own semver (`1.0.0` is the first release target, `CHANGELOG.md` currently at `[0.1.0]`); the packages carry one shared version tagged `packages/vX.Y.Z` in the same repository. Nothing outside this repository depends on the packages today, so the policy is written for contributors and for the day someone does.

| Rule | Detail |
|---|---|
| One version for all four packages | `BackglanceCore`, `BackglanceCapture`, `BackglanceSearch`, `BackglanceUI` bump in lockstep; the tag is `packages/v0.1.0`, `packages/v0.2.0`, … The number lives in `Packages/VERSION` and is read by `Scripts/build.sh`. |
| Packages start at `0.1.0` and stay `0.x` through app 1.0 | While `0.x`: a **minor** bump may break Stable APIs, but every break is listed under a `### Breaking (packages)` heading in `CHANGELOG.md`; a **patch** bump never breaks. |
| Packages reach `1.0.0` when the app ships its first v1.x minor | At that point Stable symbols are frozen: breaks require a package **major** bump. Evolving symbols still may change in a minor. Internal symbols may change anywhere. |
| App version does not imply package version | App `1.0.3` may ship packages `0.3.1`. The relation is recorded per release in `CHANGELOG.md`. |
| Deprecation before removal | Anything Stable is marked `@available(*, deprecated, message:)` for at least one minor before removal, with the replacement named in the message. |
| Adapters are exempt from the freeze | `StoreAdapterV14/15/26` follow Apple, not semver. Adding, retiring or rewriting an adapter is a patch or minor change and is documented in [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md). |
| Archive schema is versioned separately | `schema_meta.archive_version` advances with GRDB migrations (`v1_initial` … `v6_sync_metadata`). Migrations are forward-only; a package bump that adds a migration is a **minor**. See [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md). |
| Automation surfaces | `backglance://` routes marked Stable follow the **app** version: no route is removed or changed in meaning without an app major bump. New parameters may be added in a minor. |

The stability level of each symbol is the one printed in this document; when this document and a source doc-comment disagree, the source wins and this file has a bug — open an issue.

> 💡 **Tip:** If you are writing code inside the repository, prefer Stable symbols and wrap Evolving ones behind your own small protocol. If you are copying a package into another project (GPL-3.0 applies), pin the `packages/vX.Y.Z` tag.

## Next Steps

- Read [ARCHITECTURE.md](../architecture/ARCHITECTURE.md) for how these APIs fit together at runtime and the full `CaptureEngine` listing.
- Follow [DEVELOPMENT_GUIDE.md](../getting-started/DEVELOPMENT_GUIDE.md) to build the packages and run `Backglance.xctestplan`.
- Adding macOS support? The adapter template is in [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md).
- Automating from Shortcuts is a v1.x item; track it in [ROADMAP.md](../reference/ROADMAP.md).

## Related Documentation

- [ARCHITECTURE.md](../architecture/ARCHITECTURE.md) — module boundaries, `CaptureEngine` loop, error handling patterns
- [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md) — archive DDL and migrations
- [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md) — writing and verifying a `StoreAdapter`
- [EXPORT_AUTOMATION.md](../features/EXPORT_AUTOMATION.md) — full `URLSchemeHandler`, `ExportService` and intents listings
- [SEARCH.md](../features/SEARCH.md) — search UX and query language from the user's side
- [CAPTURE.md](../features/CAPTURE.md) — capture behavior, degraded mode, import
- [PRIVACY_CONTROLS.md](../features/PRIVACY_CONTROLS.md) — OTP redaction, exclusion list, panic wipe from the user's side
- [RULES.md](../features/RULES.md) — rule kinds and the visual-triage boundary
- [MISSED_DIGEST.md](../features/MISSED_DIGEST.md) — away sessions and digest thresholds
- [SNOOZE_RESURFACE.md](../features/SNOOZE_RESURFACE.md) — `SnoozeNotificationIntent`
- [PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md) — search and capture budgets
- [TESTING.md](../testing/TESTING.md) — in-memory archive, fixtures, intent tests
- [SECURITY.md](../security/SECURITY.md) — threat model behind the "no destructive routes" rule
- [DEVELOPMENT_GUIDE.md](../getting-started/DEVELOPMENT_GUIDE.md) — building and running the packages
- [CONTRIBUTING.md](../contributing/CONTRIBUTING.md) — how API changes and CHANGELOG entries are reviewed
- [CHANGELOG.md](../../CHANGELOG.md) — package and app version history
