import AppKit
import BackglanceCore
import Foundation
import SwiftUI

// MARK: - NotificationRow

/// One notification, compact or detailed — docs/features/TIMELINE.md#notificationrow.
///
/// A pure value renderer: it is handed an item, a mode and a handful of
/// closures, and draws exactly that. It deliberately does not reach into
/// `@Environment(TimelineStore.self)` — that would make the row untestable
/// and unpreviewable without a live store, and everything the store would
/// otherwise supply (open, multi-select) is just as easy to wire from the
/// caller through a closure or a plain value. `selectionCount` and `host`
/// (BACKGLANCE-203) are exactly that: values the row needs to build its
/// context menu correctly (the selection count for item 11's label and item
/// 10's visibility, the host for item 10's popover/window split) without
/// ever reading the store that owns them.
///
/// The one exception to "closures in, view out" is `@Environment(\.actionDispatcher)`
/// itself: the row's `.contextMenu` dispatches directly through it, the same
/// seam `ActionDispatching`'s own doc comment names `NotificationRow` as a
/// consumer of. That is a deliberate difference from `onOpen`/`onToggleSelect`/
/// `onExtendSelect`, which stay as caller-supplied closures — those three are
/// about *which row(s)* an interaction targets, a question only the caller
/// (which owns the store) can answer, where the context menu's dispatch is
/// the same for every row and every host, which is exactly what an
/// environment value is for.
public struct NotificationRow: View {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - item: the row to draw.
    ///   - mode: compact or detailed.
    ///   - onOpen: fired on a plain tap, with the row's archive id.
    ///   - selectionIDs: the full window's current multi-selection, in
    ///     visible order — ``TimelineStore/selectedIDsInVisibleOrder``. Not
    ///     merely a count: docs/features/ACTIONS.md#context-menu-specification
    ///     says items 3–6, 10 and 11 "act on the whole selection", so the row
    ///     needs the ids themselves, not just how many there are. Defaults to
    ///     empty, the popover's only value and every existing call site's
    ///     implicit one, so no other caller or `#Preview` has to change.
    ///   - host: popover or window; defaults to `.popover` for the same
    ///     reason.
    ///   - onToggleSelect: fired on a ⌘-click, with the row's archive id —
    ///     wired by the caller to ``TimelineStore/toggleSelection(_:)``.
    ///   - onExtendSelect: fired on a ⇧-click, with the row's archive id —
    ///     wired by the caller to ``TimelineStore/extendSelection(to:)``.
    ///   - onRequestExport: fired by item 10 ("Export Selection…") with the
    ///     ids to export. A callback rather than a direct
    ///     ``ActionDispatching/exportSelection(_:format:)`` call because the
    ///     format is the user's to choose: `ExportSheet` asks for CSV or JSON
    ///     first (docs/features/ACTIONS.md#select-and-export), and presenting
    ///     a sheet is the host's job, not a row's. A row that exported CSV on
    ///     its own would be answering a question the user was supposed to be
    ///     asked.
    ///   - onActionError: fired when a context-menu dispatch throws an
    ///     ``ActionError`` whose ``ActionError/userMessage`` is non-`nil`.
    ///     The row never shows its own alert or inline message — presenting
    ///     one is BACKGLANCE-203 part 2's job, once there is a place
    ///     (`TimelineView`'s new `@State`) to put it. The one error case
    ///     that *is* handled here, `.deepLinkUnresolvable`, has a `nil`
    ///     message by design (docs/features/ACTIONS.md's error table maps it
    ///     to a system beep instead), so it never reaches this callback at
    ///     all.
    public init(
        item: TimelineItem,
        mode: TimelineViewMode,
        onOpen: ((Int64) -> Void)? = nil,
        selectionIDs: [Int64] = [],
        host: TimelineStore.Host = .popover,
        onToggleSelect: ((Int64) -> Void)? = nil,
        onExtendSelect: ((Int64) -> Void)? = nil,
        onRequestExport: (([Int64]) -> Void)? = nil,
        onActionError: ((ActionError) -> Void)? = nil
    ) {
        self.item = item
        self.mode = mode
        self.onOpen = onOpen
        self.selectionIDs = selectionIDs
        self.host = host
        self.onToggleSelect = onToggleSelect
        self.onExtendSelect = onExtendSelect
        self.onRequestExport = onRequestExport
        self.onActionError = onActionError
    }

    // MARK: Public

    public let item: TimelineItem
    public let mode: TimelineViewMode

    /// Fired on tap with the row's archive id. `nil` leaves the row inert,
    /// which is how a preview renders one without wiring interaction.
    public let onOpen: ((Int64) -> Void)?

    /// See ``init(item:mode:onOpen:selectionIDs:host:onToggleSelect:onExtendSelect:onRequestExport:onActionError:)``.
    public let selectionIDs: [Int64]
    public let host: TimelineStore.Host
    public let onToggleSelect: ((Int64) -> Void)?
    public let onExtendSelect: ((Int64) -> Void)?
    public let onRequestExport: (([Int64]) -> Void)?
    public let onActionError: ((ActionError) -> Void)?

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AppIconView(bundleID: item.bundleID)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .imageScale(.small)
                    }
                    Text(item.appName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(item.notification.deliveredAt.date, format: .dateTime.hour().minute())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                // The one line every mode shows. Falling back to the body
                // keeps a body-only notification from rendering blank, but
                // the fallback still lands in a single `lineLimit(1)` Text —
                // it is the *second*, unbounded body block below (detailed
                // only) that compact mode never instantiates, which is what
                // keeps a 200-row popover scroll at 60 fps
                // (docs/features/TIMELINE.md#performance).
                Text(displayTitle)
                    .font(.body.weight(item.notification.isRead ? .regular : .semibold))
                    .lineLimit(1)

                if mode == .detailed {
                    if let subtitle = item.notification.subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .lineLimit(1)
                    }
                    if item.notification.title != nil, let body = item.notification.body {
                        Text(body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }
                    HStack(spacing: 6) {
                        if let chip = attachmentsChip {
                            chip
                        }
                        if item.notification.threadId != nil {
                            Label(String(localized: "Thread"), systemImage: "bubble.left.and.bubble.right")
                                .font(.caption2)
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
            }
        }
        .padding(.vertical, mode == .compact ? 4 : 8)
        .padding(.horizontal, 10)
        .background(rowBackground)
        .contentShape(Rectangle())
        // ⌘-click and ⇧-click are attached *before* the plain tap, in that
        // order, so a modified click wins: SwiftUI resolves competing
        // `TapGesture`s in the reverse of their attachment order, and a plain
        // `TapGesture()` matches any click, modified or not — it has to lose
        // the race whenever `.modifiers(...)` also matches, or ⌘-click would
        // both toggle the selection and open the row. `onToggleSelect`/
        // `onExtendSelect` are `nil` in the popover and in every existing
        // `#Preview`, which leaves a modified click inert there rather than
        // reaching for a store this view does not have.
        .gesture(TapGesture().modifiers(.command).onEnded { onToggleSelect?(item.id) })
        .gesture(TapGesture().modifiers(.shift).onEnded { onExtendSelect?(item.id) })
        .onTapGesture {
            onOpen?(item.id)
        }
        .contextMenu {
            // A `nil` dispatcher — every `#Preview` below, and any host that
            // has not wired one up — simply gets no menu content rather than
            // one full of items that would throw the moment they were
            // tapped. `ActionDispatcherKey`'s own doc comment makes the same
            // choice for the same reason: `nil` is not a stub to fake a
            // result for, so there is nothing honest to offer here either.
            // An empty `.contextMenu` closure is how SwiftUI spells "no menu
            // at all" — right-click does nothing, same as before this task.
            if let dispatcher = actionDispatcher {
                contextMenuContent(dispatcher: dispatcher)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabelParts(for: item).joined(separator: ", "))
        .accessibilityValue(Self.accessibilityValueText(for: item))
        .accessibilityHint(Text("Press Return to open in \(item.appName)."))
        .accessibilityIdentifier("timeline.row.\(item.notification.uuid)")
    }

    // MARK: Internal

    /// The context menu's dispatch target — see this type's own doc comment
    /// for why this is the one thing the row reaches through the environment
    /// rather than a closure.
    /// Not `private`: `NotificationRow+ContextMenu.swift` reads it, and Swift's
    /// `private` does not reach across files even for an extension of the same type.
    @Environment(\.actionDispatcher)
    var actionDispatcher

    /// The label's parts, in swipe order: app, title, body, time —
    /// docs/reference/ACCESSIBILITY.md#timeline-rows. State is deliberately
    /// absent here; it lives in ``accessibilityValueText(for:)`` so VoiceOver
    /// announces a change ("pinned") without re-reading the whole row.
    ///
    /// A redacted body never reaches this array — the placeholder that
    /// `OTPRedactor` already wrote into `body` before insert is not spoken
    /// either; "code redacted" is said in its place, so a screen reader user
    /// never has to parse a bracketed placeholder to learn what happened.
    /// `internal` (not `private`) so ``AccessibilityTests`` can assert on the
    /// composition directly, without instantiating a view.
    static func accessibilityLabelParts(for item: TimelineItem) -> [String] {
        var parts = [item.appName]
        if let title = item.notification.title {
            parts.append(title)
        }
        if item.notification.redaction == .otp {
            parts.append(String(
                localized: "code redacted",
                comment: "VoiceOver: the OTP digits were redacted before this notification was ever archived"
            ))
        } else if let body = item.notification.body {
            parts.append(body)
        }
        parts.append(item.notification.deliveredAt.date.formatted(.dateTime.hour().minute()))
        return parts
    }

    /// The ids a selection-wide menu item acts on, per the paragraph under
    /// docs/features/ACTIONS.md#context-menu-specification: items 3–6, 10 and
    /// 11 act on the whole selection, while 1, 2 and 9 act on the row that was
    /// right-clicked.
    ///
    /// Right-clicking a row *outside* the current selection targets that row
    /// alone rather than the selection it is not part of — the platform
    /// convention every Finder and Mail user already has, and the only reading
    /// that keeps item 11's label honest: ``NotificationRowMenu`` is handed
    /// this array's count, not the raw selection's, so "Delete 3
    /// Notifications" can only ever appear on a menu that really is about to
    /// delete three. A label promising more than the action delivers would be
    /// worse than either behaviour on its own.
    ///
    /// `static`, like ``accessibilityLabelParts(for:)`` above, so
    /// ``NotificationRowMenuTests`` can assert the rule directly instead of
    /// having to drive a menu to find out which ids a click would have sent.
    static func targetIDs(rightClicked id: Int64, selectionIDs: [Int64]) -> [Int64] {
        guard selectionIDs.count > 1, selectionIDs.contains(id) else {
            return [id]
        }
        return selectionIDs
    }

    /// "Unread, pinned" — state as a *value*, so a change is announced
    /// without re-reading the whole row (docs/reference/ACCESSIBILITY.md#timeline-rows).
    /// "Read" when there is nothing else to say, so the value is never empty.
    static func accessibilityValueText(for item: TimelineItem) -> String {
        var states: [String] = []
        if !item.notification.isRead {
            states.append(String(localized: "unread"))
        }
        if item.isPinned {
            states.append(String(localized: "pinned"))
        }
        if item.notification.redaction == .otp {
            states.append(String(localized: "redacted"))
        }
        return states.isEmpty ? String(localized: "read") : states.joined(separator: ", ")
    }

    // MARK: Private

    /// A JSON element from `attachmentsJson` we care about only for its
    /// count. `AttachmentMeta` already exists in `BackglanceCapture`
    /// (`Parsing/ParsedNotification.swift`), but this package cannot import
    /// that module — see `AppIconView.swift`'s note on dependency direction —
    /// so the row decodes into this minimal stand-in instead of inventing a
    /// second public attachment type. No properties are declared because
    /// none are read; `JSONDecoder` ignores the real payload's extra keys.
    private struct AttachmentStub: Decodable {}

    /// Increase Contrast turns the highlight tint from a fill into a border —
    /// docs/reference/ACCESSIBILITY.md#contrast: a translucent fill sitting
    /// behind `Color.primary` text can still read below 4.5:1 once the
    /// system pushes contrast up, where a stroke of the same hue never
    /// touches the text at all. Selection keeps its fill in both cases — it
    /// is `Color.accentColor`, not a Rules token, and already carries its
    /// own contrast-safe variants.
    @Environment(\.colorSchemeContrast)
    private var contrast

    /// Falls back title → body → a localized placeholder, so a row with only
    /// a body (or, from an import, neither) still shows something instead of
    /// going blank.
    private var displayTitle: String {
        item.notification.title ?? item.notification.body ?? String(localized: "(no text)")
    }

    /// "2 attachments" chip — metadata only. The archive never stores
    /// attachment bytes, so there is nothing here to render but the count.
    private var attachmentsChip: Label<Text, Image>? {
        guard let json = item.notification.attachmentsJson,
              let metas = try? JSONDecoder().decode([AttachmentStub].self, from: Data(json.utf8)),
              !metas.isEmpty
        else {
            return nil
        }
        return Label("\(metas.count)", systemImage: "paperclip")
    }

    @ViewBuilder private var rowBackground: some View {
        if item.isSelected {
            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18))
        } else if let color = item.triage.highlight {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(color.swiftUIColor, lineWidth: 2)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(color.swiftUIColor.opacity(HighlightColor.tintOpacity))
            }
        }
    }
}

// MARK: - Previews

#Preview("Compact") {
    VStack(alignment: .leading, spacing: 0) {
        ForEach(PreviewData.items) { item in
            NotificationRow(item: item, mode: .compact)
        }
    }
    .padding(.vertical, 8)
}

#Preview("Detailed") {
    VStack(alignment: .leading, spacing: 0) {
        ForEach(PreviewData.items) { item in
            NotificationRow(item: item, mode: .detailed)
        }
    }
    .padding(.vertical, 8)
}
