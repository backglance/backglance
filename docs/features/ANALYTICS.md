# Notification Analytics

Last Updated: 2026-08-18

> ℹ️ **Status:** Planned for v1.x — not in v1.0.

This document describes Backglance's local notification analytics: which apps interrupt you most, when interruptions cluster during the week, how well Focus actually held back notifications, and a quiet weekly summary that suggests — never enforces — muting an app in System Settings. Everything is computed from the archive with plain SQL on the Mac. No data leaves the machine, and analytics can only see what retention has kept.

## Table of Contents

- [Feature Overview](#feature-overview)
- [Architecture](#architecture)
- [Archive Tables Involved](#archive-tables-involved)
- [Queries](#queries)
- [Business Logic](#business-logic)
- [UI Components](#ui-components)
- [Weekly Summary](#weekly-summary)
- [Retention Trade-off](#retention-trade-off)
- [Edge Cases and Error Handling](#edge-cases-and-error-handling)
- [Testing Approach](#testing-approach)
- [Related Documentation](#related-documentation)

## Feature Overview

| Report | What it answers | Window |
|---|---|---|
| Noisiest apps | Which apps sent the most notifications | last 7 / 30 days |
| Interruptions heatmap | Which hour × weekday cells are the busiest | last 30 days (rolling) |
| Focus effectiveness | During Focus away sessions, what share of notifications arrived with `presented = 0` (held back) vs `presented = 1` (broke through) | last 30 days |
| Weekly summary | One local notification with the top three apps and an optional "consider muting X in System Settings" suggestion | Sunday 18:00 by default, opt-in |

What analytics is **not**: it does not change system delivery, does not track anything Backglance did not already archive, and produces no data that is sent anywhere. The "report" wording is deliberate — the missed-summary is always called the *digest* (see [MISSED_DIGEST.md](./MISSED_DIGEST.md)); analytics produces *reports*.

## Architecture

```
  ┌──────────────────────────────────────────────────────────────┐
  │  Backglance.app                                              │
  │                                                              │
  │   AnalyticsView (SwiftUI, Charts) ◀── AnalyticsViewModel      │
  │        ▲  Settings ▸ Analytics tab / full window sidebar     │
  │        │                                                     │
  │   AnalyticsService (BackglanceCore, actor)                   │
  │     ├ topApps(days:)            ── SQL GROUP BY app_id       │
  │     ├ heatmap(days:)            ── SQL strftime buckets      │
  │     ├ focusEffectiveness(days:) ── SQL join away_sessions    │
  │     └ weeklySummary()           ── composes the three above  │
  │        │  read-only DatabasePool.read                        │
  │        ▼                                                     │
  │   Archive (archive.sqlite)                                   │
  │                                                              │
  │   WeeklySummaryScheduler ── UNUserNotificationCenter         │
  │        (Sunday 18:00, opt-in)   local notification           │
  │        tap ▶ backglance://analytics                          │
  │        "Open System Settings" action ▶ x-apple.systempreferences: │
  └──────────────────────────────────────────────────────────────┘
```

`AnalyticsService` lives in `BackglanceCore` so it can be unit-tested against `Archive(inMemory: true)`. It runs every query in `DatabasePool.read`, never writes, and never touches the system store.

## Archive Tables Involved

| Table | Columns used | Why |
|---|---|---|
| `notifications` | `app_id`, `delivered_at`, `presented`, `away_session_id`, `is_deleted` | counts, buckets, Focus split |
| `apps` | `id`, `bundle_id`, `display_name`, `is_muted`, `is_excluded` | labels and "already muted" suppression |
| `away_sessions` | `id`, `started_at`, `ended_at`, `reason` | Focus effectiveness (`reason = 'focus'`) |

Nothing is added to the schema for analytics; the reports are pure reads. `delivered_at` is stored as Unix seconds via the `UnixDate` wrapper (see [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md)), which is why the queries can pass it straight to `strftime(..., 'unixepoch', 'localtime')`.

## Queries

### Per-app counts, last 7 / 30 days

```sql
-- :since is Unix seconds (now - 7*86400 or now - 30*86400)
SELECT a.bundle_id,
       a.display_name,
       a.is_muted,
       COUNT(n.id)                    AS total,
       SUM(n.presented = 0)           AS held_back
FROM notifications n
JOIN apps a ON a.id = n.app_id
WHERE n.delivered_at >= :since
  AND n.is_deleted = 0
GROUP BY a.id
ORDER BY total DESC
LIMIT 20;
```

Uses `idx_notifications_app_delivered`. At 100k notifications this runs in a few milliseconds.

### Hour × weekday heatmap buckets

```sql
-- %w = weekday 0-6 (Sunday = 0), %H = hour 00-23, both in the Mac's local time zone
SELECT CAST(strftime('%w', delivered_at, 'unixepoch', 'localtime') AS INTEGER) AS weekday,
       CAST(strftime('%H', delivered_at, 'unixepoch', 'localtime') AS INTEGER) AS hour,
       COUNT(*) AS total
FROM notifications
WHERE delivered_at >= :since
  AND is_deleted = 0
GROUP BY weekday, hour;
```

The service fills the missing cells so the view always receives 7 × 24 = 168 buckets.

### Focus effectiveness (away-session overlaps)

```sql
-- notifications delivered while a Focus away session was open
SELECT SUM(n.presented = 0) AS held_back,
       SUM(n.presented = 1) AS broke_through
FROM notifications n
JOIN away_sessions s
  ON s.reason = 'focus'
 AND n.delivered_at >= s.started_at
 AND n.delivered_at <  COALESCE(s.ended_at, :now)
WHERE n.delivered_at >= :since
  AND n.is_deleted = 0;
```

> ⚠️ **Warning:** Focus detection itself is fragile (it watches `~/Library/DoNotDisturb/DB/Assertions.json`, see [MISSED_DIGEST.md](./MISSED_DIGEST.md)). If no Focus away sessions were recorded, this report shows "No Focus sessions recorded" rather than a misleading 0 %.

## Business Logic

```swift
import Foundation
import GRDB

public struct AppLoad: Codable, Hashable, Sendable {
    public let bundleID: String
    public let displayName: String?
    public let isMuted: Bool
    public let total: Int
    public let heldBack: Int
}

public struct HeatmapCell: Hashable, Sendable {
    public let weekday: Int   // 0 = Sunday … 6 = Saturday
    public let hour: Int      // 0 … 23
    public let total: Int
}

public struct FocusEffectiveness: Sendable {
    public let heldBack: Int
    public let brokeThrough: Int
    /// nil when there were no Focus sessions with notifications in the window
    public var heldBackShare: Double? {
        let all = heldBack + brokeThrough
        return all == 0 ? nil : Double(heldBack) / Double(all)
    }
}

public enum AnalyticsError: Error, Equatable {
    case archiveUnavailable
    case invalidWindow(days: Int)
}

public actor AnalyticsService {
    private let archive: Archive
    private let now: () -> Date

    public init(archive: Archive = .shared, now: @escaping () -> Date = Date.init) {
        self.archive = archive
        self.now = now
    }

    public func topApps(days: Int, limit: Int = 20) async throws -> [AppLoad] {
        guard days > 0 else { throw AnalyticsError.invalidWindow(days: days) }
        let since = now().timeIntervalSince1970 - Double(days) * 86_400
        return try await archive.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.bundle_id, a.display_name, a.is_muted,
                       COUNT(n.id) AS total, SUM(n.presented = 0) AS held_back
                FROM notifications n JOIN apps a ON a.id = n.app_id
                WHERE n.delivered_at >= ? AND n.is_deleted = 0
                GROUP BY a.id ORDER BY total DESC LIMIT ?
                """, arguments: [since, limit]).map { row in
                AppLoad(bundleID: row["bundle_id"],
                        displayName: row["display_name"],
                        isMuted: row["is_muted"],
                        total: row["total"],
                        heldBack: row["held_back"] ?? 0)
            }
        }
    }

    public func heatmap(days: Int = 30) async throws -> [HeatmapCell] {
        guard days > 0 else { throw AnalyticsError.invalidWindow(days: days) }
        let since = now().timeIntervalSince1970 - Double(days) * 86_400
        let raw: [(Int, Int, Int)] = try await archive.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT CAST(strftime('%w', delivered_at, 'unixepoch', 'localtime') AS INTEGER) AS weekday,
                       CAST(strftime('%H', delivered_at, 'unixepoch', 'localtime') AS INTEGER) AS hour,
                       COUNT(*) AS total
                FROM notifications
                WHERE delivered_at >= ? AND is_deleted = 0
                GROUP BY weekday, hour
                """, arguments: [since]).map { ($0["weekday"], $0["hour"], $0["total"]) }
        }
        // Dense 7x24 grid so the chart never has holes.
        var grid = [Int: Int]()                       // key = weekday * 24 + hour
        for (weekday, hour, total) in raw { grid[weekday * 24 + hour] = total }
        return (0..<7).flatMap { weekday in
            (0..<24).map { hour in
                HeatmapCell(weekday: weekday, hour: hour, total: grid[weekday * 24 + hour] ?? 0)
            }
        }
    }

    public func focusEffectiveness(days: Int = 30) async throws -> FocusEffectiveness {
        guard days > 0 else { throw AnalyticsError.invalidWindow(days: days) }
        let nowSeconds = now().timeIntervalSince1970
        let since = nowSeconds - Double(days) * 86_400
        return try await archive.pool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT SUM(n.presented = 0) AS held_back, SUM(n.presented = 1) AS broke_through
                FROM notifications n
                JOIN away_sessions s ON s.reason = 'focus'
                  AND n.delivered_at >= s.started_at
                  AND n.delivered_at <  COALESCE(s.ended_at, ?)
                WHERE n.delivered_at >= ? AND n.is_deleted = 0
                """, arguments: [nowSeconds, since])
            return FocusEffectiveness(heldBack: row?["held_back"] ?? 0,
                                      brokeThrough: row?["broke_through"] ?? 0)
        }
    }
}
```

Error path: `Archive.pool.read` throws `DatabaseError` if the archive is mid-wipe or the file was removed; the view model maps that to `AnalyticsError.archiveUnavailable` and shows an empty state with a "Retry" button rather than a crash.

### Mute suggestions

`WeeklySummaryComposer` picks the single noisiest app that is **not** already `is_muted = 1` in the archive and has ≥ 50 notifications in the last 7 days (default threshold `analytics.suggestMuteThreshold`, editable in Settings). Only one suggestion per week; a suggestion for the same bundle id is not repeated for 4 weeks (`UserDefaults` key `analytics.lastSuggestedBundleID` + date). If the user has already muted the app inside Backglance we assume they know, and stay quiet.

## UI Components

Analytics lives in the full timeline window as a sidebar item ("Analytics") and is linked from Settings ▸ Analytics. It is not shown in the popover — the popover stays a fast timeline.

```swift
import SwiftUI
import Charts
import BackglanceCore

struct AnalyticsView: View {
    @State private var window = 7
    @State private var apps: [AppLoad] = []
    @State private var cells: [HeatmapCell] = []
    @State private var focus: FocusEffectiveness?
    @State private var error: String?
    private let service = AnalyticsService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Picker("Window", selection: $window) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }.pickerStyle(.segmented).frame(width: 200)

                if let error { ContentUnavailableView(error, systemImage: "chart.bar.xaxis") }

                Text("Noisiest apps").font(.headline)
                Chart(apps.prefix(10), id: \.bundleID) { app in
                    BarMark(x: .value("Notifications", app.total),
                            y: .value("App", app.displayName ?? app.bundleID))
                        .foregroundStyle(app.isMuted ? .secondary : .primary)
                }
                .frame(height: 260)
                .accessibilityLabel("Bar chart of notification counts per app")

                Text("Interruptions by hour and weekday").font(.headline)
                Chart(cells, id: \.self) { cell in
                    RectangleMark(x: .value("Hour", cell.hour),
                                  y: .value("Weekday", weekdaySymbol(cell.weekday)))
                        .foregroundStyle(by: .value("Count", cell.total))
                }
                .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) }
                .frame(height: 200)

                if let focus, let share = focus.heldBackShare {
                    Text("Focus held back \(Int(share * 100)) % of \(focus.heldBack + focus.brokeThrough) notifications")
                } else {
                    Text("No Focus sessions recorded in this window").foregroundStyle(.secondary)
                }
            }.padding()
        }
        .task(id: window) { await load() }
    }

    private func load() async {
        do {
            async let a = service.topApps(days: window)
            async let c = service.heatmap(days: 30)
            async let f = service.focusEffectiveness(days: 30)
            (apps, cells, focus) = try await (a, c, f)
            error = nil
        } catch {
            self.error = "Analytics is unavailable right now (\(error.localizedDescription))."
        }
    }

    private func weekdaySymbol(_ i: Int) -> String {
        Calendar.current.shortWeekdaySymbols[i]
    }
}
```

The heatmap uses a single sequential color ramp; counts are shown on hover via `.chartOverlay`. Every chart has an accessibility label and the underlying table is available as a plain `List` behind a "Show as table" toggle (see [ACCESSIBILITY.md](../reference/ACCESSIBILITY.md)).

## Weekly Summary

Opt-in in Settings ▸ Analytics ("Send a weekly summary"). Default fire time is **Sunday 18:00** local time, configurable. Delivered as a local notification through `UNUserNotificationCenter` with category `app.backglance.weeklySummary` and two actions: "Open Analytics" (`backglance://analytics`) and, when a suggestion exists, "Open Notification Settings".

```swift
import UserNotifications
import AppKit

enum WeeklySummaryScheduler {
    static let categoryID = "app.backglance.weeklySummary"

    static func schedule(weekday: Int = 1, hour: Int = 18) async throws {
        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        guard granted else { throw WeeklySummaryError.notificationsDenied }

        var date = DateComponents()
        date.weekday = weekday          // 1 = Sunday in Calendar terms
        date.hour = hour
        date.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: true)

        let content = UNMutableNotificationContent()
        content.title = "Your week in notifications"
        content.body = "Open Backglance to see the summary."   // real numbers are filled at fire time by the app
        content.categoryIdentifier = categoryID
        content.userInfo = ["url": "backglance://analytics"]

        let request = UNNotificationRequest(identifier: "weekly-summary", content: content, trigger: trigger)
        try await center.add(request)
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["weekly-summary"])
    }
}

enum WeeklySummaryError: Error { case notificationsDenied }
```

The notification body is intentionally generic: the app updates it with the actual top-three text right before the trigger fires (a `Timer` inside the app when it is running) and otherwise leaves the generic body — the summary never contains notification content, only app names and counts.

### Deep link to System Settings

```swift
enum NotificationSettingsLink {
    /// Best-effort deep link into System Settings ▸ Notifications ▸ <app>.
    /// ⚠️ The URL format is not documented and has changed across macOS versions.
    static func open(bundleID: String) {
        let specific = URL(string:
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)")!
        let root = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        if !NSWorkspace.shared.open(specific) {
            _ = NSWorkspace.shared.open(root)          // fallback: Notifications pane root
        }
    }
}
```

> ⚠️ **Warning:** `NSWorkspace.open` returns `true` even when System Settings ignores the `id` parameter and lands on the pane root; the fallback exists for the case where the URL is rejected outright. Test manually on every supported macOS at each point release and record the observed behavior in [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md).

## Retention Trade-off

Analytics reads the archive and only the archive. If an app's retention is `24h`, its notifications older than a day are gone and the 7-day report undercounts it. If an app is on the exclusion list it never appears at all. This is by design: analytics does not keep a shadow log of what was pruned, because that log would itself be a record of the user's activity that outlives their retention choice.

> 💡 **Tip:** The Analytics pane shows a footnote per report — "Based on N notifications kept under your retention settings" — and lists apps whose retention is shorter than the report window so the numbers are never read as absolute.

## Edge Cases and Error Handling

| Case | Behavior |
|---|---|
| Time zone changes / travel | `strftime(..., 'localtime')` uses the current zone at query time, so historical hours shift. Documented in the pane; no re-bucketing. |
| DST transition | One hour appears twice or not at all for that day; accepted. |
| Sparse data (first week) | Below 20 notifications the reports show "Not enough data yet" instead of charts. |
| No Focus sessions | Focus report shows "No Focus sessions recorded" (`heldBackShare == nil`). |
| App already muted in Backglance | Excluded from mute suggestions. |
| Notification permission denied | Weekly summary toggle shows "Allow notifications for Backglance in System Settings" with the deep link above; toggle stays off. |
| Archive locked / wipe in progress | `AnalyticsError.archiveUnavailable`, empty state with Retry. |
| 100k+ notifications | All queries are index-backed `GROUP BY`; budget: each report < 100 ms p95 (see [PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md)). |

## Testing Approach

- **Query correctness (`BackglanceCoreTests/AnalyticsServiceTests`):** seed `Archive(inMemory: true)` with a deterministic set (seeded RNG) across three apps and two Focus away sessions; assert exact `topApps` ordering, that `heatmap` always returns 168 cells, and that `focusEffectiveness` counts only overlaps.
- **Time zone:** run heatmap tests with `TZ` overridden via `setenv("TZ", "Europe/Istanbul", 1); tzset()` and again with `America/Los_Angeles`; assert buckets shift by the expected offset.
- **Window validation:** `topApps(days: 0)` throws `AnalyticsError.invalidWindow`.
- **Suggestions:** `WeeklySummaryComposer` tests for threshold, already-muted suppression, and the 4-week repeat guard using an injected `now`.
- **Scheduler:** `WeeklySummaryScheduler` tested through a `NotificationCentering` protocol fake (same one used by [SNOOZE_RESURFACE.md](./SNOOZE_RESURFACE.md)); assert the trigger's `dateMatching` components and the denied path.
- **Performance:** `measure {}` block over 100k seeded rows; fail above 100 ms.
- **UI:** snapshot-free XCUITest that opens Analytics and asserts the "Not enough data yet" state on an empty archive.

## Related Documentation

- [MISSED_DIGEST.md](./MISSED_DIGEST.md) — away sessions and Focus detection that the Focus report depends on
- [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md) — retention, exclusion, and why analytics can only see what is kept
- [SNOOZE_RESURFACE.md](./SNOOZE_RESURFACE.md) — shared `UNUserNotificationCenter` plumbing
- [RULES.md](./RULES.md) — muting inside Backglance (visual only)
- [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md) — `notifications`, `apps`, `away_sessions`
- [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md) — per-release check of the System Settings deep link
- [PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md)
- [ACCESSIBILITY.md](../reference/ACCESSIBILITY.md)
- [TESTING.md](../testing/TESTING.md)
- [ROADMAP.md](../reference/ROADMAP.md)
