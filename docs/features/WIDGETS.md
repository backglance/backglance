# WidgetKit Widgets

Last Updated: 2026-08-18

> ℹ️ **Status:** Planned for v1.x — not in v1.0.

This document describes Backglance's two desktop/Notification Center widgets, built as a WidgetKit extension called `BackglanceWidgets`: **"Today's notification load"** (a count plus an hour-by-hour sparkline) and **"Missed while away"** (the count from the latest undismissed digest, deep-linking to `backglance://digest`). The design constraint that shapes everything: the widget extension never opens the archive. It reads one small JSON summary file the app writes into a shared App Group container.

## Table of Contents

- [Feature Overview](#feature-overview)
- [Architecture](#architecture)
- [The Summary File](#the-summary-file)
- [Archive Tables Involved](#archive-tables-involved)
- [Privacy Defaults](#privacy-defaults)
- [Business Logic](#business-logic)
- [UI Components](#ui-components)
- [Signing and Entitlements](#signing-and-entitlements)
- [Edge Cases and Error Handling](#edge-cases-and-error-handling)
- [Testing Approach](#testing-approach)
- [Related Documentation](#related-documentation)

## Feature Overview

| Widget | Kind | Families | Shows | Tap |
|---|---|---|---|---|
| Today's notification load | `TodayLoadWidget` | `.systemSmall`, `.systemMedium` | today's count + sparkline by hour (medium adds top app names if enabled) | opens the timeline window |
| Missed while away | `MissedWidget` | `.systemSmall` | item count of the latest **undismissed** digest, or a quiet checkmark | `backglance://digest` |

Both widgets show **counts only** by default — no titles, no bodies, no senders. Widgets render on the desktop and in Notification Center, places a passer-by can see; the archive's content stays in the app.

## Architecture

```
 ┌──────────────────────────────────────────┐
 │ Backglance.app (not sandboxed)           │
 │                                          │
 │  Archive (archive.sqlite) ── stays here  │
 │      │                                   │
 │      ▼                                   │
 │  WidgetSummaryWriter (BackglanceCore)    │
 │   - on digest creation                   │
 │   - on capture batch commit (coalesced,  │
 │     at most every 5 min)                 │
 │      │  atomic write                     │
 │      ▼                                   │
 │  ~/Library/Group Containers/             │
 │    group.app.backglance.shared/          │
 │      widget-summary.json   (≤ 2 KB)      │
 │      │                                   │
 │  WidgetCenter.shared.reloadTimelines ────┼──▶ WidgetKit
 └──────┼───────────────────────────────────┘
        │ read-only
 ┌──────▼───────────────────────────────────┐
 │ BackglanceWidgets.appex (IS sandboxed)   │
 │  SummaryProvider (TimelineProvider)      │
 │   - decode widget-summary.json           │
 │   - policy .after(now + 15 min)          │
 │  TodayLoadWidget / MissedWidget views    │
 └──────────────────────────────────────────┘
```

Two facts make this shape necessary and sufficient:

1. **The extension never opens the archive.** No GRDB in the widget target, no second process holding the SQLite file, no schema coupling. The extension's only input is one small file.
2. **The extension IS sandboxed** — WidgetKit extensions must be, and that is fine here, because it only reads the group container it is entitled to. The main app is not sandboxed (see [PERMISSIONS_PRIVACY.md](./PERMISSIONS_PRIVACY.md)); it simply adds the same App Group entitlement so both sides resolve `group.app.backglance.shared`.

## The Summary File

`widget-summary.json` in the App Group container, written atomically (`.atomic`) so the widget never reads a half-written file:

```json
{
  "version": 1,
  "generatedAt": 1786726800,
  "todayTotal": 47,
  "hourlyCounts": [0,0,0,0,0,0,1,3,6,9,7,4,2,5,4,3,2,1,0,0,0,0,0,0],
  "missedCount": 12,
  "missedDigestCreatedAt": 1786719600,
  "topApps": null
}
```

`topApps` is `null` unless the user enables "Show app names in widgets"; then it carries up to three `{ "name": "Slack", "count": 18 }` entries — names and counts, still no content.

```swift
import Foundation

public struct WidgetSummary: Codable, Equatable, Sendable {
    public var version: Int
    public var generatedAt: Date               // Unix seconds via custom coding below
    public var todayTotal: Int
    public var hourlyCounts: [Int]             // exactly 24 buckets, local time
    public var missedCount: Int                // 0 when latest digest is dismissed
    public var missedDigestCreatedAt: Date?
    public var topApps: [TopApp]?

    public struct TopApp: Codable, Equatable, Sendable {
        public var name: String
        public var count: Int
    }

    public static let currentVersion = 1

    public static func containerURL() throws -> URL {
        guard let base = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.app.backglance.shared") else {
            throw WidgetSummaryError.noGroupContainer
        }
        return base.appendingPathComponent("widget-summary.json")
    }
}

public enum WidgetSummaryError: Error, Equatable {
    case noGroupContainer          // entitlement missing or profile mismatch
    case unsupportedVersion(Int)
    case malformed(String)
}
```

Dates are encoded with `JSONEncoder.dateEncodingStrategy = .secondsSince1970` to match the archive's Unix-seconds convention.

## Archive Tables Involved

The **app side** computes the summary from:

| Table | Used for |
|---|---|
| `notifications` | `todayTotal`, `hourlyCounts` (same `strftime('%H', delivered_at, 'unixepoch', 'localtime')` bucketing as [ANALYTICS.md](./ANALYTICS.md), restricted to today) |
| `digests` | latest row with `dismissed_at IS NULL` → `missedCount = item_count`, `missedDigestCreatedAt = created_at` |
| `apps` | `topApps` names, only when the setting is on |

The widget side touches no tables at all.

## Privacy Defaults

> 🔒 **Security:** default widget content is numbers. Adding app names is opt-in (Settings ▸ Widgets ▸ "Show app names in widgets"), and there is deliberately no option to show titles or bodies — a widget is visible in screen shares and photos of a desk, and no setting should make the archive's content ambient. Excluded apps never appear in `topApps` regardless of the toggle.

The summary file also honors pause and wipe: pausing capture stops updates (widgets show the "as of" time drifting), and `PanicWipe` deletes `widget-summary.json` and reloads timelines so widgets fall back to their placeholder immediately.

## Business Logic

App side — writing the summary and nudging WidgetKit:

```swift
import Foundation
import WidgetKit

public struct WidgetSummaryWriter {
    let archive: Archive
    let includeAppNames: Bool

    /// Called after digest creation and on coalesced capture commits (max once / 5 min).
    public func writeAndReload() async {
        do {
            let summary = try await buildSummary()
            let data = try JSONEncoder.unixSeconds.encode(summary)
            try data.write(to: try WidgetSummary.containerURL(), options: .atomic)
            WidgetCenter.shared.reloadTimelines(ofKind: "TodayLoadWidget")
            WidgetCenter.shared.reloadTimelines(ofKind: "MissedWidget")
        } catch WidgetSummaryError.noGroupContainer {
            // Build without the entitlement (e.g. source build with a free team): widgets just stay empty.
            Log.widgets.notice("No App Group container; skipping widget summary")
        } catch {
            Log.widgets.error("Widget summary write failed: \(error.localizedDescription)")
        }
    }

    func buildSummary() async throws -> WidgetSummary {
        try await archive.pool.read { db in
            let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
            let rows = try Row.fetchAll(db, sql: """
                SELECT CAST(strftime('%H', delivered_at, 'unixepoch', 'localtime') AS INTEGER) AS hour,
                       COUNT(*) AS total
                FROM notifications
                WHERE delivered_at >= ? AND is_deleted = 0
                GROUP BY hour
                """, arguments: [startOfDay])
            var hourly = [Int](repeating: 0, count: 24)
            for row in rows { hourly[row["hour"]] = row["total"] }

            let digest = try Row.fetchOne(db, sql: """
                SELECT item_count, created_at FROM digests
                WHERE dismissed_at IS NULL ORDER BY created_at DESC LIMIT 1
                """)
            return WidgetSummary(version: WidgetSummary.currentVersion,
                                 generatedAt: Date(),
                                 todayTotal: hourly.reduce(0, +),
                                 hourlyCounts: hourly,
                                 missedCount: digest?["item_count"] ?? 0,
                                 missedDigestCreatedAt: digest.map { Date(timeIntervalSince1970: $0["created_at"]) },
                                 topApps: nil) // filled by a second query when includeAppNames
        }
    }
}
```

Widget side — the timeline provider (success and failure both produce an entry; a widget must always render something):

```swift
import WidgetKit
import SwiftUI

struct SummaryEntry: TimelineEntry {
    let date: Date
    let summary: WidgetSummary?      // nil = no file yet (app not set up) or unreadable
    let stale: Bool                  // generatedAt older than 2 h
}

struct SummaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> SummaryEntry {
        SummaryEntry(date: .now, summary: .preview, stale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (SummaryEntry) -> Void) {
        completion(context.isPreview
                   ? SummaryEntry(date: .now, summary: .preview, stale: false)
                   : loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SummaryEntry>) -> Void) {
        let entry = loadEntry()
        // The app reloads timelines on digest creation; .after(15 min) is the fallback
        // so the "as of" time never drifts far even if the app is quiet.
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
    }

    private func loadEntry() -> SummaryEntry {
        do {
            let url = try WidgetSummary.containerURL()
            let data = try Data(contentsOf: url)
            let summary = try JSONDecoder.unixSeconds.decode(WidgetSummary.self, from: data)
            guard summary.version <= WidgetSummary.currentVersion else {
                throw WidgetSummaryError.unsupportedVersion(summary.version)
            }
            let stale = Date().timeIntervalSince(summary.generatedAt) > 2 * 3600
            return SummaryEntry(date: .now, summary: summary, stale: stale)
        } catch {
            // Missing file (fresh install, widget added before onboarding) or bad JSON:
            // render the "open Backglance" state instead of crashing the extension.
            return SummaryEntry(date: .now, summary: nil, stale: false)
        }
    }
}

extension WidgetSummary {
    static let preview = WidgetSummary(version: 1, generatedAt: .now, todayTotal: 47,
                                       hourlyCounts: [0,0,0,0,0,0,1,3,6,9,7,4,2,5,4,3,2,1,0,0,0,0,0,0],
                                       missedCount: 12, missedDigestCreatedAt: .now, topApps: nil)
}
```

## UI Components

```swift
import WidgetKit
import SwiftUI

struct TodayLoadWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodayLoadWidget", provider: SummaryProvider()) { entry in
            TodayLoadView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Today's notification load")
        .description("How many notifications arrived today, hour by hour.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TodayLoadView: View {
    let entry: SummaryEntry

    var body: some View {
        if let summary = entry.summary {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(summary.todayTotal)").font(.system(.title, design: .rounded).bold())
                Text("notifications today").font(.caption).foregroundStyle(.secondary)
                Sparkline(values: summary.hourlyCounts)
                    .frame(height: 24)
                    .accessibilityLabel("Hourly notification counts")
                if entry.stale {
                    Text("as of \(summary.generatedAt, style: .time)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(spacing: 4) {
                Image(systemName: "bell.badge")
                Text("Open Backglance to start").font(.caption).multilineTextAlignment(.center)
            }.foregroundStyle(.secondary)
        }
    }
}

struct Sparkline: View {
    let values: [Int]
    var body: some View {
        GeometryReader { geo in
            let maxValue = max(values.max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(values.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .frame(height: max(2, geo.size.height * CGFloat(values[i]) / CGFloat(maxValue)))
                }
            }
        }
    }
}

struct MissedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MissedWidget", provider: SummaryProvider()) { entry in
            MissedView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(URL(string: "backglance://digest"))   // tap opens the digest
        }
        .configurationDisplayName("Missed while away")
        .description("Notifications from your latest digest you haven't looked at yet.")
        .supportedFamilies([.systemSmall])
    }
}

struct MissedView: View {
    let entry: SummaryEntry
    var body: some View {
        if let summary = entry.summary, summary.missedCount > 0 {
            VStack(spacing: 4) {
                Text("\(summary.missedCount)").font(.system(.largeTitle, design: .rounded).bold())
                Text("missed while away").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 4) {
                Image(systemName: "checkmark.circle")
                Text("All caught up").font(.caption)
            }.foregroundStyle(.secondary)
        }
    }
}

@main
struct BackglanceWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TodayLoadWidget()
        MissedWidget()
    }
}
```

`.systemMedium` of `TodayLoadView` adds a right-hand column with `topApps` when present; otherwise the sparkline stretches.

## Signing and Entitlements

- New target `BackglanceWidgets` under `Widgets/` in the project (see the repository layout in [ARCHITECTURE.md](../architecture/ARCHITECTURE.md)); bundle id `app.backglance.Backglance.BackglanceWidgets`, embedded in the app at `Contents/PlugIns/`.
- **Both** targets get the App Group entitlement:

```xml
<key>com.apple.security.application-groups</key>
<array>
  <string>group.app.backglance.shared</string>
</array>
```

- The extension additionally has `com.apple.security.app-sandbox = true` (required for extensions; the main app stays unsandboxed — Full Disk Access and App Sandbox don't mix, which is also why Backglance is not on the Mac App Store).
- `sign_and_notarize.sh` signs inside-out: the `.appex` first, then the app; both with the Developer ID identity `"Developer ID Application: Backglance (TEAMID1234)"`, hardened runtime on. Notarization covers the nested extension automatically (see [PACKAGING_NOTARIZATION.md](../deployment/PACKAGING_NOTARIZATION.md)).

> ⚠️ **Warning:** for Developer ID (non-App-Store) distribution the App Group identifier is not brokered by App Store Connect; macOS 15+ shows a one-time consent prompt when unrelated-looking processes share a group. Using a group prefixed with the team identifier (`TEAMID1234.group.app.backglance.shared`) avoids the prompt; the docs and code use the short form and the release script rewrites it to the team-prefixed form at signing time. Verified per release in [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md).

## Edge Cases and Error Handling

| Case | Behavior |
|---|---|
| App not running for hours | Summary goes stale; widget keeps rendering it and shows "as of 14:05" once older than 2 h. |
| Widget added before onboarding / first launch | No summary file → "Open Backglance to start" placeholder state. |
| Group container unavailable (source build, free team) | App logs and skips writing; widgets stay in the placeholder state. |
| Corrupt or truncated JSON | Decoder throws → placeholder state; the app rewrites the file on its next update. Atomic writes make this rare. |
| Version from a newer app | `unsupportedVersion` → placeholder; the widget never guesses at fields. |
| Midnight rollover | `hourlyCounts` are "today"; the 15-min refresh naturally resets the sparkline shortly after midnight. |
| Digest dismissed in the app | App rewrites summary with `missedCount = 0` and reloads timelines → "All caught up". |
| Capture paused / panic wipe | Paused: file stops updating (stale label). Wipe: file deleted, timelines reloaded, placeholder state. |
| WidgetKit budget | `.after(15 min)` plus event-driven reloads stays far under the system's refresh budget. |

## Testing Approach

- **`WidgetSummaryTests`** (`BackglanceCoreTests`): `WidgetSummary` encode→decode round-trip, `secondsSince1970` dates, exactly 24 `hourlyCounts`, `topApps` nil vs populated.
- **Writer:** `buildSummary()` against `Archive(inMemory: true)` seeded with notifications across today and yesterday plus one undismissed digest; assert only today's rows are counted and `missedCount` matches `item_count`; dismiss the digest and assert `missedCount == 0`.
- **Provider:** point `WidgetSummary.containerURL` at a temp directory via a test seam (`static var containerOverride: URL?`); table tests for missing file, corrupt JSON, `version: 99`, stale `generatedAt` → assert the entry's `summary`/`stale` flags.
- **Views:** Xcode previews for every state (normal, stale, empty, all-caught-up) via `SummaryProvider.placeholder` data; snapshot review is manual — widget rendering differs per macOS.
- **Integration (manual checklist per release):** add both widgets, create a digest (lock the Mac ≥ 5 min with pending notifications), confirm the reload lands without waiting 15 min, and confirm the `backglance://digest` tap opens the digest window.

## Related Documentation

- [MISSED_DIGEST.md](./MISSED_DIGEST.md) — where digests come from; the reload trigger
- [ANALYTICS.md](./ANALYTICS.md) — the same hourly bucketing, computed over longer windows
- [PERMISSIONS_PRIVACY.md](./PERMISSIONS_PRIVACY.md) — why the app is unsandboxed while the extension is sandboxed
- [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md) — counts-only default, excluded apps, wipe behavior
- [EXPORT_AUTOMATION.md](./EXPORT_AUTOMATION.md) — the `backglance://digest` URL route
- [ARCHITECTURE.md](../architecture/ARCHITECTURE.md) — targets and module layout
- [PACKAGING_NOTARIZATION.md](../deployment/PACKAGING_NOTARIZATION.md) — signing the nested `.appex`
- [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md) — App Group consent behavior per macOS
- [TESTING.md](../testing/TESTING.md)
- [ROADMAP.md](../reference/ROADMAP.md)
