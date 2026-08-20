import SwiftUI

// MARK: - UnreadDivider

/// "new since you were away" — placed before the first row delivered after the
/// unread anchor (last popover open, or the last away session's end, whichever
/// is later).
///
/// `TimelineStore.buildSections` decides whether the divider appears at all and
/// where it lands; this view only draws the marker itself. See
/// docs/features/TIMELINE.md#unreaddivider for the placement rules — in
/// particular, why there is never more than one divider on screen, and why
/// nothing arriving since the anchor means no divider at all.
public struct UnreadDivider: View {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.tint).frame(height: 1)
            Text(String(localized: "new since you were away"))
                .font(.caption2.smallCaps())
                .foregroundStyle(.tint)
                .fixedSize()
            Rectangle().fill(.tint).frame(height: 1)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "New notifications since you were away start here"))
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Preview

#Preview {
    UnreadDivider()
}
