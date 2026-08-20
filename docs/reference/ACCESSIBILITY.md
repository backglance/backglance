# Accessibility

Last Updated: 2026-08-18

A notification archive is exactly the kind of utility that must work without a mouse and without sight: it is dense, list-shaped, and often used in a hurry. This document specifies how Backglance supports VoiceOver, full keyboard control, contrast, reduced motion, and larger text — with the actual SwiftUI code used in `BackglanceUI` — plus the identifiers and checklists used to test it. Accessibility is a v1.0 requirement, verified in milestone M2 and re-checked before release (see [ROADMAP.md](./ROADMAP.md)).

## Table of Contents

- [VoiceOver](#voiceover)
  - [Timeline rows](#timeline-rows)
  - [Day headers and grouping](#day-headers-and-grouping)
  - [Muted groups](#muted-groups)
  - [Digest view](#digest-view)
  - [Menu bar item](#menu-bar-item)
- [Keyboard navigation](#keyboard-navigation)
- [Contrast](#contrast)
- [Reduced motion](#reduced-motion)
- [Reduce Transparency](#reduce-transparency)
- [Text size](#text-size)
- [Pointer and hover states](#pointer-and-hover-states)
- [Identifiers for UI tests](#identifiers-for-ui-tests)
- [Testing](#testing)
  - [Accessibility Inspector](#accessibility-inspector)
  - [VoiceOver checklist](#voiceover-checklist)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## VoiceOver

### Timeline rows

A `NotificationRow` is one VoiceOver element, not five. Its children (icon, title, body, time, badges) combine into a single label read in a fixed order: **app, title, body, time, state** — so a user can skim rows with a single swipe each.

```swift
struct NotificationRow: View {
    let item: ArchivedNotification
    let appName: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AppIconView(bundleID: item.bundleID)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? appName).font(.headline)
                if let body = item.body {
                    Text(body).font(.body).lineLimit(3)
                }
            }
            Spacer()
            Text(item.deliveredAt, format: .dateTime.hour().minute())
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(stateText)
        .accessibilityHint(Text("Press Return to open in \(appName). Press Command-C to copy."))
        .accessibilityAddTraits(item.isRead ? [] : .isSelected)
        .accessibilityIdentifier("timeline.row.\(item.uuid.uuidString)")
    }

    /// "Slack, Deploy finished, main is green, 14:32"
    private var accessibilityText: Text {
        var parts: [String] = [appName]
        if let t = item.title { parts.append(t) }
        if item.redaction == .otp {
            parts.append(String(localized: "code redacted",
                                comment: "VoiceOver: OTP body was redacted"))
        } else if let b = item.body {
            parts.append(b)
        }
        parts.append(item.deliveredAt.formatted(.dateTime.hour().minute()))
        return Text(parts.joined(separator: ", "))
    }

    /// "Unread, pinned" — state is a value, so it is re-read when it changes.
    private var stateText: Text {
        var states: [String] = []
        if !item.isRead { states.append(String(localized: "unread")) }
        if item.isPinned { states.append(String(localized: "pinned")) }
        if item.redaction == .otp { states.append(String(localized: "redacted")) }
        return Text(states.isEmpty ? String(localized: "read") : states.joined(separator: ", "))
    }
}
```

Notes:

- **State goes in `accessibilityValue`,** not the label, so VoiceOver announces changes ("pinned") without re-reading the whole row.
- **Redacted rows never speak digits.** The label says "code redacted"; there are no digits to speak, because redaction happened before insert (see [PRIVACY_CONTROLS.md](../features/PRIVACY_CONTROLS.md)) — but the label path still guards against reading the placeholder awkwardly.
- The hint teaches the two primary actions once; hints are read last and can be disabled by the user.

### Day headers and grouping

Day headers are headings, so VoiceOver users can jump between days with the rotor (VO-U → Headings):

```swift
Section {
    ForEach(day.items) { NotificationRow(item: $0, appName: name(for: $0)) }
} header: {
    Text(day.date, format: .dateTime.weekday(.wide).day().month(.wide))
        .font(.subheadline.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
}
```

App-group subheaders inside a day (when grouping by app) also get `.isHeader`, one level down in reading order.

### Muted groups

Apps muted by a rule collapse into a disclosure at the bottom of each day. The disclosure announces its content and state:

```swift
DisclosureGroup(isExpanded: $showMuted) {
    ForEach(mutedItems) { NotificationRow(item: $0, appName: name(for: $0)) }
} label: {
    Text("^[\(mutedItems.count) muted notification](inflect: true)")
}
.accessibilityHint(Text("Muted by your rules. Expands to show them."))
.accessibilityIdentifier("timeline.mutedGroup")
```

SwiftUI exposes the expanded/collapsed state automatically; the hint explains *why* the items are set aside, because "muted" alone is ambiguous in a notifications app (see [RULES.md](../features/RULES.md) — muting is visual triage only).

### Digest view

The digest banner and view follow the same composition rules:

- Banner: one combined element — "What you missed: 12 notifications from 4 apps while you were away for 2 hours" — with `.isButton` trait (activating opens the digest) and a "Dismiss" action exposed via `accessibilityAction`.
- Digest list: VIP items first (already the visual order), app groups as headings, rows identical to timeline rows so the interaction model is learned once.

```swift
DigestBanner(digest: digest)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(
        "What you missed: ^[\(digest.itemCount) notification](inflect: true) while you were away"))
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(named: Text("Dismiss")) { model.dismissDigest() }
    .accessibilityIdentifier("digest.banner")
```

### Menu bar item

The `NSStatusItem` button gets an explicit label including the unread count, updated whenever the badge changes.
The copy itself lives in `BackglanceUI` as `StatusItemAccessibility`, a pure function of the count and the
capture state: the app target has no test bundle, and this is the only shape in which the string contract can
be asserted at all.

```swift
// StatusItemAccessibility.swift (BackglanceUI)
public static func label(unreadCount: Int, state: TimelineCaptureState) -> String {
    let unread = unreadPhrase(count: unreadCount)   // "Backglance, no unread notifications",
                                                    // "…, 1 unread notification",
                                                    // "…, more than 99 unread notifications"
    guard let suffix = stateSuffix(for: state) else { return unread }   // nil while running
    return String(localized: "\(unread), \(suffix)")
}

// StatusItemController.swift (AppKit side) — set on every badge or state change
button.setAccessibilityLabel(StatusItemAccessibility.label(unreadCount: count, state: state))
button.setAccessibilityHelp(StatusItemAccessibility.help)
```

The count is capped exactly where the drawn badge caps it (`Archive.unreadBadgeCap`): announcing an exact
214 while the icon reads "99+" is its own kind of wrong.

When capture is paused or degraded, the label appends the state ("capture paused", "needs Full Disk Access",
"capture degraded", "capture stopped") so the icon's changed appearance is not the only signal. The capture
layer's own degraded sentence stays in the tooltip — a label read aloud on every focus is the wrong place
for a paragraph.

## Keyboard navigation

Backglance is fully operable without a mouse. The global hotkey **⌃⌥N** opens the popover from anywhere; from there:

| Key | Action |
|---|---|
| (popover opens) | Focus lands on the search field's list — first unread row selected |
| ↓ / ↑ | Move selection through rows (wraps at day boundaries, skips headers) |
| ↩ (Return) | Open the selected notification's app or deep link |
| ⌘C | Copy the selected notification's text |
| ⌫ (Delete) | Delete the selected notification (soft delete; undo with ⌘Z) |
| ⌘F | Focus the search field |
| Esc | Clear search if active, else close the popover |
| Tab / ⇧Tab | Cycle focus: search field → filter chips → list → footer buttons |
| Space | Toggle detailed view for the selected row |
| ⌘↩ | Pin/unpin the selected row |

Implementation sketch — selection is model-driven, keys handled with `.onKeyPress`, and rows are focusable so Full Keyboard Access users can also Tab through them:

```swift
struct TimelineList: View {
    @ObservedObject var model: TimelineModel
    @FocusState private var focus: FocusTarget?

    enum FocusTarget: Hashable { case search, list }

    var body: some View {
        VStack(spacing: 0) {
            SearchBar(text: $model.query)
                .focused($focus, equals: .search)
            ScrollViewReader { proxy in
                List(selection: $model.selectedID) {
                    timelineSections
                }
                .focused($focus, equals: .list)
                .focusable()
                .onKeyPress(.return) { model.openSelected(); return .handled }
                .onKeyPress(.escape) {
                    if model.query.isEmpty { model.closePopover(); return .handled }
                    model.query = ""; return .handled
                }
                .onKeyPress(keys: [.delete]) { _ in
                    model.deleteSelected(); return .handled
                }
                .onChange(of: model.selectedID) { _, id in
                    if let id { proxy.scrollTo(id) } // keep selection visible
                }
            }
        }
        .onAppear { focus = .list } // popover open → list, first unread selected
        .onKeyPress(characters: .init(charactersIn: "f"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            focus = .search; return .handled
        }
    }

    @ViewBuilder private var timelineSections: some View {
        ForEach(model.days) { day in
            Section { /* rows */ } header: { DayHeader(day: day) }
        }
    }
}
```

`NSPopover` focus handling: the popover is created with `behavior = .transient` and `becomesKeyOnlyIfNeeded = false`, and `StatusItemController` calls `popover.contentViewController?.view.window?.makeKey()` on show so keyboard events reach SwiftUI immediately — without this, the first keystroke after opening is lost. Esc closes via the popover's standard cancel path, mirrored by the `.onKeyPress(.escape)` handler when search has focus. ⌘C is a `Copy` menu-command (`CommandGroup`) so it also works from the full timeline window.

## Contrast

- All text meets **WCAG AA (4.5:1)** against its background in light, dark, and increased-contrast appearances. Secondary text uses system semantic styles (`.secondary`), which Apple maintains at compliant contrast.
- **Highlight colors from Rules are the risk point.** Rule highlight tokens (`amber`, etc.) are defined per appearance in `Assets.xcassets` with light/dark/increased-contrast variants, and are used as *row background tints* behind primary label color — never as text color. Each token's tint is capped at an opacity where `Color.primary` on top of it stays ≥ 4.5:1 in both appearances; the token list is validated in a unit test that computes contrast ratios from the asset catalog's resolved colors.
- Unread and pinned indicators are never color-only: unread pairs a bold title with a dot **plus** the VoiceOver state; pinned shows a pin symbol.
- System semantic colors (`.primary`, `.secondary`, `Color(nsColor: .controlBackgroundColor)`) are used instead of hard-coded values wherever possible so Increase Contrast mode works for free.

## Reduced motion

The digest banner normally slides in from the top of the popover. With Reduce Motion on, it appears with a plain opacity change:

```swift
struct DigestBannerContainer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let visible: Bool

    var body: some View {
        if visible {
            DigestBanner()
                .transition(reduceMotion
                    ? .opacity                                   // no movement
                    : .move(edge: .top).combined(with: .opacity)) // slide-in
                .animation(reduceMotion ? .easeIn(duration: 0.15) : .spring(),
                           value: visible)
        }
    }
}
```

The same environment value disables the unread-badge bounce and any scroll-position animations. Nothing in Backglance auto-plays or loops.

## Reduce Transparency

The popover and timeline window use system materials (`.regularMaterial`). When Reduce Transparency is enabled, AppKit/SwiftUI substitute opaque equivalents automatically; custom views never draw their own translucency, so there is nothing to special-case. Verified in the checklist below because material-on-material stacking can still produce low-contrast seams.

## Text size

- All fonts use Dynamic-Type-style semantic text styles (`.headline`, `.body`, `.caption`) — never fixed point sizes — so the system text-size preference (System Settings ▸ Displays / Accessibility) scales them.
- Rows grow with their content: no fixed row heights; `lineLimit(3)` on body text expands to `nil` in the detailed view (Space).
- The popover has a maximum height and scrolls; at the largest text sizes the layout switches the time label to its own line via `ViewThatFits` rather than truncating.

## Pointer and hover states

- Hover reveals row actions (open, copy, pin, delete) as buttons at the row's trailing edge — but every hover-revealed action is **also** reachable by keyboard (table above) and by VoiceOver actions (`accessibilityAction`), so hover is a shortcut, never the only path.
- Hovered rows get a background tint using `View.onHover` + system `selectedContentBackgroundColor` tokens; hover states are suppressed while navigating by keyboard to avoid two competing highlights.
- Buttons use `.pointerStyle(.link)` only for actual links (deep links); everything else keeps the default pointer.

## Identifiers for UI tests

Stable `accessibilityIdentifier` strings power XCUITest (see [TESTING.md](../testing/TESTING.md)) and never change without a deprecation note:

| Identifier | Element |
|---|---|
| `statusItem.button` | Menu bar button |
| `timeline.searchField` | Search field |
| `timeline.row.<uuid>` | A timeline row |
| `timeline.mutedGroup` | Muted disclosure |
| `digest.banner` | Digest banner |
| `digest.list` | Digest list |
| `settings.privacy.panicWipe` | Panic wipe button |
| `onboarding.fda.openSettings` | FDA "Open System Settings" button |

Identifiers are namespaced `scene.element` and are not localized (they are not user-facing).

## Testing

### Accessibility Inspector

Run Xcode ▸ Open Developer Tool ▸ Accessibility Inspector against the running app for every milestone build:

1. **Audit** the popover, timeline window, digest, Settings, and onboarding: zero issues of type "element has no description" or "insufficient contrast" allowed at release.
2. **Inspection pointer** over each row type (unread, pinned, redacted, muted) to confirm label/value/hint composition matches this document.
3. Use the Inspector's simulators for Increase Contrast and Reduce Transparency where a physical settings toggle is slower.

### VoiceOver checklist

Run with VoiceOver (⌘F5) before every tagged release; all items must pass:

- [ ] ⌃⌥N opens the popover and VoiceOver focus lands in the list, first unread row announced.
- [ ] Each row reads as one element: app, title, body, time, then state as value.
- [ ] A redacted row says "code redacted" and speaks no digits.
- [ ] Rotor ▸ Headings jumps between day headers (and app subheaders when grouped by app).
- [ ] Muted disclosure announces count and expanded/collapsed state.
- [ ] Digest banner reads its summary, activates to open the digest, and offers a "Dismiss" action.
- [ ] Menu bar item announces the unread count, and "capture paused" when paused.
- [ ] All row actions (open, copy, pin, delete) are available as VoiceOver actions.
- [ ] Search: typing, result announcement ("12 results"), Esc behavior.
- [ ] Settings and onboarding fully navigable; FDA flow announces the degraded state plainly.
- [ ] Nothing traps focus; Esc always leads out.

## Next Steps

- M2 exit criteria include the keyboard table working end-to-end; the VoiceOver checklist is part of the M4 release gate ([ROADMAP.md](./ROADMAP.md)).
- Contributors adding any view to `BackglanceUI` add labels/identifiers in the same PR — see [CONTRIBUTING.md](../contributing/CONTRIBUTING.md).

## Related Documentation

- [ROADMAP.md](./ROADMAP.md)
- [INTERNATIONALIZATION.md](./INTERNATIONALIZATION.md)
- [FAQ.md](./FAQ.md)
- [TIMELINE.md](../features/TIMELINE.md)
- [MISSED_DIGEST.md](../features/MISSED_DIGEST.md)
- [RULES.md](../features/RULES.md)
- [PRIVACY_CONTROLS.md](../features/PRIVACY_CONTROLS.md)
- [TESTING.md](../testing/TESTING.md)
- [ARCHITECTURE.md](../architecture/ARCHITECTURE.md)
