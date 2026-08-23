# Export & Automation

Last Updated: 2026-08-18

> ℹ️ **Status:** Planned for v1.x — not in v1.0.

This document describes how Backglance gets notifications *out* of the archive (CSV/JSON export, date-range export, streaming writes) and how other tools can drive Backglance (the `backglance://` URL scheme and Shortcuts App Intents). The archive is the user's data; export exists so nothing is ever locked in, and automation exists so the archive can feed the user's own scripts and Shortcuts without Backglance ever talking to a network.

## Table of Contents

- [Feature Overview](#feature-overview)
- [Architecture](#architecture)
- [Archive Tables Involved](#archive-tables-involved)
- [Export Formats](#export-formats)
- [What Is Never Exported](#what-is-never-exported)
- [UI Components](#ui-components)
- [Business Logic](#business-logic)
- [URL Scheme](#url-scheme)
- [Shortcuts (App Intents)](#shortcuts-app-intents)
- [AppleScript](#applescript)
- [Edge Cases and Error Handling](#edge-cases-and-error-handling)
- [Testing Approach](#testing-approach)
- [Related Documentation](#related-documentation)

## Feature Overview

| Capability | v1.0 | v1.x |
|---|---|---|
| Export selected notifications (CSV/JSON) from the timeline | ✅ (see [ACTIONS.md](./ACTIONS.md)) | ✅ |
| Date-range export from Settings ▸ Export (`ExportSheet`) | — | ✅ |
| Streaming write for large archives (100k rows) | — | ✅ |
| `backglance://search`, `open`, `digest`, `pause`, `resume` | ✅ | ✅ |
| `backglance://export?from=&to=&format=` | — | ✅ (always confirms) |
| Shortcuts App Intents + `NotificationEntity` | — | ✅ |
| AppleScript dictionary | — | ❌ not planned |

Everything here is local. Export writes to a file the user chooses; the URL scheme and intents run in-process; nothing leaves the Mac.

## Architecture

```
                 ┌──────────────────────────────────────────────┐
                 │  Backglance.app (not sandboxed, LSUIElement)  │
                 │                                              │
  Shortcuts ───▶ │  App Intents ──┐                             │
  (in-process)   │                │                             │
                 │  URLSchemeHandler ─┐                         │
  open backglance://…              │                            │
  (NSAppleEventManager kAEGetURL)  ▼                            │
                 │        ┌──────────────────┐   ┌──────────┐  │
                 │        │ ExportCoordinator │──▶│ExportSheet│ │  (always a UI
                 │        │  (confirm + save) │   └──────────┘  │   confirmation)
                 │        └────────┬─────────┘                  │
                 │                 ▼                            │
                 │        ┌──────────────────┐   BackglanceCore │
                 │        │  ExportService   │  (streams rows   │
                 │        │  CSVWriter/JSON  │   via GRDB cursor)│
                 │        └────────┬─────────┘                  │
                 └─────────────────┼────────────────────────────┘
                                   ▼
                     ~/Downloads/Backglance-export-2026-08-17.csv
```

`ExportService` lives in `BackglanceCore` (pure logic, testable against `Archive(inMemory: true)`). `ExportCoordinator` and `ExportSheet` live in the app target / `BackglanceUI`; they own the confirmation and the `NSSavePanel`. `URLSchemeHandler` (in `Backglance/App/`) and the intents call the coordinator — never `ExportService` directly — so every export path goes through the same confirmation.

## Archive Tables Involved

| Table | Use |
|---|---|
| `notifications` | rows to export; filtered by `delivered_at` range, `is_deleted = 0` |
| `apps` | joined for `bundle_id` and `display_name` |
| `away_sessions` | `away_session_id IS NOT NULL` → `missed = true` |
| `redactions` | not read directly; `notifications.redaction` already carries `'otp'` |

Only reads. Export never writes to the archive.

## Export Formats

### `ExportedNotification` schema

Both formats serialize the same `Codable` struct. Column order in CSV equals the field order below.

| Field | Type | Source | Notes |
|---|---|---|---|
| `uuid` | string | `notifications.uuid` | stable identifier, also used by `backglance://open?id=` |
| `app_bundle_id` | string | `apps.bundle_id` | |
| `app_name` | string? | `apps.display_name` | may be empty if the app was never resolved |
| `title` | string? | `notifications.title` | |
| `subtitle` | string? | `notifications.subtitle` | |
| `body` | string? | `notifications.body` | already redacted when `redacted = true` |
| `sender` | string? | `notifications.sender` | |
| `delivered_at` | string | `notifications.delivered_at` | ISO 8601 **with UTC offset**, e.g. `2026-08-17T09:14:03+03:00` |
| `presented` | bool | `notifications.presented` | store's own "banner was shown" flag |
| `missed` | bool | `away_session_id IS NOT NULL` | delivered during an away session |
| `redacted` | bool | `notifications.redaction != 'none'` | |
| `deep_link` | string? | `notifications.deep_link` | |
| `attachments` | array | `notifications.attachments_json` | **metadata only** (`type`, `name`, `size`); never bytes |

```swift
// BackglanceCore/Export/ExportedNotification.swift
public struct ExportedNotification: Codable, Equatable, Sendable {
    public var uuid: String
    public var appBundleID: String
    public var appName: String?
    public var title: String?
    public var subtitle: String?
    public var body: String?
    public var sender: String?
    public var deliveredAt: String       // ISO 8601 with offset, local time zone
    public var presented: Bool
    public var missed: Bool
    public var redacted: Bool
    public var deepLink: String?
    public var attachments: [AttachmentMeta]

    enum CodingKeys: String, CodingKey {
        case uuid
        case appBundleID = "app_bundle_id"
        case appName = "app_name"
        case title, subtitle, body, sender
        case deliveredAt = "delivered_at"
        case presented, missed, redacted
        case deepLink = "deep_link"
        case attachments
    }
}
```

### CSV (RFC 4180)

A small writer, no dependency. Rules: fields containing `,`, `"`, `\r` or `\n` are quoted; quotes are doubled; line ending is `\r\n`; header row first; UTF-8 without BOM (a setting "Add BOM for Excel" toggles a leading `\u{FEFF}`).

```swift
// BackglanceCore/Export/CSVWriter.swift
public struct CSVWriter {
    public var protectFormulas: Bool = true   // CSV-injection guard, on by default

    public func row(_ fields: [String?]) -> String {
        fields.map { escape($0 ?? "") }.joined(separator: ",") + "\r\n"
    }

    func escape(_ raw: String) -> String {
        var s = raw
        // Spreadsheet formula injection: a cell starting with = + - @ (or tab/CR)
        // would be evaluated by Excel/Numbers. Prefix with an apostrophe.
        if protectFormulas, let first = s.first, "=+-@\t\r".contains(first) {
            s = "'" + s
        }
        let needsQuoting = s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r")
        guard needsQuoting else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
```

### JSON

A single top-level array of `ExportedNotification` objects, `snake_case` keys, pretty-printed with sorted keys (diff-friendly). Written incrementally: `[` , then each element encoded on its own, joined by `,\n`, then `]` — so a 100k-row export never holds the whole array in memory.

## What Is Never Exported

- Nothing from the **system store** — export reads only the archive.
- Redacted content stays redacted: the placeholder `[code redacted]` is what gets written; the original digits were never stored, so there is nothing else to export.
- Notifications from excluded apps (they were never archived).
- Soft-deleted rows (`is_deleted = 1`).
- Logs, capture state, rules, settings, embeddings, digests. (Rules and saved searches have their own JSON export — see [RULES.md](./RULES.md) and [SAVED_SEARCHES.md](./SAVED_SEARCHES.md).)
- Attachment bytes — the archive never had them; only `attachments_json` metadata is included.

> 🔒 **Security:** an export file is plaintext and lives outside Backglance's `0700` directory. The `ExportSheet` says so once ("This file will contain notification text in plain text.") and the default location is `~/Downloads`. See [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md).

## UI Components

| Component | Where | Purpose |
|---|---|---|
| `ExportSheet` (SwiftUI, `BackglanceUI`) | Settings ▸ Export, and from `backglance://export` | date range (presets: Today, Last 7 days, Last 30 days, All, Custom), format picker, app filter (optional), "Include redaction placeholders" (always on, informational), estimated row count, **Export…** button |
| Timeline selection → **Export Selection…** | `TimelineWindow` toolbar/context menu | v1.0 subset; calls the same `ExportService` with an explicit id list ([ACTIONS.md](./ACTIONS.md)) |
| `NSSavePanel` | app target | Backglance is not sandboxed, so a plain `NSSavePanel` is used; no security-scoped bookmarks are needed. Suggested name `Backglance-export-2026-08-17.csv` (`yyyy-MM-dd` of the export day, extension follows the format) |
| Progress overlay | inside `ExportSheet` | rows written / estimated, Cancel button; shown only if the export takes > 400 ms |

## Business Logic

```swift
// BackglanceCore/Export/ExportService.swift
import Foundation
import GRDB

public enum ExportFormat: String, CaseIterable, Sendable { case csv, json }

public struct ExportRequest: Sendable {
    public var from: Date
    public var to: Date
    public var format: ExportFormat
    public var bundleIDs: Set<String>? = nil     // nil = all apps
    public var notificationIDs: [Int64]? = nil    // non-nil = selection export

    public init(from: Date, to: Date, format: ExportFormat) {
        self.from = from; self.to = to; self.format = format
    }
}

public enum ExportError: Error, LocalizedError, Equatable {
    case invalidRange
    case rangeTooLarge(days: Int)
    case cancelled
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRange:            return "The start date must be before the end date."
        case .rangeTooLarge(let d):    return "Ranges above \(d) days are exported as multiple files."
        case .cancelled:               return "Export cancelled."
        case .io(let msg):             return "Couldn't write the export file: \(msg)"
        }
    }
}

public final class ExportService: Sendable {
    private let archive: Archive
    public init(archive: Archive) { self.archive = archive }

    /// Streams rows into `url`. Never materialises the whole result set.
    /// `progress` is called on the calling task roughly every 500 rows.
    public func export(_ request: ExportRequest,
                       to url: URL,
                       progress: (@Sendable (Int) -> Void)? = nil) async throws -> Int {
        guard request.from < request.to else { throw ExportError.invalidRange }

        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw ExportError.io("cannot open \(url.lastPathComponent)")
        }
        defer { try? handle.close() }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let csv = CSVWriter()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]      // includes offset
        iso.timeZone = .current

        var written = 0
        do {
            if request.format == .csv {
                try handle.write(contentsOf: Data(csv.row(Self.csvHeader).utf8))
            } else {
                try handle.write(contentsOf: Data("[\n".utf8))
            }

            // GRDB cursor: rows are pulled one at a time from SQLite.
            try await archive.pool.read { db in
                let cursor = try Row.fetchCursor(db, sql: Self.sql(for: request),
                                                 arguments: Self.arguments(for: request))
                while let row = try cursor.next() {
                    try Task.checkCancellation()
                    let item = ExportedNotification(row: row, iso: iso)
                    let line: String
                    switch request.format {
                    case .csv:
                        line = csv.row(item.csvFields)
                    case .json:
                        let obj = String(decoding: try encoder.encode(item), as: UTF8.self)
                        line = (written == 0 ? "" : ",\n") + obj
                    }
                    try handle.write(contentsOf: Data(line.utf8))
                    written += 1
                    if written % 500 == 0 { progress?(written) }
                }
            }

            if request.format == .json { try handle.write(contentsOf: Data("\n]\n".utf8)) }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: url)   // never leave a partial file
            throw ExportError.cancelled
        } catch let e as ExportError {
            throw e
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.io(error.localizedDescription)   // e.g. ENOSPC "No space left on device"
        }
        return written
    }

    static let csvHeader: [String?] = ["uuid", "app_bundle_id", "app_name", "title", "subtitle", "body",
                                       "sender", "delivered_at", "presented", "missed", "redacted",
                                       "deep_link", "attachments"]

    static func sql(for r: ExportRequest) -> String {
        var sql = """
        SELECT n.uuid, a.bundle_id, a.display_name, n.title, n.subtitle, n.body, n.sender,
               n.delivered_at, n.presented, n.away_session_id, n.redaction, n.deep_link, n.attachments_json
        FROM notifications n JOIN apps a ON a.id = n.app_id
        WHERE n.is_deleted = 0 AND n.delivered_at >= :from AND n.delivered_at < :to
        """
        if r.notificationIDs != nil { sql += " AND n.id IN (SELECT value FROM json_each(:ids))" }
        if r.bundleIDs != nil { sql += " AND a.bundle_id IN (SELECT value FROM json_each(:bundles))" }
        return sql + " ORDER BY n.delivered_at ASC"
    }

    static func arguments(for r: ExportRequest) -> StatementArguments {
        var args: [String: DatabaseValueConvertible?] = [
            "from": r.from.timeIntervalSince1970,
            "to": r.to.timeIntervalSince1970,
        ]
        if let ids = r.notificationIDs { args["ids"] = jsonArray(ids.map(String.init)) }
        if let bundles = r.bundleIDs { args["bundles"] = jsonArray(Array(bundles)) }
        return StatementArguments(args)
    }

    static func jsonArray(_ values: [String]) -> String {
        String(decoding: try! JSONEncoder().encode(values), as: UTF8.self)
    }
}
```

Notes:

- The whole read runs inside one `pool.read` snapshot, so an export is consistent even while capture keeps inserting.
- The **selection export** (v1.0) is the same call with `notificationIDs` set; the date range is then `distantPast..<distantFuture`.
- Files are created `0600` and only in the location the user chose.

## URL Scheme

`CFBundleURLTypes` registers `backglance` in `Info.plist`. `URLSchemeHandler` is installed by `AppDelegate` via `NSAppleEventManager` for `kAEGetURL`. Routes:

| URL | Behavior | Since |
|---|---|---|
| `backglance://search?q=<urlencoded>` | opens the popover with the query filled in | v1.0 |
| `backglance://open?id=<uuid>` | reveals the notification in the timeline window | v1.0 |
| `backglance://digest` | shows the latest digest (or "nothing missed") | v1.0 |
| `backglance://pause?minutes=30` | pauses capture (`minutes` optional, 1…10080; omitted = indefinitely) | v1.0 |
| `backglance://resume` | resumes capture | v1.0 |
| `backglance://export?from=YYYY-MM-DD&to=YYYY-MM-DD&format=csv\|json` | **opens `ExportSheet` prefilled** — always a confirmation, never a silent write; default target `~/Downloads` | v1.x |

```swift
// Packages/BackglanceCore/Sources/BackglanceCore/Automation/URLRoute.swift
//
// The sketch below is the shape as first drafted, with `parse` hanging off
// `URLSchemeHandler` in the app target. As shipped, the route enum, the errors and
// `parse(_:)` are in `BackglanceCore` and only the `NSAppleEventManager` installation
// stayed behind in `Backglance/App/URLSchemeHandler.swift` — app-target code has no
// test host in this project, and the parser is where every bound in
// API_DOCUMENTATION.md#security-properties actually lives.
import Foundation

enum URLRoute: Equatable {
    case search(query: String)
    case open(uuid: UUID)
    case digest
    case pause(minutes: Int?)
    case resume
    case export(from: Date, to: Date, format: ExportFormat)
}

enum URLRouteError: Error, Equatable {
    case unknownHost(String)
    case missingParameter(String)
    case invalidParameter(String)
}

struct URLSchemeHandler {
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    static func parse(_ url: URL) throws -> URLRoute {
        guard url.scheme == "backglance", let host = url.host else {
            throw URLRouteError.unknownHost(url.absoluteString)
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        switch host {
        case "search":
            guard let q = value("q"), !q.isEmpty else { throw URLRouteError.missingParameter("q") }
            return .search(query: String(q.prefix(512)))          // bound query length
        case "open":
            guard let raw = value("id") else { throw URLRouteError.missingParameter("id") }
            guard let uuid = UUID(uuidString: raw) else { throw URLRouteError.invalidParameter("id") }
            return .open(uuid: uuid)
        case "digest":
            return .digest
        case "pause":
            guard let raw = value("minutes") else { return .pause(minutes: nil) }
            guard let m = Int(raw), (1...10_080).contains(m) else { throw URLRouteError.invalidParameter("minutes") }
            return .pause(minutes: m)
        case "resume":
            return .resume
        case "export":
            guard let f = value("from") else { throw URLRouteError.missingParameter("from") }
            guard let t = value("to") else { throw URLRouteError.missingParameter("to") }
            guard let from = dayFormatter.date(from: f) else { throw URLRouteError.invalidParameter("from") }
            guard let toDay = dayFormatter.date(from: t) else { throw URLRouteError.invalidParameter("to") }
            let format = ExportFormat(rawValue: value("format") ?? "csv") ?? .csv
            // `to` is inclusive for the user → end of that day.
            let to = Calendar.current.date(byAdding: .day, value: 1, to: toDay)!
            guard from < to else { throw URLRouteError.invalidParameter("from>to") }
            return .export(from: from, to: to, format: format)
        default:
            throw URLRouteError.unknownHost(host)
        }
    }

    /// Wired from AppDelegate: NSAppleEventManager kInternetEventClass / kAEGetURL.
    @MainActor
    static func handle(_ url: URL, app: AppCoordinator) {
        do {
            let route = try parse(url)
            app.perform(route)                                    // export → ExportSheet, never silent
        } catch {
            app.presentToast("Couldn't open link: \(error)")      // no crash, no partial action
            Log.automation.error("bad url route: \(error, privacy: .public)")   // no query content logged
        }
    }
}
```

The handler never logs the query string or notification content — only the failure kind.

## Shortcuts (App Intents)

App Intents are compiled into the app target. Backglance is a non-sandboxed menu bar app, so intents run **in-process** (the app is launched if needed) and can use `Archive.shared` directly.

> 🔒 **Security:** returning notification text to Shortcuts is the user's explicit choice — they build the shortcut and choose where the output goes. Backglance does nothing with the result. Redacted notifications come back redacted, exactly like the timeline shows them.

| Intent | Parameters | Returns |
|---|---|---|
| `SearchNotificationsIntent` | `query: String`, `limit: Int = 25`, `sinceDays: Int?` | `[NotificationEntity]` |
| `GetMissedDigestIntent` | — | `[NotificationEntity]` from the latest digest + dialog "You missed N notifications" |
| `ExportNotificationsIntent` | `from`, `to`, `format` | `IntentFile` (CSV/JSON) — shows the confirmation sheet first (`openAppWhenRun = true`) |
| `PauseCaptureIntent` | `minutes: Int?` | dialog |
| `SnoozeNotificationIntent` | `notification: NotificationEntity`, `until: Date` | dialog (see [SNOOZE_RESURFACE.md](./SNOOZE_RESURFACE.md)) |

```swift
// Backglance/Intents/NotificationEntity.swift
import AppIntents
import BackglanceCore

struct NotificationEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Notification"
    static var defaultQuery = NotificationEntityQuery()

    var id: String                    // uuid
    @Property(title: "App") var appName: String
    @Property(title: "Title") var title: String
    @Property(title: "Body") var body: String
    @Property(title: "Delivered At") var deliveredAt: Date
    @Property(title: "Missed") var missed: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(appName)")
    }

    init(_ n: ArchivedNotification, appName: String) {
        id = n.uuid.uuidString
        self.appName = appName
        title = n.title ?? ""
        body = n.body ?? ""            // already redacted if it was an OTP
        deliveredAt = n.deliveredAt
        missed = n.awaySessionID != nil
    }
}

struct NotificationEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [NotificationEntity] {
        let uuids = identifiers.compactMap(UUID.init(uuidString:))
        return try await Archive.shared.notifications(uuids: uuids)
            .map { NotificationEntity($0.notification, appName: $0.appName) }
    }
    func suggestedEntities() async throws -> [NotificationEntity] {
        try await Archive.shared.recentNotifications(limit: 10)
            .map { NotificationEntity($0.notification, appName: $0.appName) }
    }
}
```

```swift
// Backglance/Intents/SearchNotificationsIntent.swift
import AppIntents
import BackglanceCore
import BackglanceSearch

struct SearchNotificationsIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Notifications"
    static var description = IntentDescription("Searches the Backglance archive using the same query language as the app.")

    @Parameter(title: "Query") var query: String
    @Parameter(title: "Limit", default: 25, inclusiveRange: (1, 500)) var limit: Int
    @Parameter(title: "Only the last N days") var sinceDays: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Search notifications for \(\.$query)") { \.$limit; \.$sinceDays }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[NotificationEntity]> & ProvidesDialog {
        var q = query.trimmingCharacters(in: .whitespaces)
        if let d = sinceDays, d > 0 { q += " after:-\(d)d" }
        guard !q.isEmpty else {
            throw $query.needsValueError("What should Backglance search for?")
        }
        let hits = try await HybridSearch.shared.search(SearchQuery(text: q, limit: limit))
        let entities = try await Archive.shared.notifications(ids: hits.map(\.notificationID))
            .map { NotificationEntity($0.notification, appName: $0.appName) }
        let dialog: IntentDialog = entities.isEmpty
            ? "No notifications matched."
            : "Found \(entities.count) notification\(entities.count == 1 ? "" : "s")."
        return .result(value: entities, dialog: dialog)
    }
}
```

```swift
// Backglance/Intents/PauseCaptureIntent.swift
import AppIntents
import BackglanceCapture

struct PauseCaptureIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause Capture"
    @Parameter(title: "Minutes", inclusiveRange: (1, 10_080)) var minutes: Int?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let until = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
        await CaptureEngine.shared.pause(until: until)
        if let m = minutes { return .result(dialog: "Capture paused for \(m) minutes.") }
        return .result(dialog: "Capture paused until you resume it.")
    }
}
```

`ExportNotificationsIntent` sets `static var openAppWhenRun = true`, hands the request to `ExportCoordinator`, and returns an `IntentFile` only after the user pressed **Export…** in the sheet; if the sheet is dismissed it throws a `LocalizedError` "Export cancelled." so the shortcut stops cleanly.

## AppleScript

An AppleScript/JXA dictionary is **not planned**. The URL scheme covers scripting (`open "backglance://search?q=invoice"` from any language) and App Intents cover Shortcuts; a scripting definition would be a third surface to keep in sync for little gain.

## Edge Cases and Error Handling

| Case | Handling |
|---|---|
| Huge export (100k+ rows) | streamed via GRDB cursor; ~1 KB/row → ~100–150 MB file; progress overlay with Cancel; partial file removed on cancel |
| Disk full (`ENOSPC`) | write throws → `ExportError.io`, partial file removed, sheet shows the message and keeps the settings so the user can pick another volume |
| Invalid date range (`from ≥ to`) | `ExportError.invalidRange`; sheet disables **Export…** and shows inline text; URL route throws `invalidParameter("from>to")` |
| Range in the future / before first capture | allowed; result is simply 0 rows (sheet shows "Nothing to export for this range" and does not create a file) |
| Unicode | UTF-8 always; CSV quoting handles emoji, RTL, combining marks; JSON escapes per `JSONEncoder` |
| CSV injection | cells starting with `=`, `+`, `-`, `@`, tab or CR are prefixed with `'` (default on; a "Raw values" toggle in the sheet turns it off with an explanation) |
| Newlines in body | quoted per RFC 4180; JSON is unaffected |
| App renamed/uninstalled | `app_name` may be empty; `app_bundle_id` is always present |
| Redacted notification | exported with `[code redacted]` and `redacted = true` — no bypass exists |
| URL with unknown host / bad params | toast + log at `.error` (no content), nothing else happens |
| Intent run while archive is being wiped or migrated | `Archive` throws `ArchiveError.unavailable` → intent rethrows a `LocalizedError`; Shortcuts shows it |
| `backglance://export` while another export is running | second request is queued behind the sheet, not started in parallel |

## Testing Approach

- **Round-trip:** insert 1,000 synthetic notifications (seeded RNG, no real content) into `Archive(inMemory: true)`, export JSON, decode `[ExportedNotification]`, compare field by field; export CSV, parse with a tiny test-only CSV reader, compare.
- **CSV escaping:** table-driven tests for `CSVWriter.escape` — commas, quotes, CRLF, leading `=`/`+`/`-`/`@`, empty, emoji.
- **Streaming:** export 100k rows to a temp file and assert peak RSS delta < 30 MB (measured with `task_info` in a performance test, marked `XCTSkip` on CI runners without the budget).
- **Cancellation / disk full:** inject a `FileHandle` failure via a temporary read-only directory; assert `ExportError.io` and that no partial file remains.
- **URL parsing:** `URLRoute.parse` table tests (`URLRouteTests`, `BackglanceCoreTests`) for every route, including `minutes=0`, `minutes=abc`, `id=not-a-uuid`, `from=2026-13-40`, missing `q`, plus the refusals: a `file://` URL, another app's scheme, and any URL carrying a path.
- **Intents:** call `perform()` directly on `SearchNotificationsIntent` with an injected in-memory archive; assert entity ids and dialog text; `PauseCaptureIntent` asserts `CaptureStatus.paused(until:)`.
- **UI:** XCUITest for `ExportSheet` (preset → row estimate → save panel appears) on the `Backglance` scheme.

See [TESTING.md](../testing/TESTING.md) for the test plan layout.

## Related Documentation

- [ACTIONS.md](./ACTIONS.md) — v1.0 selection export and per-notification actions
- [SEARCH.md](./SEARCH.md) — query language used by `SearchNotificationsIntent`
- [SNOOZE_RESURFACE.md](./SNOOZE_RESURFACE.md) — `SnoozeNotificationIntent`
- [SAVED_SEARCHES.md](./SAVED_SEARCHES.md) — JSON export of saved searches and rules
- [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md) — redaction, exclusion, what a plaintext export means
- [API_DOCUMENTATION.md](../api/API_DOCUMENTATION.md) — `ExportService`, `URLSchemeHandler` signatures
- [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md) — `notifications`, `apps` tables
- [SECURITY.md](../security/SECURITY.md) — threat model
- [TESTING.md](../testing/TESTING.md)
- [ROADMAP.md](../reference/ROADMAP.md)
