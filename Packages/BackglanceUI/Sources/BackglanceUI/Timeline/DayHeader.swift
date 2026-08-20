import SwiftUI

// MARK: - DayHeader

/// The pinned label at the top of one day's rows — "Today", "Yesterday", or a
/// dated weekday further back.
///
/// `TimelineSection.Model` already decided the string (``DayTitle``); this view
/// only draws it. It is pinned via `LazyVStack`'s `.sectionHeaders`
/// (docs/features/TIMELINE.md#timelineview-and-timelinesection), so the header
/// stays on screen while its day's rows scroll underneath it — the thin
/// material behind the text is what keeps it legible over moving rows rather
/// than floating bare text on top of them.
public struct DayHeader: View {
    // MARK: Lifecycle

    public init(title: String) {
        self.title = title
    }

    // MARK: Public

    /// "Today" / "Yesterday" / "Monday, 11 Aug" / "11 August 2026" — see ``DayTitle``.
    public let title: String

    public var body: some View {
        Text(title)
            .font(.caption.smallCaps())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
            // So VoiceOver users can rotor between days (docs/features/TIMELINE.md#accessibility).
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Previews

#Preview("Today") {
    DayHeader(title: "Today")
}

#Preview("Dated") {
    DayHeader(title: "Monday, 11 Aug")
}
