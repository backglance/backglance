import BackglanceCore
import Foundation
import SwiftUI

// MARK: - NotificationRow

/// One notification, compact or detailed — docs/features/TIMELINE.md#notificationrow.
///
/// A pure value renderer: it is handed an item, a mode and an optional
/// `onOpen` closure, and draws exactly that. Unlike the sample in TIMELINE.md
/// it does not reach into `@Environment(TimelineStore.self)` — that would
/// make the row untestable and unpreviewable without a live store, and the
/// store's `open(_:)` (mark read + deep link, see ACTIONS.md) is just as easy
/// to wire from the caller through a closure. Row actions (`RowContextMenu`
/// in the sample) are a later milestone and are deliberately absent here.
public struct NotificationRow: View {
    // MARK: Lifecycle

    public init(item: TimelineItem, mode: TimelineViewMode, onOpen: ((Int64) -> Void)? = nil) {
        self.item = item
        self.mode = mode
        self.onOpen = onOpen
    }

    // MARK: Public

    public let item: TimelineItem
    public let mode: TimelineViewMode

    /// Fired on tap with the row's archive id. `nil` leaves the row inert,
    /// which is how a preview renders one without wiring interaction.
    public let onOpen: ((Int64) -> Void)?

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
        .onTapGesture {
            onOpen?(item.id)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabelParts(for: item).joined(separator: ", "))
        .accessibilityValue(Self.accessibilityValueText(for: item))
        .accessibilityHint(Text("Press Return to open in \(item.appName)."))
        .accessibilityIdentifier("timeline.row.\(item.notification.uuid)")
    }

    // MARK: Internal

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
                RoundedRectangle(cornerRadius: 6).fill(color.swiftUIColor.opacity(0.12))
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
