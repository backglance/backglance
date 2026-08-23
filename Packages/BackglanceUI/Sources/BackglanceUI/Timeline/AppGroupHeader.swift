import SwiftUI

// MARK: - AppGroupHeader

/// The header for a run of rows from one app, or for a day's collapsed "Muted"
/// group — see docs/features/TIMELINE.md#grouping for how `TimelineStore`
/// decides which rows land under which header.
///
/// A plain app group is informational only: icon, name, count, nothing to
/// tap. The muted group is different — it starts collapsed
/// (docs/features/TIMELINE.md#grouping: "Muted rows render only when the
/// group is expanded"), so its header *is* the group until the user expands
/// it. That is the only case with a chevron, and the only case `onToggle`
/// fires for.
public struct AppGroupHeader: View {
    // MARK: Lifecycle

    public init(group: TimelineSection.AppGroup, isExpanded: Bool = false, onToggle: (() -> Void)? = nil) {
        self.group = group
        self.isExpanded = isExpanded
        self.onToggle = onToggle
    }

    // MARK: Public

    public let group: TimelineSection.AppGroup

    /// Whether the muted group's rows are currently showing. Ignored — and
    /// never toggleable — for a non-muted group, which has no collapsed state.
    public var isExpanded = false

    /// Fired on tap, muted group only. `nil` leaves the header inert, which is
    /// how a caller previews the collapsed state without wiring interaction.
    public var onToggle: (() -> Void)?

    public var body: some View {
        content
    }

    // MARK: Private

    /// Reduce Motion turns the chevron's rotation into a plain state change —
    /// docs/reference/ACCESSIBILITY.md#reduced-motion: the disclosure still
    /// ends up pointing the right way, it just gets there without the
    /// animated turn.
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    private var accessibilityLabel: String {
        String(localized: "\(group.name), ^[\(group.count) notification](inflect: true)")
    }

    private var expandedStateText: String {
        isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed")
    }

    private var content: some View {
        HStack(spacing: 8) {
            AppIconView(bundleID: group.bundleID)
                .frame(width: 16, height: 16)

            Text(group.name)
                .font(.caption.weight(.semibold))
            Text("(\(group.count))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            if group.isMuted {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(reduceMotion ? nil : .default, value: isExpanded)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            guard group.isMuted else {
                return
            }
            onToggle?()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        // An ordinary group is a subheader — the rotor's Headings stop, one
        // level below the day (docs/reference/ACCESSIBILITY.md#day-headers-and-grouping).
        // The muted group is a disclosure instead, so it takes `.isButton`
        // the same way `DisclosureGroup`'s built-in trigger would.
        .accessibilityAddTraits(group.isMuted ? .isButton : .isHeader)
        .accessibilityValue(group.isMuted ? expandedStateText : "")
        // Only the muted group is a stable, testable identity — an ordinary
        // app header's id is per-day and per-app, which XCUITest has no
        // stable way to address (docs/reference/ACCESSIBILITY.md#identifiers-for-ui-tests).
        .accessibilityIdentifier(group.isMuted ? "timeline.mutedGroup" : "")
    }
}

// MARK: - Previews

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        AppGroupHeader(
            group: .init(id: "com.apple.MobileSMS", name: "Messages", count: 4, bundleID: "com.apple.MobileSMS")
        )
        AppGroupHeader(
            group: .init(id: "muted", name: "Muted", count: 3, isMuted: true),
            isExpanded: false
        )
        AppGroupHeader(
            group: .init(id: "muted", name: "Muted", count: 3, isMuted: true),
            isExpanded: true
        )
    }
    .padding()
}
