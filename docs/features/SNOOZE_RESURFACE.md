# Snooze & Resurface

Last Updated: 2026-08-18

> ℹ️ **Status:** Planned for v1.x — not in v1.0.

This document describes how any archived notification can be turned into a local reminder — "bring this back at 5 pm" — and how it resurfaces at the top of the timeline when the time comes. It covers the `snoozes` table, `SnoozeScheduler` on top of `UNUserNotificationCenter`, restart survival, the optional Reminders export through EventKit, and the honest wrinkle that Backglance's own local notifications land in the same system store it captures from.

## Table of Contents

- [Feature Overview](#feature-overview)
- [Architecture](#architecture)
- [Archive Tables Involved](#archive-tables-involved)
- [UI Components](#ui-components)
- [Business Logic](#business-logic)
- [Reminders Export (EventKit)](#reminders-export-eventkit)
- [Backglance Captures Itself](#backglance-captures-itself)
- [Edge Cases and Error Handling](#edge-cases-and-error-handling)
- [Testing Approach](#testing-approach)
- [Related Documentation](#related-documentation)

## Feature Overview

| Capability | Detail |
|---|---|
| Snooze presets | In 1 hour · This evening (18:00) · Tomorrow morning (09:00) · Custom date/time |
| Delivery | Local notification via `UNUserNotificationCenter`, category `app.backglance.snooze`, actions **Open** / **Snooze again** / **Done** |
| Resurface | Notification moves to the top of the timeline with a "Snoozed" badge, `is_read` reset to 0 |
| Persistence | `snoozes` table; pending snoozes are rescheduled from the table at every launch |
| Reminders export | Optional; creates an `EKReminder` and stores its identifier in `snoozes.reminders_identifier` |
| Entry points | Row context menu, ⌘⇧S in the timeline, `SnoozeNotificationIntent` (Shortcuts, see [EXPORT_AUTOMATION.md](./EXPORT_AUTOMATION.md)) |

Snoozing is a Backglance-side reminder. It does not re-deliver the original app's notification and does not touch the system store.

## Architecture

```
  Timeline row ── "Snooze ▸ Tomorrow morning"
        │
        ▼
  SnoozeScheduler (BackglanceCore, actor)
    ├ insert row in `snoozes` (fire_at)          ── Archive (GRDB)
    ├ UNUserNotificationCenter.add(request)      ── identifier "snooze-<snoozeID>"
    └ optional: RemindersExporter.create(...)    ── EventKit, stores reminders_identifier
        │
        │  fire_at reached (Mac awake) / on wake if missed
        ▼
  macOS shows Backglance's local notification  ──▶ (also written to the system store,
        │      Open / Snooze again / Done            which CaptureEngine skips because
        ▼                                            app.backglance.Backglance is excluded)
  UNUserNotificationCenterDelegate (AppDelegate)
    ├ Open        ▶ SnoozeScheduler.markFired(id) ▶ timeline scrolls to row, "Snoozed" badge
    ├ Snooze again▶ SnoozeScheduler.reschedule(id, +1h)
    └ Done        ▶ markFired + is_read = 1

  App launch ▶ SnoozeScheduler.restorePending()  (re-adds requests for fire_at > now,
                                                   resurfaces those with fire_at <= now)
```

## Archive Tables Involved

```sql
CREATE TABLE snoozes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  notification_id INTEGER NOT NULL REFERENCES notifications(id) ON DELETE CASCADE,
  fire_at REAL NOT NULL,          -- Unix seconds
  fired_at REAL,                  -- NULL while pending
  reminders_identifier TEXT       -- EKReminder.calendarItemIdentifier when exported
);
```

Migration `v3_snoozes` in `ArchiveMigrations.swift`. `ON DELETE CASCADE` means deleting a notification (hard prune) removes its snooze row; the scheduler also cancels the pending `UNNotificationRequest` when it observes the deletion. On `notifications`, resurfacing sets `is_read = 0` and the timeline sorts pending-fired snoozes above everything else for the current session.

```swift
import GRDB

public struct Snooze: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "snoozes"
    public var id: Int64?
    public var notificationID: Int64
    public var fireAt: Date
    public var firedAt: Date?
    public var remindersIdentifier: String?

    enum CodingKeys: String, CodingKey {
        case id, notificationID = "notification_id", fireAt = "fire_at",
             firedAt = "fired_at", remindersIdentifier = "reminders_identifier"
    }
    public var isPending: Bool { firedAt == nil }
}
```

## UI Components

- **`SnoozeMenu`** (BackglanceUI): submenu in the row context menu and in the row's hover actions. Presets computed by `SnoozePresets.options(now:)`; "Custom…" opens `SnoozeDatePickerSheet` (`DatePicker` with `.hourAndMinute` + date, minimum = now + 1 min).
- **"Snoozed" badge** on `NotificationRow`: a small clock glyph + "Snoozed · was due 17:00"; tapping it clears the badge (`markSeen`).
- **Settings ▸ Snooze:** default evening/morning times, "Also add to Reminders" toggle (off by default), "Reminders list" picker (only after permission granted).
- **Popover:** a pending-snooze count in the popover footer ("2 snoozed"), tapping filters the timeline to pending snoozes.

```swift
enum SnoozePresets {
    static func options(now: Date = .now, calendar: Calendar = .current,
                        eveningHour: Int = 18, morningHour: Int = 9) -> [(title: String, fireAt: Date)] {
        var out: [(String, Date)] = [("In 1 hour", now.addingTimeInterval(3_600))]
        if let evening = calendar.date(bySettingHour: eveningHour, minute: 0, second: 0, of: now),
           evening > now {
            out.append(("This evening", evening))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           let morning = calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: tomorrow) {
            out.append(("Tomorrow morning", morning))
        }
        return out
    }
}
```

"This evening" is omitted after 18:00 rather than pointing into the past.

## Business Logic

`SnoozeScheduler` depends on a small protocol so tests never touch the real notification center.

```swift
import Foundation
import UserNotifications
import GRDB

public protocol NotificationCentering: Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
}

extension UNUserNotificationCenter: NotificationCentering {}

public enum SnoozeError: Error, Equatable {
    case fireTimeInPast
    case notificationNotFound(Int64)
    case authorizationDenied
    case archive(String)
}

public actor SnoozeScheduler {
    public static let categoryID = "app.backglance.snooze"
    private let archive: Archive
    private let center: any NotificationCentering
    private let now: () -> Date

    public init(archive: Archive = .shared,
                center: any NotificationCentering = UNUserNotificationCenter.current(),
                now: @escaping () -> Date = Date.init) {
        self.archive = archive
        self.center = center
        self.now = now
    }

    public func registerCategory() {
        let open = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
        let again = UNNotificationAction(identifier: "again", title: "Snooze again")
        let done = UNNotificationAction(identifier: "done", title: "Done")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: [open, again, done],
                                   intentIdentifiers: [], options: [])
        ])
    }

    /// Success path returns the persisted snooze. Throws before writing anything on bad input.
    @discardableResult
    public func snooze(notificationID: Int64, until fireAt: Date) async throws -> Snooze {
        guard fireAt > now() else { throw SnoozeError.fireTimeInPast }

        // 1. Persist first: the table is the source of truth, the notification center is a cache.
        var snooze = Snooze(id: nil, notificationID: notificationID, fireAt: fireAt,
                            firedAt: nil, remindersIdentifier: nil)
        do {
            snooze = try await archive.pool.write { db in
                guard try ArchivedNotification.exists(db, key: notificationID) else {
                    throw SnoozeError.notificationNotFound(notificationID)
                }
                return try snooze.inserted(db)
            }
        } catch let error as SnoozeError {
            throw error
        } catch {
            throw SnoozeError.archive(error.localizedDescription)
        }

        // 2. Schedule. If the user denied notifications we keep the row: it still resurfaces in-app.
        do {
            try await schedule(snooze)
        } catch SnoozeError.authorizationDenied {
            Log.snooze.notice("Notifications denied; snooze \(snooze.id ?? -1) will resurface in-app only")
        }
        return snooze
    }

    private func schedule(_ snooze: Snooze) async throws {
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        guard granted else { throw SnoozeError.authorizationDenied }

        let content = UNMutableNotificationContent()
        content.title = "Snoozed notification"
        content.body = "Something you set aside is back."   // never the original body: this text goes into the system store
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["snoozeID": snooze.id ?? 0]

        let interval = max(1, snooze.fireAt.timeIntervalSince(now()))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        try await center.add(UNNotificationRequest(identifier: Self.requestID(snooze),
                                                   content: content, trigger: trigger))
    }

    /// Called from AppDelegate on launch. Rebuilds pending requests; resurfaces anything already due.
    public func restorePending() async throws {
        let pending = try await archive.pool.read { db in
            try Snooze.filter(Column("fired_at") == nil).fetchAll(db)
        }
        for snooze in pending {
            if snooze.fireAt <= now() {
                try await markFired(snooze.id!)          // Mac was asleep or app not running at fire time
            } else {
                try? await schedule(snooze)              // denied permission is not fatal here either
            }
        }
    }

    public func markFired(_ id: Int64) async throws {
        try await archive.pool.write { db in
            guard var snooze = try Snooze.fetchOne(db, key: id) else { return }
            snooze.firedAt = now()
            try snooze.update(db)
            try db.execute(sql: "UPDATE notifications SET is_read = 0 WHERE id = ?",
                           arguments: [snooze.notificationID])
        }
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestID(id)])
    }

    public func cancel(_ id: Int64) async throws {
        _ = try await archive.pool.write { db in try Snooze.deleteOne(db, key: id) }
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestID(id)])
    }

    public func reschedule(_ id: Int64, delay: TimeInterval = 3_600) async throws {
        try await archive.pool.write { db in
            guard var snooze = try Snooze.fetchOne(db, key: id) else { return }
            snooze.fireAt = now().addingTimeInterval(delay)
            snooze.firedAt = nil
            try snooze.update(db)
        }
        if let snooze = try await archive.pool.read({ db in try Snooze.fetchOne(db, key: id) }) {
            try await schedule(snooze)
        }
    }

    private static func requestID(_ snooze: Snooze) -> String { requestID(snooze.id ?? 0) }
    private static func requestID(_ id: Int64) -> String { "snooze-\(id)" }
}
```

The `UNUserNotificationCenterDelegate` in `AppDelegate` maps action identifiers to `markFired` / `reschedule` and, for "open", posts `backglance://open?id=<uuid>` through `URLSchemeHandler` so the timeline scrolls to the resurfaced row. When the app is in the foreground, `willPresent` returns `[.banner]` so the reminder still shows.

## Reminders Export (EventKit)

Off by default. When enabled, snoozing also creates a reminder in the user's chosen list, so it shows on iPhone too. Backglance requests **full** access because it must read the reminder back to delete it when the snooze is cancelled.

```swift
import EventKit

enum RemindersExportError: Error { case accessDenied, noDefaultList, save(Error) }

struct RemindersExporter {
    let store = EKEventStore()

    func create(title: String, due: Date, listIdentifier: String?) async throws -> String {
        let granted = try await store.requestFullAccessToReminders()      // macOS 14+
        guard granted else { throw RemindersExportError.accessDenied }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title                                            // app name + "(snoozed in Backglance)", never the body
        reminder.dueDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: due)
        reminder.addAlarm(EKAlarm(absoluteDate: due))
        guard let list = listIdentifier.flatMap(store.calendar(withIdentifier:))
                ?? store.defaultCalendarForNewReminders() else {
            throw RemindersExportError.noDefaultList
        }
        reminder.calendar = list
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw RemindersExportError.save(error)
        }
        return reminder.calendarItemIdentifier
    }

    func delete(identifier: String) throws {
        guard let item = store.calendarItem(withIdentifier: identifier) as? EKReminder else { return }
        try store.remove(item, commit: true)
    }
}
```

`Info.plist` needs `NSRemindersFullAccessUsageDescription` ("Backglance adds a reminder for notifications you snooze, if you turn that on."). If access is denied, the toggle flips back off with an inline explanation; the snooze itself still works. The reminder title is the app's display name plus a suffix, never notification content — a reminder syncs through iCloud, and Backglance does not put archive content on any network by default (see [CLOUDKIT_SYNC.md](./CLOUDKIT_SYNC.md) for the one opt-in exception).

## Backglance Captures Itself

Every local notification Backglance posts is delivered by the same `usernoted` process whose store Backglance reads. Without a guard, each snooze reminder would be captured back into the archive as a notification from `app.backglance.Backglance`. That is why the app's own bundle id is in the **default exclusion list** (`apps.is_excluded = 1`, see [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md)) alongside password managers. If a user removes it from the list, they will see their own reminders in the timeline — harmless, slightly silly, and documented in [FAQ.md](../reference/FAQ.md).

> ℹ️ **Info:** For the same reason the reminder body never repeats the original notification text: it would otherwise be written into Apple's store a second time, outside the retention and redaction rules the archive applies.

## Edge Cases and Error Handling

| Case | Behavior |
|---|---|
| Fire time in the past (custom picker, clock change) | `SnoozeError.fireTimeInPast`; sheet shows "Pick a time in the future". |
| Mac asleep at fire time | `UNTimeIntervalNotificationTrigger` fires on wake; if the app was not running, `restorePending()` resurfaces it on next launch. |
| App quit at fire time | Notification still fires (system-owned); action taps launch the app, which handles them after `restorePending()`. |
| Notification deleted (soft or hard) | Snooze row cascades on hard delete; on soft delete the row context "Delete" also calls `cancel`. |
| Notification permission denied | Row is stored, no system notification; resurfaces in-app when the app is next active after `fire_at` (checked every timeline refresh). Settings shows a hint with the System Settings link. |
| Duplicate snooze on same notification | Allowed; the timeline shows the earliest pending time. |
| Reminders access denied | `RemindersExportError.accessDenied`, toggle turns off, snooze still scheduled. |
| Reminder deleted by the user in Reminders.app | `delete(identifier:)` finds nothing and returns; no error surfaced. |
| Retention prunes the notification before `fire_at` | Cascade removes the snooze; the pending request is removed by a periodic reconcile that diffs `pendingNotificationRequests` against the table. |
| Panic wipe | Wipe cancels all `snooze-*` requests and deletes exported reminders it created (identifiers are read before the table is dropped). |

## Testing Approach

- **`FakeNotificationCenter`** (`BackglanceCoreTests/Support`): conforms to `NotificationCentering`, records `added` requests and `removed` identifiers, and has `authorization: Bool` and `addError: Error?` knobs.
- **Scheduling:** snooze → assert one request with identifier `snooze-<id>`, correct category, `UNTimeIntervalNotificationTrigger` interval within 1 s of expected, and no notification content in `body`.
- **Past fire time:** assert `SnoozeError.fireTimeInPast` and that the table is unchanged.
- **Denied permission:** `authorization = false` → row exists, `added.isEmpty`, no throw from `snooze(...)`.
- **Restart:** insert two rows (one due, one future) directly, call `restorePending()`, assert the due one has `fired_at` set and `is_read = 0`, the future one is re-added.
- **Cascade:** delete the notification, assert `Snooze.fetchCount == 0`.
- **Reschedule:** "Snooze again" moves `fire_at` by 3 600 s and clears `fired_at`.
- **Reminders:** `RemindersExporter` is behind a `RemindersExporting` protocol; the real one is exercised only in a manual checklist because EventKit needs TCC consent.
- **UI:** XCUITest: snooze from the context menu, verify the "Snoozed" badge after forcing `markFired` via a debug menu item.

## Related Documentation

- [ACTIONS.md](./ACTIONS.md) — the row action model this extends
- [TIMELINE.md](./TIMELINE.md) — badge rendering and top-of-timeline resurfacing
- [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md) — default exclusion list (includes Backglance itself)
- [EXPORT_AUTOMATION.md](./EXPORT_AUTOMATION.md) — `SnoozeNotificationIntent`, `backglance://open`
- [ANALYTICS.md](./ANALYTICS.md) — shares the `NotificationCentering` fake for the weekly summary
- [CLOUDKIT_SYNC.md](./CLOUDKIT_SYNC.md) — the only opt-in path by which content leaves the Mac
- [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md) — `snoozes` table, migration `v3_snoozes`
- [PERMISSIONS_PRIVACY.md](./PERMISSIONS_PRIVACY.md) — notification and Reminders permissions
- [FAQ.md](../reference/FAQ.md)
- [TESTING.md](../testing/TESTING.md)
