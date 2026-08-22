# Actions

Last Updated: 2026-08-18

This document specifies everything a user can *do* with an archived notification in Backglance v1.0: open the source app or a deep link, copy the text, delete (with undo), select and export, pin, mark read/unread, mute the app in the timeline, and jump to the app's page in System Settings ▸ Notifications. It covers the context menu and keyboard shortcuts, the `NotificationActionHandler` that backs both, the archive columns each action touches, the error paths, and how the actions are tested. Rules (highlight / VIP / mute) have their own settings surface and engine and are documented separately in [RULES.md](./RULES.md); the "Mute this app" action here simply delegates to that engine.

## Table of Contents

- [Feature Overview](#feature-overview)
- [Architecture](#architecture)
- [Archive Tables Involved](#archive-tables-involved)
- [UI Components](#ui-components)
  - [Context Menu Specification](#context-menu-specification)
  - [Keyboard Shortcuts](#keyboard-shortcuts)
  - [Selection Model](#selection-model)
  - [Undo Toast](#undo-toast)
- [Business Logic](#business-logic)
  - [Open (OpenAction and DeepLinkResolver)](#open-openaction-and-deeplinkresolver)
  - [Copy](#copy)
  - [Delete and Undo](#delete-and-undo)
  - [Select and Export](#select-and-export)
  - [Pin, Unpin, Read, Unread](#pin-unpin-read-unread)
  - [Mute This App in Timeline](#mute-this-app-in-timeline)
  - [Open in System Settings ▸ Notifications](#open-in-system-settings--notifications)
- [NotificationActionHandler](#notificationactionhandler)
- [Edge Cases and Error Handling](#edge-cases-and-error-handling)
- [Testing Approach](#testing-approach)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Feature Overview

Every action is available from three places that share one implementation: the row context menu (right-click / Control-click), keyboard shortcuts while a row is focused, and the row hover buttons in the popover. The same `NotificationActionHandler` runs behind all three so behaviour never diverges between the menu bar popover and the full timeline window.

| Action | v1.0 | Scope | Reversible | Touches |
|---|---|---|---|---|
| Open source app / deep link | ✅ | single | n/a | reads `notifications.deep_link`, `apps.bundle_id` |
| Copy text | ✅ | single or selection | n/a | reads only |
| Delete | ✅ | single or selection | undo toast, 5 s | `notifications.is_deleted` |
| Select and export (CSV / JSON) | ✅ (selection + visible filter) | selection | n/a | reads only |
| Pin / Unpin | ✅ | single or selection | toggle | `notifications.is_pinned` |
| Mark read / unread | ✅ | single or selection | toggle | `notifications.is_read` |
| Mute this app in timeline | ✅ | app | toggle | `apps.is_muted` (via [RULES.md](./RULES.md)) |
| Open in System Settings ▸ Notifications | ✅ | app | n/a | none |
| Snooze / bring back later | v1.x | single | cancel | `snoozes` — see [SNOOZE_RESURFACE.md](./SNOOZE_RESURFACE.md) |
| Date-range / automated export | v1.x | archive | n/a | see [EXPORT_AUTOMATION.md](./EXPORT_AUTOMATION.md) |

> ℹ️ **Info:** None of these actions touch Apple's system store. Backglance only ever reads the store (see [CAPTURE.md](./CAPTURE.md)); deleting a notification in Backglance deletes it from Backglance's archive, nothing else.

## Architecture

```
┌──────────────────────────── BackglanceUI ─────────────────────────────┐
│  NotificationRow ── context menu ─┐                                    │
│  TimelineView    ── key handling ─┼──► NotificationActionHandler       │
│  Popover / Window toolbar ────────┘        (BackglanceUI, @MainActor)  │
└───────────────────────────────────────────────┬────────────────────────┘
                                                │
             ┌──────────────────────────────────┼──────────────────────────────┐
             ▼                                  ▼                              ▼
   OpenAction (AppKit)               CopyAction (NSPasteboard)      Archive (BackglanceCore, GRDB)
   • deep_link → NSWorkspace.open    • "Title — Body"               • is_deleted / is_pinned / is_read
   • else activate by bundle id      • optional app + timestamp     • apps.is_muted (RulesEngine)
   • else ActionError.appNotInstalled                               • ExportService (CSV/JSON)
             ▲
             │ deep_link was written at capture time by
   EnrichmentService (BackglanceCapture)
   • DeepLinkResolverRegistry → per-app DeepLinkResolver
   • generic userInfo URL scan
```

Deep links are resolved once, at capture time, by `EnrichmentService` in `BackglanceCapture` and stored in `notifications.deep_link`. `OpenAction` at click time only decides between "open that URL" and "activate the app". This keeps the click path fast (no plist parsing on the main thread) and means a resolver bug is fixed by re-running enrichment, not by touching UI code.

## Archive Tables Involved

Only the `notifications` and `apps` tables are written by actions. Column names are the canonical ones from [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md).

| Table.column | Type | Written by | Notes |
|---|---|---|---|
| `notifications.is_deleted` | INTEGER 0/1 | Delete / Undo | Soft delete. Rows stay until the retention job hard-prunes them; FTS row is removed by the `notifications_au` trigger only on hard delete, so the timeline and search both filter `is_deleted = 0` explicitly. |
| `notifications.is_pinned` | INTEGER 0/1 | Pin / Unpin | Manual pin. Independent of VIP pinning from rules (which is computed, not stored). |
| `notifications.is_read` | INTEGER 0/1 | Mark read / unread, Open | Opening a notification marks it read. Feeds the unread badge. |
| `notifications.deep_link` | TEXT | Enrichment (capture) | Read by Open. `NULL` when no resolver produced a URL. |
| `apps.is_muted` | INTEGER 0/1 | Mute this app | Visual only; documented in [RULES.md](./RULES.md). |
| `apps.bundle_id` | TEXT | — | Read by Open and by the System Settings deep link. |

Actions never write to `rules`, `digests`, `away_sessions` or `redactions`. Deleting a notification cascades to `digest_items`, `redactions`, `snoozes` and `embeddings` only at *hard* delete time (the `ON DELETE CASCADE` foreign keys), which is why undo is cheap: a soft-deleted row is a single flag flip.

## UI Components

| Component | Module | Role |
|---|---|---|
| `NotificationRow` | `BackglanceUI` | Row view; owns the `.contextMenu` and hover buttons; forwards to the handler via an `ActionDispatching` environment value |
| `TimelineView` | `BackglanceUI` | Selection state, key equivalents (`.onKeyPress`), undo toast host |
| `NotificationActionHandler` | `BackglanceUI` | `@MainActor` coordinator; the only place that talks to `NSWorkspace`, `NSPasteboard`, `NSSavePanel` |
| `UndoToastView` | `BackglanceUI` | Bottom-anchored toast with an "Undo" button and a 5 s countdown |
| `ExportSheet` | `BackglanceUI` | Format picker (CSV / JSON) and "Include redacted placeholders as-is" note, then `NSSavePanel` |

The popover and the full window use the same row and the same handler; the only difference is that multi-select is enabled only in the full window (the popover is single-selection to keep it a quick glance).

`NotificationActionHandler` lives in `BackglanceUI` rather than the app target: the app target ships only an XCUITest bundle, which cannot unit-test a class in isolation, and a coordinator this central needs that — see `Tests/BackglanceUITests/NotificationActionHandlerTests.swift`.

### Context Menu Specification

Menu items appear in this order. "Condition" is evaluated per right-click; items whose condition is false are hidden, not disabled, except where noted.

| # | Item | Condition | Shortcut | Result |
|---|---|---|---|---|
| 1 | **Open in ‹App›** | always; label uses `apps.display_name`; disabled with tooltip "App not found" if the bundle id does not resolve | ↩ | `OpenAction.run` |
| 2 | Open Link | `deep_link` is non-nil and differs from plain app activation (i.e. has a path/query) | ⌘↩ | `NSWorkspace.shared.open(url)` only, no app fallback |
| — | separator | | | |
| 3 | Copy | always | ⌘C | "Title — Body" to the general pasteboard |
| 4 | Copy with App and Time | always | ⌥⌘C | "‹App› · 2026-08-17 14:03\nTitle — Body" |
| — | separator | | | |
| 5 | Pin / Unpin | always (label toggles) | ⇧⌘P | flip `is_pinned` |
| 6 | Mark as Read / Mark as Unread | always (label toggles) | ⇧⌘U | flip `is_read` |
| 7 | Snooze… | v1.x only | — | see [SNOOZE_RESURFACE.md](./SNOOZE_RESURFACE.md) |
| — | separator | | | |
| 8 | Mute ‹App› in Timeline / Unmute ‹App› | always (label toggles) | ⇧⌘M | delegates to `RulesEngine` mute (see [RULES.md](./RULES.md)) |
| 9 | Notification Settings for ‹App›… | always | — | System Settings deep link, per-version URL |
| — | separator | | | |
| 10 | Export Selection… | full window only; selection ≥ 1 | ⌘E | `ExportSheet` → `ExportService` |
| 11 | Delete | always; label becomes "Delete 3 Notifications" for multi-select | ⌫ | soft delete + undo toast |

When several rows are selected, items 3–6, 10 and 11 act on the whole selection; items 1, 2, 8 and 9 act on the row that was right-clicked (its app), and the menu title row shows "3 selected".

### Keyboard Shortcuts

Shortcuts are active whenever a row is focused in the popover or the window. They are `KeyboardShortcut` values in SwiftUI (`.keyboardShortcut(.return)`, `.keyboardShortcut("c", modifiers: .command)`, and so on) attached to hidden menu commands so they also show up in the app's Edit menu when the full window is frontmost.

| Keys | Action | Notes |
|---|---|---|
| ↩ | Open | marks read |
| ⌘↩ | Open Link only | no app fallback; beeps if no deep link (the full window's own binding — the popover binds ⌘↩ to "Open the full window" per [TIMELINE.md](./TIMELINE.md#keyboard-navigation)) |
| ⌘C | Copy | plain "Title — Body" |
| ⌥⌘C | Copy with App and Time | |
| ⌫ / ⌦ | Delete | soft delete, undo toast |
| ⌘Z | Undo delete | while the toast is visible |
| ⇧⌘P | Pin / Unpin | |
| ⇧⌘U | Mark read / unread | |
| ⇧⌘M | Mute / unmute app in timeline | |
| ⌘E | Export Selection… | window only |
| ⌘A | Select all visible rows | window only |
| ⌘-click / ⇧-click | Toggle / range select | window only |
| Esc | Clear selection, or close popover if nothing selected | |
| ⌃⌥N | Toggle popover (global) | see [TIMELINE.md](./TIMELINE.md) |

### Selection Model

The full timeline window keeps a `Set<Int64>` of selected notification ids plus an "anchor" id for ⇧-click ranges. Ranges are computed over the *currently visible* ordering (after filters, muted groups collapsed), so a range never silently includes hidden rows. Selection is cleared when the filter changes. The popover has a single focused row and no multi-select.

### Undo Toast

Deleting shows a toast anchored at the bottom of the timeline: "Deleted 1 notification · Undo". It stays for 5 seconds (or until the next delete, which replaces its contents and restarts the timer). ⌘Z while the toast is visible is equivalent to clicking Undo. When the toast expires nothing else happens: the rows stay soft-deleted (`is_deleted = 1`) and the retention job hard-deletes them on its next run (see [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md)).

## Business Logic

### Open (OpenAction and DeepLinkResolver)

Order of preference on click:

1. `notifications.deep_link` present → `NSWorkspace.shared.open(url)`. If that returns `false` (no handler registered any more, e.g. app uninstalled) fall through.
2. Activate the app: `urlForApplication(withBundleIdentifier:)` → `openApplication(at:configuration:)` with `activates = true`.
3. Neither works → `ActionError.appNotInstalled`. The UI shows "App not found" inline and offers **Copy** so the text is still usable. We deliberately do not offer "Search App Store"; many notifying apps are not on the App Store and a wrong guess would be worse than an honest message.

Deep links are produced at capture time by resolvers registered in `DeepLinkResolverRegistry`. A resolver gets the `ParsedNotification` (which still has `userInfo`) and returns a URL or `nil`.

```swift
// Packages/BackglanceCapture/Sources/BackglanceCapture/Enrichment/DeepLinkResolver.swift
import Foundation

/// Produces a URL that reopens the context of one notification.
/// Resolvers run at capture time; the result is stored in `notifications.deep_link`.
public protocol DeepLinkResolver: Sendable {
    /// Bundle identifiers this resolver handles. Empty set = generic fallback.
    static var bundleIDs: Set<String> { get }
    func resolve(_ n: ParsedNotification) -> URL?
}

public struct DeepLinkResolverRegistry: Sendable {
    private let specific: [String: any DeepLinkResolver]
    private let generic: any DeepLinkResolver

    public init(resolvers: [any DeepLinkResolver], generic: any DeepLinkResolver = GenericURLResolver()) {
        var map: [String: any DeepLinkResolver] = [:]
        for r in resolvers {
            for id in type(of: r).bundleIDs { map[id] = r }
        }
        self.specific = map
        self.generic = generic
    }

    public static let `default` = DeepLinkResolverRegistry(resolvers: [
        MessagesResolver(), MailResolver(), SlackResolver(), DiscordResolver(),
        TeamsResolver(), SafariWebPushResolver(), CalendarResolver(), RemindersResolver(),
    ])

    /// Per-app resolver first, then the generic scan. Never throws: enrichment must not block capture.
    public func resolve(_ n: ParsedNotification) -> URL? {
        if let r = specific[n.bundleID], let url = r.resolve(n) { return url }
        return generic.resolve(n)
    }
}
```

The generic resolver scans `userInfo` values for something that parses as a URL whose scheme has a registered handler on this Mac.

```swift
public struct GenericURLResolver: DeepLinkResolver {
    public static let bundleIDs: Set<String> = []
    public init() {}

    public func resolve(_ n: ParsedNotification) -> URL? {
        // Keys are sorted so the result is deterministic across runs.
        for key in n.userInfo.keys.sorted() {
            guard let value = n.userInfo[key],
                  let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = url.scheme?.lowercased(),
                  scheme != "file",                                       // never open arbitrary local files
                  NSWorkspace.shared.urlForApplication(toOpen: url) != nil // handler exists
            else { continue }
            return url
        }
        return nil
    }
}
```

Per-app resolvers and their honesty level:

| App | Bundle id | URL produced | Confidence |
|---|---|---|---|
| Messages | `com.apple.MobileSMS` | `imessage://<handle>` (falls back to `sms:<handle>`) when a sender handle (phone or email) is present; else `nil` → activate Messages | ⚠️ handle key is undocumented; observed only in fixtures |
| Mail | `com.apple.mail` | `message://%3C<message-id>%3E` when a Message-ID is present in `userInfo` | ⚠️ the Message-ID is **often absent** from the store payload; expect `nil` most of the time → activate Mail |
| Slack | `com.tinyspeck.slackmacgap` | `slack://…` or `https://app.slack.com/…` from `userInfo` | medium; depends on Slack build |
| Discord | `com.hnc.Discord` | `discord://…` from `userInfo` | medium |
| Teams | `com.microsoft.teams2` | `msteams:…` from `userInfo` | medium |
| Safari web push | `com.apple.Safari`, `com.apple.Safari.WebApp.*` | the site URL from `userInfo` | medium |
| Calendar | `com.apple.iCal` | `ical://` (opens Calendar; no per-event URL is derivable in v1.0) | high but shallow |
| Reminders | `com.apple.reminders` | `x-apple-reminderkit://` (opens Reminders; per-item only when an identifier is present) | ⚠️ per-item is best-effort |

```swift
public struct MessagesResolver: DeepLinkResolver {
    public static let bundleIDs: Set<String> = ["com.apple.MobileSMS"]
    public init() {}

    public func resolve(_ n: ParsedNotification) -> URL? {
        // ⚠️ Undocumented: the sender handle has been observed under these keys in fixtures.
        let candidates = [n.userInfo["senderHandle"], n.userInfo["handle"], n.sender]
        guard let handle = candidates.compactMap({ $0 }).first(where: Self.looksLikeHandle),
              let encoded = handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "imessage://\(encoded)") ?? URL(string: "sms:\(encoded)")
    }

    /// Phone number ("+1 555 0100") or email ("name@example.com"); display names are rejected.
    static func looksLikeHandle(_ s: String) -> Bool {
        if s.contains("@") { return s.split(separator: "@").count == 2 }
        let digits = s.filter(\.isNumber)
        return digits.count >= 7 && s.allSatisfy { $0.isNumber || " +-()".contains($0) }
    }
}

public struct MailResolver: DeepLinkResolver {
    public static let bundleIDs: Set<String> = ["com.apple.mail"]
    public init() {}

    public func resolve(_ n: ParsedNotification) -> URL? {
        // ⚠️ Often absent. When present the value looks like "<id@example.com>".
        guard var mid = n.userInfo["messageID"] ?? n.userInfo["message-id"] else { return nil }
        if !mid.hasPrefix("<") { mid = "<\(mid)>" }
        guard let encoded = mid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "message://\(encoded)")
    }
}
```

`OpenAction` itself lives in the app target because it needs AppKit:

```swift
// Backglance/Scenes/TimelineWindow/Actions/OpenAction.swift
import AppKit
import BackglanceCore

@MainActor
struct OpenAction {
    var workspace: NSWorkspace = .shared

    /// Opens the deep link when there is one, otherwise activates the app.
    /// - Throws: `ActionError.appNotInstalled` when neither path works.
    func run(_ n: ArchivedNotification, app: AppRecord) async throws {
        if let raw = n.deepLink, let url = URL(string: raw) {
            if workspace.open(url) { return }      // false = no handler; fall through, don't fail yet
        }
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: app.bundleID) else {
            throw ActionError.appNotInstalled(bundleID: app.bundleID)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await workspace.openApplication(at: appURL, configuration: config)
        } catch {
            throw ActionError.launchFailed(bundleID: app.bundleID, reason: error.localizedDescription)
        }
    }

    /// ⌘↩: the deep link only, no app fallback.
    func openLinkOnly(_ n: ArchivedNotification) throws {
        guard let raw = n.deepLink, let url = URL(string: raw), workspace.open(url) else {
            throw ActionError.deepLinkUnresolvable(notificationID: n.id ?? -1)
        }
    }
}
```

### Copy

⌘C copies plain text in the form `Title — Body` (em dash with spaces). Missing parts are dropped: a notification with no title copies just the body. ⌥⌘C prefixes a line with the app name and a local timestamp. Redacted content is copied exactly as stored, i.e. the placeholder `[code redacted]` — the original digits were never written to the archive, so there is nothing else to copy (see [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md)).

```swift
// Packages/BackglanceUI/Sources/BackglanceUI/Actions/CopyAction.swift
import AppKit
import BackglanceCore

struct CopyAction {
    var includeAppAndTimestamp = false
    /// `PasteboardWriting`, not `NSPasteboard`: a private named pasteboard conforms
    /// as-is, and the one test that must force a refused write needs a fake.
    var pasteboard: any PasteboardWriting = NSPasteboard.general
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // a fixed dateFormat still reads the locale's calendar
        f.dateFormat = "yyyy-MM-dd HH:mm"      // local time, unambiguous, sorts well when pasted in a sheet
        return f
    }()

    func text(for n: ArchivedNotification, app: AppRecord) -> String {
        let parts = [n.title, n.body].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                                     .filter { !$0.isEmpty }
        let line = parts.joined(separator: " — ")
        guard includeAppAndTimestamp else { return line }
        let name = app.displayName ?? app.bundleId
        return "\(name) · \(Self.stamp.string(from: n.deliveredAt.date))\n\(line)"
    }

    /// Multi-select: one block per notification, separated by a blank line.
    /// The write goes through `PasteboardCopier`, never straight to the pasteboard —
    /// that is what keeps the concealed marker from being forgotten here.
    func run(_ items: [(ArchivedNotification, AppRecord)]) throws {
        let joined = items.map { text(for: $0.0, app: $0.1) }.joined(separator: "\n\n")
        guard PasteboardCopier.copyConcealed(joined, to: pasteboard) else {
            throw ActionError.pasteboardFailure
        }
    }
}
```

> 🔒 **Security:** Backglance marks every copy it makes with `org.nspasteboard.ConcealedType` (the nspasteboard.org convention), so clipboard managers that honour it — PasteShelf's clipboard monitor is one — skip the item, while managers that ignore the marker still see it, which is the expected behaviour for an explicit ⌘C. Backglance never reads the pasteboard back. See [SECURITY.md#concealed-pasteboard-copies](../security/SECURITY.md#concealed-pasteboard-copies).

### Delete and Undo

Delete is a soft delete: `UPDATE notifications SET is_deleted = 1 WHERE id IN (…)`. Undo flips it back. Nothing is physically removed until the retention job's next hard-prune pass, which deletes rows with `is_deleted = 1` regardless of their age. Consequences worth stating plainly:

- A soft-deleted row is still on disk until the retention job runs (every 15 minutes while the app is running, and at launch). Panic wipe removes everything immediately (see [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md)).
- Soft-deleted rows are excluded from the timeline, search, digest, analytics, export and the unread badge by an explicit `is_deleted = 0` predicate in every query. Search results filter after FTS matching, so a soft-deleted row can cost a wasted FTS hit but never appears.
- The unread badge recomputes immediately after delete/undo.

```swift
// Packages/BackglanceCore/Sources/BackglanceCore/Archive/Archive+Actions.swift
public extension Archive {
    /// Soft delete. Returns the ids actually flipped so undo can restore exactly those.
    /// Synchronous, like every other `Archive` write (see `Archive+Digest.swift`'s
    /// `markRead(ids:)`) — `pool.write { db in … }`, not `async`/`await write { }`, and
    /// the read that finds the live ids happens inside the same transaction as the
    /// update so the returned array is exact under concurrent windows.
    @discardableResult
    func softDelete(_ ids: [Int64]) throws -> [Int64] { /* … */ }

    /// Flips ids back. Not an error if it changes nothing — the retention job may have
    /// hard-pruned them first.
    @discardableResult
    func restore(_ ids: [Int64]) throws -> Int { /* … */ }
}
```

### Select and Export

v1.0 ships the *selection* subset of export: select rows in the full window (⌘-click / ⇧-click / ⌘A over the visible filter), then **Export Selection…** (⌘E). The `ExportSheet` asks for CSV or JSON, then an `NSSavePanel` picks the destination; the default filename is `Backglance-export-2026-08-17.csv`. Date-range export, `backglance://export?…` and the Shortcuts action are v1.x and documented in [EXPORT_AUTOMATION.md](./EXPORT_AUTOMATION.md).

Export columns (CSV header, same keys in JSON): `uuid, app_bundle_id, app_name, title, subtitle, body, sender, delivered_at (ISO 8601 local), presented, missed, redacted, deep_link, attachments`. Redacted bodies export the placeholder. Attachments export as metadata only, never bytes.

```swift
@MainActor
func exportSelection(_ ids: [Int64], format: ExportFormat) async throws {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Backglance-export-\(ISO8601DateFormatter.dayOnly.string(from: .now)).\(format.fileExtension)"
    panel.allowedContentTypes = [format.contentType]        // UTType.commaSeparatedText / .json
    guard panel.runModal() == .OK, let url = panel.url else { return }   // user cancelled: not an error
    do {
        try await exportService.export(.ids(ids), format: format, to: url)
    } catch {
        throw ActionError.exportFailed(reason: error.localizedDescription)
    }
}
```

### Pin, Unpin, Read, Unread

Both are single-column toggles on `notifications`. Pinned rows sort to the top of the timeline together with VIP-pinned rows; the manual pin wins ties (manual before VIP, then `delivered_at DESC`). Marking read affects only the badge; opening a notification marks it read implicitly. Marking *unread* is allowed and puts the row back into the badge count if it was delivered since the last popover open.

### Mute This App in Timeline

This action flips `apps.is_muted` through the rules layer (`RulesEngine.setAppMuted(bundleID:muted:)`) so the timeline store's triage cache is invalidated in the same place as any other rule change. The result: the app's notifications collapse into a "Muted" group at the bottom of the timeline and stop counting toward the unread badge. They are still archived, searchable, exported and shown in analytics. Everything about matching semantics, VIP-beats-mute, and the settings UI is in [RULES.md](./RULES.md).

> ⚠️ **Warning:** Muting in Backglance changes only how Backglance *shows* the app. The banner, sound and badge from macOS are unchanged. To stop delivery, use item 9 ("Notification Settings for ‹App›…") which takes you to System Settings.

### Open in System Settings ▸ Notifications

Backglance opens the app's own page in System Settings so the user can change delivery there. The URL scheme is `x-apple.systempreferences:` and the Notifications pane identifier is `com.apple.Notifications-Settings.extension`. Selecting a specific app is done with a `?id=<bundle id>` query.

> ⚠️ **Warning:** The `?id=` selection is not a documented API and behaves differently across macOS versions. Backglance always tries the most specific URL first and falls back to the pane root. Verify against each new macOS release; the table below is what has been observed, not a contract.

| macOS | URL tried first | Observed | Fallback |
|---|---|---|---|
| 14 (Sonoma) | `x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=<bundle>` | opens Notifications and selects the app | pane root |
| 15 (Sequoia) | same | opens Notifications and selects the app | pane root |
| 26 (Tahoe) | same | opens Notifications; app selection honoured inconsistently (sometimes lands on the pane root) | pane root, then legacy id |
| any | `x-apple.systempreferences:com.apple.Notifications-Settings.extension` | opens the pane root | — |
| any | `x-apple.systempreferences:com.apple.preference.notifications` | legacy id (macOS ≤ 12); harmless if ignored | — |

```swift
struct SystemSettingsLink {
    static func notificationSettingsURLs(for bundleID: String) -> [URL] {
        let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        let encoded = bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bundleID
        return [
            URL(string: "\(pane)?id=\(encoded)"),
            URL(string: pane),
            URL(string: "x-apple.systempreferences:com.apple.preference.notifications"),
        ].compactMap { $0 }
    }

    /// Tries each URL in order; `open` returns false when the scheme is refused.
    @MainActor
    static func open(bundleID: String, workspace: NSWorkspace = .shared) throws {
        for url in notificationSettingsURLs(for: bundleID) where workspace.open(url) {
            return
        }
        throw ActionError.systemSettingsUnavailable
    }
}
```

The same helper is reused by the weekly summary in [ANALYTICS.md](./ANALYTICS.md), so the per-version behaviour lives in exactly one place.

## NotificationActionHandler

The handler is the single entry point used by menu, keyboard and hover buttons. It is `@MainActor`, holds an `Archive`, and reports failures as thrown `ActionError` values which the view layer turns into an inline message; it never shows alerts itself.

```swift
// Packages/BackglanceUI/Sources/BackglanceUI/Actions/NotificationActionHandler.swift
import AppKit
import BackglanceCore
import os

public enum ActionError: Error, Equatable {
    case notFound(notificationID: Int64)
    case appNotInstalled(bundleID: String)
    case launchFailed(bundleID: String, reason: String)
    case deepLinkUnresolvable(notificationID: Int64)
    case pasteboardFailure
    case exportFailed(reason: String)
    case systemSettingsUnavailable
    case archive(reason: String)
}

@MainActor
final class NotificationActionHandler {
    private let archive: Archive
    private let rules: RulesEngine
    private let exportService: ExportService
    private let open = OpenAction()
    private let log = Logger(subsystem: "app.backglance.Backglance", category: "actions")

    /// Pending undo: the ids of the last delete and the task that clears the toast.
    private(set) var pendingUndo: [Int64] = []
    private var undoExpiry: Task<Void, Never>?
    var onUndoStateChanged: (([Int64]) -> Void)?

    init(archive: Archive, rules: RulesEngine, exportService: ExportService) {
        self.archive = archive
        self.rules = rules
        self.exportService = exportService
    }

    // MARK: Open

    func openNotification(id: Int64) async throws {
        let (n, app) = try await fetch(id)
        do {
            try await open.run(n, app: app)
            try await archive.markRead([id], read: true)
        } catch let e as ActionError {
            log.error("open failed for \(id, privacy: .public): \(String(describing: e), privacy: .public)")
            throw e
        } catch {
            throw ActionError.archive(reason: error.localizedDescription)
        }
    }

    // MARK: Copy

    func copy(ids: [Int64], includeAppAndTimestamp: Bool) async throws {
        var items: [(ArchivedNotification, AppRecord)] = []
        for id in ids { items.append(try await fetch(id)) }
        try CopyAction(includeAppAndTimestamp: includeAppAndTimestamp).run(items)
    }

    // MARK: Delete / Undo
    //
    // Synchronous, not `async`: `Archive.softDelete`/`restore` are ordinary
    // `pool.write { db in … }` calls, the same as every other archive write, so there
    // is no `await` on the archive side of either method. `pendingUndo` is a plain
    // `@Observable` property — `NotificationActionHandler` is itself `@Observable` —
    // rather than the `onUndoStateChanged` closure sketched earlier: a view reads
    // `pendingUndo` directly, the same way it would read any other `@Observable`
    // state, and SwiftUI's observation tracking is what redraws the toast. The
    // 5-second wait goes through an injected `UndoClock` (mirrors
    // `BackglanceCore`'s `AwayClock`) so a test can drive the expiry without
    // sleeping for real.

    func delete(ids: [Int64]) throws {
        let flipped = try archive.softDelete(ids)
        undoExpiry?.cancel()
        pendingUndo = flipped
        guard !flipped.isEmpty else { return }   // nothing was actually deleted; no toast
        undoExpiry = Task { [weak self, undoClock] in
            try? await undoClock.sleep(seconds: 5)
            guard !Task.isCancelled else { return }
            self?.pendingUndo = []                 // toast goes away; rows stay soft-deleted
        }
    }

    func undoDelete() throws {
        guard !pendingUndo.isEmpty else { return }  // nothing to undo: silently ignore ⌘Z
        let ids = pendingUndo
        undoExpiry?.cancel()
        pendingUndo = []
        try archive.restore(ids)
    }

    // MARK: Toggles
    //
    // Synchronous, like Delete/Undo above: `Archive.setPinned`/`setRead` are ordinary
    // `pool.write { db in … }` calls, so there is no `await` on the archive side of
    // either method.

    func setPinned(ids: [Int64], _ pinned: Bool) throws { try archive.setPinned(ids, pinned) }
    func setRead(ids: [Int64], _ read: Bool) throws { try archive.setRead(ids, read) }

    func setAppMuted(bundleID: String, _ muted: Bool) async throws {
        try await rules.setAppMuted(bundleID: bundleID, muted: muted)   // invalidates the triage cache
    }

    // MARK: System Settings

    func openNotificationSettings(bundleID: String) throws {
        try SystemSettingsLink.open(bundleID: bundleID)
    }

    // MARK: Helpers

    private func fetch(_ id: Int64) async throws -> (ArchivedNotification, AppRecord) {
        do {
            return try await archive.read { db in
                guard let n = try ArchivedNotification.fetchOne(db, key: id),
                      let app = try AppRecord.fetchOne(db, key: n.appID)
                else { throw ActionError.notFound(notificationID: id) }
                return (n, app)
            }
        } catch let e as ActionError {
            throw e
        } catch {
            throw ActionError.archive(reason: error.localizedDescription)
        }
    }
}
```

The view layer maps errors to short inline strings:

| `ActionError` | Shown to user |
|---|---|
| `.appNotInstalled` | "App not found" (row subtitle for 3 s), Copy remains available |
| `.launchFailed` | "Couldn't open ‹App›" |
| `.deepLinkUnresolvable` | system beep (`NSSound.beep()`), no text |
| `.pasteboardFailure` | "Couldn't copy" |
| `.exportFailed` | "Export failed: ‹reason›" in the sheet |
| `.systemSettingsUnavailable` | "Couldn't open System Settings" |
| `.notFound` / `.archive` | "Something went wrong — see log" and a `Logger` error line |

## Edge Cases and Error Handling

| Case | Behaviour |
|---|---|
| App uninstalled after capture | `urlForApplication(withBundleIdentifier:)` returns nil → `.appNotInstalled`; row shows "App not found"; the icon cached at capture time keeps rendering |
| Deep link scheme lost its handler | `NSWorkspace.open` returns false → fall through to app activation; no error surfaced |
| Deep link is `file:` | rejected at enrichment (`GenericURLResolver`) — Backglance never opens local paths from notification payloads |
| Deep link contains credentials/tokens (e.g. Slack magic links) | opened as-is when the user clicks; never logged (`deep_link` is excluded from log lines) |
| Mail Message-ID absent | expected; falls back to activating Mail (documented in the resolver table) |
| Messages sender is a display name, not a handle | `looksLikeHandle` rejects → activate Messages |
| Copy while pasteboard is owned by a locked app | `setString` returns false → `.pasteboardFailure` |
| Copy of a redacted notification | placeholder `[code redacted]` is copied verbatim; nothing else exists |
| Delete during an in-flight capture insert | soft delete only touches existing ids; a new row from the same store record cannot reappear because `store_rec_id` is unique and the row still exists (soft-deleted) |
| Undo after the retention job already hard-pruned | `restore` updates 0 rows; the toast is gone anyway. Window is 15 min minimum, so this needs the app to have been asleep across a prune |
| Delete a pinned or VIP notification | allowed; pin/VIP do not protect from delete (deletion is explicit) |
| Multi-select across muted group | allowed; muted rows are still real rows |
| Export cancelled in the save panel | not an error; nothing logged |
| Export destination unwritable | `.exportFailed(reason:)` with the file system message |
| System Settings URL refused (all three) | `.systemSettingsUnavailable`; the user is told to open System Settings ▸ Notifications manually |
| Action on a notification that was just deleted from another window | `.notFound`, row disappears on next refresh |
| Keyboard action with no focused row | ignored (no beep) except ⌘↩ which beeps by design |

> ❌ **Don't:** never call `NSWorkspace.shared.open` with a URL built from notification content that has not gone through a resolver. Only `deep_link` (produced by resolvers) or the fixed System Settings URLs are ever opened.

## Testing Approach

Tests live in `Tests/BackglanceCaptureTests` (resolvers) and `Tests/BackglanceCoreTests` (soft delete / undo). AppKit-dependent pieces (`OpenAction`, `CopyAction`) are covered in the app target's unit test bundle with injected `NSWorkspace`/`NSPasteboard` where possible; anything that would actually launch an app is not exercised in CI.

**Resolver unit tests** — table-driven over synthetic `ParsedNotification` values (fixtures use `example.com` and `+1 555 0100` handles only):

```swift
import XCTest
@testable import BackglanceCapture

final class DeepLinkResolverTests: XCTestCase {
    func testMessagesHandleProducesIMessageURL() {
        var n = ParsedNotification.fixture(bundleID: "com.apple.MobileSMS")
        n.userInfo = ["senderHandle": "+1 555 0100"]
        XCTAssertEqual(MessagesResolver().resolve(n)?.scheme, "imessage")
    }

    func testMessagesDisplayNameFallsBackToNil() {
        var n = ParsedNotification.fixture(bundleID: "com.apple.MobileSMS")
        n.userInfo = ["senderHandle": "Alex Example"]
        XCTAssertNil(MessagesResolver().resolve(n))       // OpenAction will activate Messages instead
    }

    func testMailWithoutMessageIDIsNil() {
        let n = ParsedNotification.fixture(bundleID: "com.apple.mail")
        XCTAssertNil(MailResolver().resolve(n))
    }

    func testGenericResolverRejectsFileURLs() {
        var n = ParsedNotification.fixture(bundleID: "com.example.app")
        n.userInfo = ["path": "file:///etc/hosts"]
        XCTAssertNil(GenericURLResolver().resolve(n))
    }
}
```

**Pasteboard test** — uses a private named pasteboard so the developer's clipboard is not clobbered:

```swift
@MainActor
final class CopyActionTests: XCTestCase {
    func testCopyJoinsTitleAndBodyWithEmDash() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("app.backglance.tests.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let action = CopyAction(includeAppAndTimestamp: false, pasteboard: pb)
        let n = ArchivedNotification.fixture(title: "Build finished", body: "All 42 tests passed")
        try action.run([(n, AppRecord.fixture(bundleID: "com.example.ci"))])
        XCTAssertEqual(pb.string(forType: .string), "Build finished — All 42 tests passed")
    }

    func testRedactedPlaceholderIsCopiedAsIs() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("app.backglance.tests.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let n = ArchivedNotification.fixture(title: nil, body: "Your code is [code redacted]", redaction: "otp")
        try CopyAction(pasteboard: pb).run([(n, AppRecord.fixture(bundleID: "com.apple.MobileSMS"))])
        XCTAssertEqual(pb.string(forType: .string), "Your code is [code redacted]")
    }
}
```

**Soft-delete / undo test** — in-memory archive, asserts the flag flips and that the timeline query hides the row:

```swift
// Tests/BackglanceCoreTests — Archive.softDelete/restore are synchronous, like every
// other Archive write, so these tests are too.
final class SoftDeleteTests: XCTestCase {
    func testDeleteThenUndoRestoresRow() throws {
        let archive = try Archive(inMemory: true)
        let id = try insertFixtureNotification(archive, title: "Hello")
        let flipped = try archive.softDelete([id])
        XCTAssertEqual(flipped, [id])
        var visible = try archive.pool.read { db in try ArchivedNotification.filter(Column("is_deleted") == false).fetchCount(db) }
        XCTAssertEqual(visible, 0)
        XCTAssertEqual(try archive.restore([id]), 1)
        visible = try archive.pool.read { db in try ArchivedNotification.filter(Column("is_deleted") == false).fetchCount(db) }
        XCTAssertEqual(visible, 1)
    }

    func testDeletingAlreadyDeletedRowFlipsNothing() throws {
        let archive = try Archive(inMemory: true)
        let id = try insertFixtureNotification(archive, title: "Hello")
        _ = try archive.softDelete([id])
        let second = try archive.softDelete([id])
        XCTAssertTrue(second.isEmpty)               // undo of the second delete must not resurrect anything
    }
}
```

The 5 s undo timer is tested through `NotificationActionHandler` with an injected `UndoClock` (mirrors `BackglanceCore`'s `AwayClock` and the `ScriptedAwayClock` technique in `AwaySessionTrackerTests`) standing in for `Task.sleep` — a manual test clock that resolves only when the test tells it to, never the wall clock. The assertion is that `pendingUndo` empties once the clock is advanced past 5 seconds and that `Archive.restore` is never called on that path.

## Next Steps

- Read [RULES.md](./RULES.md) for what "Mute this app" actually does and how VIP pinning interacts with manual pins.
- Read [TIMELINE.md](./TIMELINE.md) for row layout, grouping and the unread badge.
- v1.x follow-ups: snooze ([SNOOZE_RESURFACE.md](./SNOOZE_RESURFACE.md)), date-range and automated export ([EXPORT_AUTOMATION.md](./EXPORT_AUTOMATION.md)).

## Related Documentation

- [RULES.md](./RULES.md) — highlight / VIP / mute rules and the engine behind "Mute this app"
- [TIMELINE.md](./TIMELINE.md) — timeline layout, selection, badge
- [CAPTURE.md](./CAPTURE.md) — where `deep_link` is produced (EnrichmentService)
- [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md) — retention job, hard delete, redaction, panic wipe
- [SEARCH.md](./SEARCH.md) — how soft-deleted rows are excluded from results
- [ANALYTICS.md](./ANALYTICS.md) — reuses the System Settings deep link
- [SNOOZE_RESURFACE.md](./SNOOZE_RESURFACE.md) — v1.x snooze action
- [EXPORT_AUTOMATION.md](./EXPORT_AUTOMATION.md) — v1.x date-range export, URL scheme, Shortcuts
- [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md) — canonical DDL
- [API_DOCUMENTATION.md](../api/API_DOCUMENTATION.md) — `Archive`, `ExportService`, `RulesEngine` signatures
- [TESTING.md](../testing/TESTING.md) — test targets and fixtures
- [ACCESSIBILITY.md](../reference/ACCESSIBILITY.md) — keyboard access and VoiceOver labels for menu items
