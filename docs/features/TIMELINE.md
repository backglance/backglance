# Timeline

Last Updated: 2026-08-18

This document describes the timeline: the two places where the archive becomes visible — the menu bar dropdown (an `NSPopover` from the status item) and the full timeline window — and everything they share: grouping by day and by app, compact and detailed rows, the "new since you were away" marker, read state and the unread badge, keyboard navigation, pagination, and live updates from the archive. The timeline reads the archive only; capture is documented in [CAPTURE.md](./CAPTURE.md), search in [SEARCH.md](./SEARCH.md), and row actions in [ACTIONS.md](./ACTIONS.md).

## Table of Contents

- [Feature Overview](#feature-overview)
- [Architecture](#architecture)
- [Archive Tables Involved](#archive-tables-involved)
- [UI Components](#ui-components)
  - [StatusItemController](#statusitemcontroller)
  - [MenuBarPopoverView](#menubarpopoverview)
  - [TimelineView and TimelineSection](#timelineview-and-timelinesection)
  - [NotificationRow](#notificationrow)
  - [UnreadDivider](#unreaddivider)
  - [Toolbar](#toolbar)
  - [Keyboard navigation](#keyboard-navigation)
- [Business Logic](#business-logic)
  - [TimelineStore](#timelinestore)
  - [Keyset pagination](#keyset-pagination)
  - [Grouping](#grouping)
  - [Triage in the timeline](#triage-in-the-timeline)
  - [Read state and the unread badge](#read-state-and-the-unread-badge)
  - [View mode persistence](#view-mode-persistence)
  - [Window management](#window-management)
- [Performance](#performance)
- [Accessibility](#accessibility)
- [Edge Cases and Error Handling](#edge-cases-and-error-handling)
- [Testing Approach](#testing-approach)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Feature Overview

The timeline is the archive, newest first. It appears in two hosts backed by the same SwiftUI views from `BackglanceUI`:

| Host | Entry | Size | Purpose |
|---|---|---|---|
| Menu bar popover | Status item click, hotkey ⌃⌥N | fixed 380 × 520 | Glance: what came in, what did I miss |
| Timeline window | "Open full window" (⌘↩) from the popover, `backglance://open` | resizable, frame restored | Reading, filtering, keyboard-driven triage |

What both show:

- Notifications **grouped by day** ("Today", "Yesterday", "Monday, 11 Aug"), optionally **sub-grouped by app** within each day.
- **Compact** rows (icon, app, title, time) or **detailed** rows (plus subtitle/body, attachments chip, thread indicator). The mode persists per host.
- An **unread divider** — "new since you were away" — placed before the first notification that arrived after the last time the user looked (last popover open, or the end of the last away session, whichever is later).
- **Triage** from the rules engine: pinned VIP notifications float to the top of their day, muted apps collapse into a single "Muted (n)" group, highlight rules tint the row. Triage is visual only ([RULES.md](./RULES.md)).
- The status item shows an **unread badge count** (muted excluded, capped at "99+").

> ℹ️ **Info:** The timeline never talks to the system store. It renders whatever capture already archived, so it works identically with FDA granted, revoked, or capture paused — only the empty states differ.

## Architecture

```
                       Archive (GRDB DatabasePool, WAL)
                                    │
              ┌─────────────────────┴──────────────────────┐
              │ ValueObservation                            │ timelinePage(after:limit:)
              │ (newest page + unread count, main queue)    │ (older pages, on demand)
              ▼                                             ▼
   ┌────────────────────────── TimelineStore (@MainActor @Observable) ─────────────────────────┐
   │ rows: [ArchivedNotification]      cursor: TimelineCursor?     loadError: String?          │
   │ filter (app chips, muted)         viewMode (.compact/.detailed)                            │
   │ unreadAnchor: UnixDate            triage cache (RulesEngine over visible rows)             │
   │ sections: [TimelineSection.Model] ← grouping by day (user calendar) and by app             │
   └───────┬───────────────────────────────┬───────────────────────────────────┬───────────────┘
           │                               │                                   │
           ▼                               ▼                                   ▼
   MenuBarPopoverView              TimelineWindow (NSWindow,           NSStatusItem badge
   (NSPopover ◀ NSHosting-         frame restored, ⌘↩)                 (unread count, muted
    Controller, 380×520)                                                excluded)
           └───────────────┬───────────────┘
                           ▼
                     TimelineView
                       ├── UnreadDivider          "new since you were away"
                       ├── TimelineSection        day header + optional AppGroupHeader groups
                       │     └── NotificationRow  compact / detailed
                       └── EmptyStateView         no FDA / paused / nothing yet / all filtered
```

One store instance serves both hosts. The popover and the window render the same `sections`; only chrome (toolbar, sizing) differs. Writes triggered from the UI (mark read, delete, pin) go through `Archive` and come back via the observation, so the views never mutate their own copy of a row.

## Archive Tables Involved

The timeline reads three tables and writes flags on one. DDL in [../architecture/DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md).

| Table | Read | Written |
|---|---|---|
| `notifications` | every visible column; `is_deleted = 0` always filtered | `is_read` (visibility ≥ 1 s or opened; "Mark all read"), `is_pinned` (toggle), `is_deleted` (⌫, soft delete) |
| `apps` | `display_name`, `bundle_id`, `is_muted` (collapse), joined per row | — |
| `rules` | loaded once, observed for changes; evaluated per visible row | — |
| `away_sessions` | `ended_at` of the most recent session (unread anchor) | — |

The unread anchor is not a table of its own: it is `max(last popover open, last away session end)`, with the popover-open timestamp kept in `UserDefaults` (`timeline.lastSeenAt`, suite `app.backglance.Backglance`).

## UI Components

| Component | File | Role |
|---|---|---|
| `StatusItemController` | `Backglance/App/StatusItemController.swift` | `NSStatusItem`, badge, popover toggle, right-click menu |
| `MenuBarPopoverView` | `Backglance/Scenes/MenuBarPopover/MenuBarPopoverView.swift` | Popover chrome: toolbar + `TimelineView` + footer |
| `TimelineView` | `Packages/BackglanceUI/Sources/BackglanceUI/Timeline/TimelineView.swift` | Scroll view, sections, empty states, keyboard focus |
| `TimelineSection` | `…/Timeline/TimelineSection.swift` | Day header ("Today / Yesterday / Monday, 11 Aug") + rows, optional app sub-groups |
| `AppGroupHeader` | `…/Timeline/AppGroupHeader.swift` | App icon + name + count when by-app grouping is on; collapse chevron for muted group |
| `NotificationRow` | `…/Timeline/NotificationRow.swift` | One notification, compact or detailed |
| `UnreadDivider` | `…/Timeline/UnreadDivider.swift` | "new since you were away" marker |
| `EmptyStateView` | `…/Timeline/EmptyStateView.swift` | Four states, see [Edge Cases](#edge-cases-and-error-handling) |
| `TimelineWindowController` | `Backglance/Scenes/TimelineWindow/TimelineWindowController.swift` | `NSWindow` hosting `TimelineView` with the full toolbar |

### StatusItemController

AppKit owns the status item and the popover; SwiftUI starts inside the `NSHostingController`. The toggle is also the point where the unread anchor advances — opening the popover *is* "the user looked".

```swift
// Backglance/App/StatusItemController.swift
import AppKit
import SwiftUI
import BackglanceCore
import BackglanceUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let store: TimelineStore

    init(store: TimelineStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let hosting = NSHostingController(rootView: MenuBarPopoverView().environment(store))
        hosting.sizingOptions = []                               // we own the size
        popover.contentViewController = hosting
        popover.contentSize = NSSize(width: 380, height: 520)
        popover.behavior = .transient                            // click-away closes
        popover.animates = false                                 // < 100 ms to first paint
        popover.delegate = self

        if let button = statusItem.button {
            button.image = NSImage(named: "StatusIcon")          // template image
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        observeBadge()
    }

    // MARK: Toggle

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = contextMenu()                      // pause / resume / settings / quit
            statusItem.button?.performClick(nil)                 // shows the menu
            statusItem.menu = nil                                // restore left-click behaviour
            return
        }
        togglePopover()
    }

    /// Also bound to the ⌃⌥N hotkey via HotKeyCenter.
    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            store.popoverWillOpen()                              // advances the unread anchor *after* snapshotting it
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        store.popoverDidClose()                                  // persists timeline.lastSeenAt
    }

    // MARK: Badge

    private func observeBadge() {
        // withObservationTracking re-arms itself; fires on store.unreadBadgeCount changes.
        withObservationTracking {
            self.render(badge: self.store.unreadBadgeCount)
        } onChange: {
            Task { @MainActor [weak self] in self?.observeBadge() }
        }
    }

    private func render(badge count: Int) {
        guard let button = statusItem.button else { return }
        // A text badge next to the template icon; 0 hides it, display caps at 99+.
        button.title = count == 0 ? "" : (count > 99 ? " 99+" : " \(count)")
        button.imagePosition = count == 0 ? .imageOnly : .imageLeft
        button.toolTip = count == 0 ? "Backglance" : "Backglance — \(count) unread"
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Full Window", action: #selector(AppDelegate.openTimelineWindow(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Pause Capture for 1 Hour", action: #selector(AppDelegate.pauseOneHour(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Backglance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }
}
```

> 💡 **Tip:** `popover.animates = false` and a prebuilt hosting controller are two of the three things that keep open-to-first-paint under 100 ms; the third is that `TimelineStore` already holds the newest page in memory ([../deployment/PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md)).

### MenuBarPopoverView

The popover is `TimelineView` plus a thin toolbar (search field that routes to [SEARCH.md](./SEARCH.md), view-mode toggle, "Open full window" ⌘↩) and a footer showing capture status when it is not `.running` (paused note, degraded banner from [PERMISSIONS_PRIVACY.md](./PERMISSIONS_PRIVACY.md)).

### TimelineView and TimelineSection

```swift
// Packages/BackglanceUI/Sources/BackglanceUI/Timeline/TimelineView.swift
import SwiftUI
import BackglanceCore

public struct TimelineView: View {
    @Environment(TimelineStore.self) private var store
    @FocusState private var focusedRowID: Int64?

    public init() {}

    public var body: some View {
        Group {
            if let message = store.loadError {
                ArchiveHealthBanner(message: message, retry: { store.retry() })
            }
            if store.sections.isEmpty {
                EmptyStateView(kind: store.emptyStateKind)
            } else {
                timeline
            }
        }
        .onKeyPress(.upArrow) { store.moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { store.moveSelection(1); return .handled }
        .onKeyPress(.return) { store.openSelected(); return .handled }
        .onDeleteCommand { store.deleteSelected() }
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(store.sections) { section in
                        Section {
                            ForEach(section.slots) { slot in
                                switch slot {
                                case .divider:
                                    UnreadDivider()
                                case .appHeader(let group):
                                    AppGroupHeader(group: group)
                                case .row(let item):
                                    NotificationRow(item: item, mode: store.viewMode)
                                        .id(item.id)                       // stable Int64 archive id
                                        .focused($focusedRowID, equals: item.id)
                                        .onAppear { store.rowBecameVisible(item.id) }   // read-state timer
                                        .onDisappear { store.rowBecameHidden(item.id) }
                                }
                            }
                        } header: {
                            DayHeader(title: section.title)                 // "Today" / "Yesterday" / "Monday, 11 Aug"
                        }
                    }
                    if store.hasMorePages {
                        PageSentinel()                                      // triggers loadNextPage() on appear
                            .task { await store.loadNextPage() }
                    }
                }
            }
            .onChange(of: store.selectedID) { _, id in
                if let id { proxy.scrollTo(id) }                            // keyboard selection stays visible
            }
        }
    }
}
```

`TimelineSection.Model` is a value the store builds off the row array; the view never groups. `slots` interleaves the unread divider and app headers with rows so `LazyVStack` sees one flat, lazily-instantiated list.

Day header titles come from one formatter:

```swift
// Packages/BackglanceUI/Sources/BackglanceUI/Timeline/DayHeader.swift (formatting logic)
import Foundation

enum DayTitle {
    /// "Today", "Yesterday", weekday + day + month within the last week ("Monday, 11 Aug"),
    /// full date beyond that ("11 August 2026"). Calendar and time zone are the user's current ones.
    static func string(for day: Date, calendar: Calendar = .current, now: Date = .now) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let withinWeek = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
            .map { day >= $0 } ?? false
        formatter.setLocalizedDateFormatFromTemplate(withinWeek ? "EEEE d MMM" : "d MMMM y")
        return formatter.string(from: day)
    }
}
```

### NotificationRow

```swift
// Packages/BackglanceUI/Sources/BackglanceUI/Timeline/NotificationRow.swift
import SwiftUI
import BackglanceCore

public enum TimelineViewMode: String, CaseIterable, Sendable { case compact, detailed }

/// A display item: the archived row plus its computed triage and cached icon.
public struct TimelineItem: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let notification: ArchivedNotification
    public let appName: String
    public let triage: Triage
    public var isSelected: Bool
}

public struct NotificationRow: View {
    let item: TimelineItem
    let mode: TimelineViewMode
    @Environment(TimelineStore.self) private var store

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AppIconView(bundleID: item.notification.appId)          // NSCache-backed, never NSWorkspace on the row
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if item.triage.pinned { Image(systemName: "pin.fill").imageScale(.small) }
                    Text(item.appName).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(item.notification.deliveredAt.date, format: .dateTime.hour().minute())
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(item.notification.title ?? item.notification.body ?? String(localized: "(no text)"))
                    .font(.body.weight(item.notification.isRead ? .regular : .semibold))
                    .lineLimit(1)                                   // compact: never measure body text

                if mode == .detailed {
                    if let subtitle = item.notification.subtitle {
                        Text(subtitle).font(.callout).lineLimit(1)
                    }
                    if item.notification.title != nil, let body = item.notification.body {
                        Text(body).font(.callout).foregroundStyle(.secondary)
                            .lineLimit(4)                           // bounded even for huge bodies
                    }
                    HStack(spacing: 6) {
                        if let chip = attachmentsChip { chip }
                        if item.notification.threadId != nil {
                            Label(String(localized: "Thread"), systemImage: "bubble.left.and.bubble.right")
                                .font(.caption2).labelStyle(.titleAndIcon)
                        }
                    }
                }
            }
        }
        .padding(.vertical, mode == .compact ? 4 : 8)
        .padding(.horizontal, 10)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture { store.open(item.id) }                       // marks read + deep link (ACTIONS.md)
        .contextMenu { RowContextMenu(item: item) }                 // copy, pin, delete, rules…
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    /// "2 attachments" chip — metadata only; the archive never stores attachment bytes.
    private var attachmentsChip: Label<Text, Image>? {
        guard let json = item.notification.attachmentsJson,
              let metas = try? JSONDecoder().decode([AttachmentMeta].self, from: Data(json.utf8)),
              !metas.isEmpty else { return nil }
        return Label("\(metas.count)", systemImage: "paperclip")
    }

    @ViewBuilder private var rowBackground: some View {
        if item.isSelected {
            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18))
        } else if let color = item.triage.highlight {
            RoundedRectangle(cornerRadius: 6).fill(color.swiftUIColor.opacity(0.12))
        }
    }

    private var accessibilitySummary: String {
        var parts = [item.appName]
        if !item.notification.isRead { parts.append(String(localized: "unread")) }
        if let t = item.notification.title { parts.append(t) }
        if mode == .detailed, let b = item.notification.body { parts.append(b) }
        return parts.joined(separator: ", ")
    }
}
```

Compact rows never render the body, so SwiftUI never measures multi-line text on the popover's hot path. An OTP-redacted notification renders like any other — the body simply reads `[code redacted]`.

### UnreadDivider

```swift
// Packages/BackglanceUI/Sources/BackglanceUI/Timeline/UnreadDivider.swift
import SwiftUI

/// Placed before the first notification delivered after the unread anchor
/// (last popover open, or the last away session's end — whichever is later).
public struct UnreadDivider: View {
    public init() {}

    public var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.tint).frame(height: 1)
            Text("new since you were away")
                .font(.caption2.smallCaps())
                .foregroundStyle(.tint)
                .fixedSize()
            Rectangle().fill(.tint).frame(height: 1)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .accessibilityElement()
        .accessibilityLabel(Text("New notifications since you were away start here"))
        .accessibilityAddTraits(.isHeader)
    }
}
```

Placement rules:

- The anchor is snapshotted when the popover opens and *then* advanced, so the divider the user sees reflects the moment before they clicked.
- If nothing arrived since the anchor, no divider is shown (a divider at the very top would be noise).
- If everything on screen is newer than the anchor, the divider sits below the newest older row — which may be on a later page; the store keeps the anchor so the divider materializes when that page loads.
- The full window shares the same anchor: opening either surface counts as "you looked".

### Toolbar

| Control | Popover | Window | Notes |
|---|---|---|---|
| Search field | ✅ (compact) | ✅ | Routes to `QueryParser`/`HybridSearch` ([SEARCH.md](./SEARCH.md)); Esc clears, then closes |
| Filter chips by app | overflow menu | ✅ chips row | Multi-select; "Muted" chip reveals collapsed groups |
| By-app grouping toggle | ✅ | ✅ | Persists per host |
| View mode toggle (compact/detailed) | ✅ | ✅ | Persists per host |
| "Mark all read" | menu | ✅ | Single `UPDATE`, observation refreshes rows |
| "Open full window" | ✅ ⌘↩ | — | Closes the popover, opens/focuses the window |

### Keyboard navigation

| Key | Action |
|---|---|
| ↑ / ↓ | Move selection (skips headers and the divider; wraps at neither end) |
| ↩ | Open selected — deep link when present, else detail popout ([ACTIONS.md](./ACTIONS.md)); marks read |
| ⌘C | Copy selected notification's text (title — subtitle — body, redacted body copies as redacted) |
| ⌫ | Soft-delete selected (`is_deleted = 1`); selection moves to the next row |
| ⌘F | Focus the search field |
| Esc | Clear search if active, else close popover / window |
| ⌘↩ | Open the full window (popover only) |
| Space | Toggle compact/detailed for the selected row (peek) |

Selection is `TimelineStore.selectedID: Int64?`; the view scrolls it visible via `ScrollViewReader`. All shortcuts work identically in both hosts.

## Business Logic

### TimelineStore

```swift
// Packages/BackglanceUI/Sources/BackglanceUI/Timeline/TimelineStore.swift
import Foundation
import GRDB
import Observation
import BackglanceCore

@MainActor @Observable
public final class TimelineStore {
    // Display state
    public private(set) var sections: [TimelineSection.Model] = []
    public private(set) var unreadBadgeCount = 0
    public private(set) var loadError: String?
    public private(set) var hasMorePages = true
    public var selectedID: Int64?
    public var viewMode: TimelineViewMode {
        didSet { defaults.set(viewMode.rawValue, forKey: "timeline.viewMode.\(host.rawValue)") }
    }
    public var groupByApp: Bool {
        didSet { defaults.set(groupByApp, forKey: "timeline.groupByApp.\(host.rawValue)"); regroup() }
    }
    public var appFilter: Set<String> = [] { didSet { regroup() } }

    public enum Host: String { case popover, window }

    // Dependencies
    private let archive: Archive
    private let rules: RulesEngine
    private let host: Host
    private let defaults: UserDefaults
    private let calendar: Calendar

    // Internals
    private var rows: [ArchivedNotification] = []          // ≤ 1,000, newest first
    private var cursor: TimelineCursor?
    private var unreadAnchor: UnixDate
    private var observation: Task<Void, Never>?
    private var visibilityTimers: [Int64: Task<Void, Never>] = [:]
    private var isLoadingPage = false
    private static let pageSize = 200
    private static let maxRows = 1_000

    public init(archive: Archive, rules: RulesEngine, host: Host = .popover,
                defaults: UserDefaults = UserDefaults(suiteName: "app.backglance.Backglance") ?? .standard,
                calendar: Calendar = .current) {
        self.archive = archive
        self.rules = rules
        self.host = host
        self.defaults = defaults
        self.calendar = calendar
        self.viewMode = TimelineViewMode(rawValue: defaults.string(forKey: "timeline.viewMode.\(host.rawValue)") ?? "") ?? .compact
        self.groupByApp = defaults.bool(forKey: "timeline.groupByApp.\(host.rawValue)")
        self.unreadAnchor = UnixDate(Date(timeIntervalSince1970: defaults.double(forKey: "timeline.lastSeenAt")))
        startObserving()
    }

    // MARK: Live first page + badge

    private func startObserving() {
        observation?.cancel()
        observation = Task {
            let stream = ValueObservation
                .tracking { db -> (page: [ArchivedNotification], unread: Int) in
                    let page = try ArchivedNotification.recent(limit: Self.pageSize).fetchAll(db)
                    // Badge: unread, not muted, delivered since the anchor. Muted apps never count.
                    let unread = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM notifications n
                        JOIN apps a ON a.id = n.app_id
                        WHERE n.is_deleted = 0 AND n.is_read = 0 AND a.is_muted = 0
                          AND n.delivered_at > ?
                        """, arguments: [self.unreadAnchor.date.timeIntervalSince1970]) ?? 0
                    return (page, unread)
                }
                .values(in: archive.pool)
            do {
                for try await (page, unread) in stream {
                    mergeFirstPage(page)
                    unreadBadgeCount = min(unread, 100)            // display renders 100 as "99+"
                    loadError = nil
                }
            } catch {
                // Archive read failure: banner, never crash. Rows already loaded stay visible.
                loadError = ArchiveError.observationFailed(String(describing: error)).userMessage
            }
        }
    }

    public func retry() {
        loadError = nil
        startObserving()
    }

    /// The live observation replaces the newest page; older, paginated rows are kept.
    private func mergeFirstPage(_ page: [ArchivedNotification]) {
        guard let oldestNew = page.last else {
            rows = []
            cursor = nil
            hasMorePages = false
            regroup()
            return
        }
        let older = rows.drop { row in
            (row.deliveredAt, row.id ?? 0) >= (oldestNew.deliveredAt, oldestNew.id ?? 0)
        }
        rows = page + Array(older)
        if rows.count > Self.maxRows {                              // bounded memory
            rows.removeLast(rows.count - Self.maxRows)
            cursor = rows.last.map { TimelineCursor(deliveredAt: $0.deliveredAt.date.timeIntervalSince1970, id: $0.id ?? 0) }
            hasMorePages = true
        }
        regroup()
    }

    // MARK: Unread anchor

    /// Called by StatusItemController before showing the popover: snapshot, then advance.
    public func popoverWillOpen() {
        let sessionEnd = (try? archive.lastAwaySessionEnd()) ?? nil
        let anchor = max(unreadAnchor, sessionEnd ?? unreadAnchor)  // later of the two
        unreadAnchor = anchor
        regroup()                                                   // divider position uses the snapshot
    }

    public func popoverDidClose() {
        defaults.set(Date().timeIntervalSince1970, forKey: "timeline.lastSeenAt")
        unreadAnchor = .now
        unreadBadgeCount = 0
    }
}
```

### Keyset pagination

Pages of 200, never `OFFSET`; the key is the pair `(delivered_at, id)` because bursts share a second. `Archive.timelinePage(after:limit:)` is defined in `BackglanceCore` and measured at < 2 ms per page at 100k notifications ([../deployment/PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md)).

```swift
// TimelineStore, continued
extension TimelineStore {
    /// Appends the next page when the scroll sentinel appears. Errors banner; they never crash.
    public func loadNextPage() async {
        guard hasMorePages, !isLoadingPage else { return }
        isLoadingPage = true
        defer { isLoadingPage = false }

        // Continue from the oldest row we hold (covers the first, observation-fed page too).
        let after = cursor ?? rows.last.map {
            TimelineCursor(deliveredAt: $0.deliveredAt.date.timeIntervalSince1970, id: $0.id ?? 0)
        }
        do {
            let page = try await Task.detached { [archive] in       // pool.read off the main actor
                try archive.timelinePage(after: after, limit: Self.pageSize)
            }.value
            guard !page.isEmpty else {
                hasMorePages = false
                return
            }
            let known = Set(rows.compactMap(\.id))
            rows.append(contentsOf: page.filter { $0.id.map { !known.contains($0) } ?? true })
            cursor = page.last.map {
                TimelineCursor(deliveredAt: $0.deliveredAt.date.timeIntervalSince1970, id: $0.id ?? 0)
            }
            hasMorePages = page.count == Self.pageSize
            if rows.count > Self.maxRows {                          // drop from the top; scroll-up refetches via observation
                rows.removeFirst(rows.count - Self.maxRows)
            }
            regroup()
        } catch {
            loadError = ArchiveError.observationFailed(String(describing: error)).userMessage
        }
    }
}
```

### Grouping

Grouping is pure and synchronous over the in-memory rows (≤ 1,000), so it runs on the main actor without jank. Day boundaries use the *user's current* calendar and time zone at render time.

```swift
// TimelineStore, continued
extension TimelineStore {
    private func regroup() {
        var filtered = rows.filter { !($0.isDeleted) }
        if !appFilter.isEmpty {
            filtered = filtered.filter { appFilter.contains(bundleID(for: $0.appId)) }
        }
        let triaged = filtered.map { row in
            TimelineItem(id: row.id ?? 0, notification: row,
                         appName: displayName(for: row.appId),
                         triage: rules.evaluate(row),               // cached per (rowID, rulesVersion)
                         isSelected: row.id == selectedID)
        }
        sections = Self.buildSections(items: triaged, groupByApp: groupByApp,
                                      mutedBundleIDs: mutedBundleIDs(),
                                      anchor: unreadAnchor, calendar: calendar)
    }

    static func buildSections(items: [TimelineItem], groupByApp: Bool,
                              mutedBundleIDs: Set<String>, anchor: UnixDate,
                              calendar: Calendar) -> [TimelineSection.Model] {
        // 1. Day buckets, newest day first; items inside stay newest-first.
        let byDay = Dictionary(grouping: items) {
            calendar.startOfDay(for: $0.notification.deliveredAt.date)
        }
        return byDay.keys.sorted(by: >).map { day in
            var dayItems = byDay[day]!
            // 2. Pinned VIP first within the day, stable otherwise.
            let pinned = dayItems.filter { $0.triage.pinned || $0.notification.isPinned }
            dayItems = pinned + dayItems.filter { !($0.triage.pinned || $0.notification.isPinned) }
            // 3. Muted collapse into one trailing "Muted (n)" group.
            let muted = dayItems.filter { $0.triage.muted }
            let normal = dayItems.filter { !$0.triage.muted }
            // 4. Slots: divider before the first item at/below the anchor, app headers if enabled.
            var slots: [TimelineSection.Slot] = []
            var dividerPlaced = false
            func emit(_ item: TimelineItem) {
                if !dividerPlaced, item.notification.deliveredAt <= anchor,
                   normal.first.map({ $0.notification.deliveredAt > anchor }) == true {
                    slots.append(.divider)
                    dividerPlaced = true
                }
                slots.append(.row(item))
            }
            if groupByApp {
                for group in Dictionary(grouping: normal, by: \.appName).sorted(by: { $0.key < $1.key }) {
                    slots.append(.appHeader(.init(name: group.key, count: group.value.count, isMuted: false)))
                    group.value.forEach(emit)
                }
            } else {
                normal.forEach(emit)
            }
            if !muted.isEmpty {
                slots.append(.appHeader(.init(name: String(localized: "Muted (\(muted.count))"),
                                              count: muted.count, isMuted: true)))
                // Muted rows render only when the group is expanded; collapsed by default.
            }
            return TimelineSection.Model(id: day, title: DayTitle.string(for: day, calendar: calendar), slots: slots)
        }
    }
}
```

### Triage in the timeline

Triage is computed at read time — never stored — so editing a rule re-triages all of history instantly:

- **Pinned / VIP** (`Triage.pinned`, or the user's manual `is_pinned`): float to the top of their day, pin glyph.
- **Muted** (`Triage.muted` or `apps.is_muted`): collapsed into a trailing "Muted (n)" group per day; excluded from the badge; expandable per day, or globally via the "Muted" filter chip.
- **Highlight** (`Triage.highlight`): row background tint from the rule's color token (e.g. `amber`).

Rules never change what macOS delivers — visual triage only ([RULES.md](./RULES.md)).

### Read state and the unread badge

| Event | Effect |
|---|---|
| Row fully visible ≥ 1 s | `is_read = 1` (a per-row `Task.sleep(1 s)` started in `onAppear`, cancelled in `onDisappear`) |
| Row opened (↩, click) | `is_read = 1` immediately |
| "Mark all read" | one `UPDATE notifications SET is_read = 1 WHERE is_read = 0 AND is_deleted = 0` |
| Thread update with changed text | capture resets `is_read = 0` ([CAPTURE.md](./CAPTURE.md#dedupe-and-thread-updates)) |
| Popover closes | anchor advances; badge resets to 0 |

The badge counts `is_read = 0 AND is_muted = 0 AND delivered_at > anchor`, capped at "99+". Marking read is a plain archive write; the observation echoes it back to every open surface, so the popover and the window can never disagree.

```swift
// TimelineStore, continued — visibility-based read state
extension TimelineStore {
    public func rowBecameVisible(_ id: Int64) {
        guard visibilityTimers[id] == nil else { return }
        visibilityTimers[id] = Task { [archive] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            do {
                try archive.markRead(id)                            // no-op if already read
            } catch {
                // A failed read-flag write is not worth a banner; retried next visibility.
            }
        }
    }

    public func rowBecameHidden(_ id: Int64) {
        visibilityTimers.removeValue(forKey: id)?.cancel()
    }
}
```

### View mode persistence

`timeline.viewMode.popover`, `timeline.viewMode.window`, `timeline.groupByApp.popover`, `timeline.groupByApp.window` in `UserDefaults` (suite `app.backglance.Backglance`). Defaults: popover compact/flat, window detailed/flat. The popover and window deliberately remember different modes — glancing and reading are different jobs.

### Window management

`TimelineWindowController` owns a single `NSWindow` (created lazily, reused):

```swift
// Backglance/Scenes/TimelineWindow/TimelineWindowController.swift (core)
import AppKit
import SwiftUI
import BackglanceUI

@MainActor
final class TimelineWindowController: NSWindowController {
    convenience init(store: TimelineStore) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Backglance"
        window.minSize = NSSize(width: 480, height: 360)
        window.setFrameAutosaveName("TimelineWindow")               // AppKit restores the frame
        window.contentViewController = NSHostingController(rootView: TimelineView().environment(store))
        window.isReleasedWhenClosed = false                          // reuse; state survives close
        self.init(window: window)
    }

    func show() {
        NSApp.activate()                                             // LSUIElement app: activate explicitly
        window?.makeKeyAndOrderFront(nil)
    }
}
```

Closing hides; the store keeps observing so reopening is instant. Because Backglance is `LSUIElement`, the window never creates a Dock icon.

## Performance

Budgets from [../deployment/PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md): popover open-to-first-paint < 100 ms; 60 fps scroll; store holds ≤ 1,000 rows (~1 MB).

- **Lazy stack, stable IDs.** `LazyVStack` + `ForEach(…, id: \.id)` with `Int64` archive ids — never indices, never `UUID()` — so SwiftUI diffs 200 rows in < 5 ms.
- **No body measurement in compact.** Compact rows are single-line title-only; the body string is not even passed to a `Text`.
- **First page always warm.** The `ValueObservation` keeps the newest 200 rows in memory; opening the popover performs zero queries.
- **One clock.** A single 30 s ticker refreshes relative times; rows hold no timers, so the app stays eligible for App Nap.
- **Icons from `NSCache`.** Rows never call `NSWorkspace`; `EnrichmentService`'s cache is warmed at capture time.
- **Fixed popover size.** `hosting.sizingOptions = []` prevents `NSHostingView` resize thrash.

## Accessibility

Every row is one combined accessibility element ("Slack, unread, Deploy finished, 14:32"); the unread divider is a header ("New notifications since you were away start here"); day headers are headers, so VoiceOver users can rotor between days. Full keyboard operation is listed under [Keyboard navigation](#keyboard-navigation); Reduce Motion disables the (already minimal) popover animation; Increase Contrast swaps highlight tints for borders. The complete audit checklist, VoiceOver scripts and Dynamic Type behaviour live in [../reference/ACCESSIBILITY.md](../reference/ACCESSIBILITY.md).

## Edge Cases and Error Handling

Empty states — one `EmptyStateView(kind:)`, four kinds, exact copy:

| Kind | When | Copy |
|---|---|---|
| `.noFullDiskAccess` | `CaptureStatus == .degraded(.noFullDiskAccess)` and archive empty | "Backglance can't read notifications yet." + "Grant Full Disk Access…" button |
| `.paused` | `.paused` and nothing since | "Capture is paused." + "Resume" button + "Notifications that arrive while paused are not archived." |
| `.nothingYet` | running, archive empty | "Nothing here yet. New notifications will appear as they arrive." |
| `.allFiltered` | rows exist, filter/search matches none | "No notifications match. " + "Clear filters" button |

Other edge cases:

| Case | Behaviour |
|---|---|
| Archive read failure (`ValueObservation` throws, page fetch throws) | `ArchiveHealthBanner` with `ArchiveError.userMessage` + Retry; already-loaded rows stay; never a crash, never a modal |
| Time zone / calendar change while open | `NSSystemTimeZoneDidChange` triggers `regroup()`; day buckets and headers recompute; rows do not move in the archive (`delivered_at` is absolute) |
| Clock jumps backwards | "Today" may briefly contain future-dated rows; grouping uses `startOfDay` so they sort first and stay visible |
| Very long bodies (10k+ chars) | Detailed rows cap at `lineLimit(4)`; full text only in the detail popout, in a scroll view; compact never touches the body |
| RTL locales | Layout uses leading/trailing throughout; timestamps use `.monospacedDigit`; mixed-direction titles rely on `Text`'s Unicode bidi handling — no manual overrides ([../reference/INTERNATIONALIZATION.md](../reference/INTERNATIONALIZATION.md)) |
| 10k notifications in one day | One section, paginated slots; day header sticks (`pinnedViews`); grouping stays O(n) over ≤ 1,000 in-memory rows; the rest arrives page by page |
| Row deleted elsewhere while selected | Observation removes it; selection moves to the nearest surviving row |
| Notification with empty title and body | Renders "(no text)" with app and time (capture usually filters these; imports may contain them) |
| Badge overflow | Count query capped at 100; renders "99+" |

> ✅ **Do:** treat every failure on the read path as a banner state. The timeline must render *something* — an empty state, a stale page with a banner — for any combination of archive health, capture status and permissions.

## Testing Approach

| Suite | Target | What it proves |
|---|---|---|
| `TimelineGroupingTests` | `BackglanceCoreTests` / `BackglanceUITests` (pure logic) | Day bucketing across midnight, DST transitions, and time zone changes (fixed `Calendar` with explicit `TimeZone`); pinned-first ordering; muted collapse counts; divider position for: anchor mid-page, anchor before everything (no divider), anchor after everything |
| `DayTitleTests` | same | "Today"/"Yesterday"/weekday/full-date thresholds with a frozen `now`, in `en`, `tr`, `de` and an RTL locale |
| `TimelinePaginationTests` | `BackglanceCoreTests` | Keyset pages of 200 over a 10k-row in-memory archive: no gaps, no duplicates across page joins, burst rows sharing one `delivered_at` split correctly by `id`; empty page flips `hasMorePages` |
| `TimelineStoreTests` | `BackglanceUITests` (logic) | `mergeFirstPage` keeps paginated tail; 1,000-row cap; badge excludes muted and read; `popoverWillOpen` snapshots before advancing; read-state timer cancels on disappear |
| `TimelineKeyboardUITests` | `BackglanceUITests` (XCUITest) | ↑↓ selection skips headers and divider; ↩ marks read; ⌫ deletes and moves selection; ⌘C copies redacted text as redacted; Esc order (clear search → close); ⌘↩ opens the window |
| `EmptyStateUITests` | XCUITest | Each of the four kinds renders its exact copy under injected `CaptureStatus` + archive contents |

```swift
// Tests/BackglanceUITests/TimelineGroupingTests.swift (excerpt)
import XCTest
@testable import BackglanceUI
@testable import BackglanceCore

final class TimelineGroupingTests: XCTestCase {
    func testDividerLandsAtFirstRowAfterAnchor() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        let anchor = UnixDate(Date(timeIntervalSince1970: 1_755_400_000))
        let items = TimelineFixtures.items(around: anchor, newer: 3, older: 2)   // seeded, synthetic text

        let sections = TimelineStore.buildSections(items: items, groupByApp: false,
                                                   mutedBundleIDs: [], anchor: anchor,
                                                   calendar: calendar)

        let slots = sections.flatMap(\.slots)
        let dividerIndex = try XCTUnwrap(slots.firstIndex(of: .divider))
        // Three newer rows above the divider, two older below.
        XCTAssertEqual(dividerIndex, 3)
        XCTAssertEqual(slots.filter { $0 == .divider }.count, 1, "never more than one divider")
    }

    func testNoDividerWhenNothingIsNew() {
        let anchor = UnixDate.now
        let items = TimelineFixtures.items(around: anchor, newer: 0, older: 5)
        let sections = TimelineStore.buildSections(items: items, groupByApp: false,
                                                   mutedBundleIDs: [], anchor: anchor,
                                                   calendar: .current)
        XCTAssertFalse(sections.flatMap(\.slots).contains(.divider))
    }
}
```

Pagination tests run against `Archive(inMemory: true)` seeded with 10k synthetic rows (seeded RNG, text like `Fixture message 000042`); UI tests run against a temp on-disk archive so the app under test opens it normally. See [../testing/TESTING.md](../testing/TESTING.md).

## Next Steps

- [SEARCH.md](./SEARCH.md) — the search field's query language and ranking.
- [ACTIONS.md](./ACTIONS.md) — what ↩, the context menu and deep links actually do.
- [MISSED_DIGEST.md](./MISSED_DIGEST.md) — how away sessions feed the unread anchor and the digest.

## Related Documentation

- [CAPTURE.md](./CAPTURE.md)
- [SEARCH.md](./SEARCH.md)
- [ACTIONS.md](./ACTIONS.md)
- [RULES.md](./RULES.md)
- [MISSED_DIGEST.md](./MISSED_DIGEST.md)
- [PERMISSIONS_PRIVACY.md](./PERMISSIONS_PRIVACY.md)
- [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md)
- [../architecture/ARCHITECTURE.md](../architecture/ARCHITECTURE.md)
- [../architecture/DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md)
- [../deployment/PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md)
- [../reference/ACCESSIBILITY.md](../reference/ACCESSIBILITY.md)
- [../reference/INTERNATIONALIZATION.md](../reference/INTERNATIONALIZATION.md)
- [../testing/TESTING.md](../testing/TESTING.md)
