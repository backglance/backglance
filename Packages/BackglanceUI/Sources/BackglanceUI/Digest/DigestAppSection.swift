import BackglanceCore
import SwiftUI

// MARK: - DigestAppSection

/// One app's block inside the digest: icon, name, count, and that app's rows.
///
/// The rows are ``NotificationRow`` in compact mode — the same row the timeline draws,
/// not a digest-specific copy of it. A summary that rendered notifications differently
/// from the timeline would make the user learn two layouts for one thing, and every fix
/// to one would have to be made twice.
///
/// The header is deliberately not a ``AppGroupHeader``: that one carries the timeline's
/// collapse affordance for muted groups, and inside the digest an app section is
/// informational — the muted rows live behind their own disclosure in ``DigestView``.
///
/// See docs/features/MISSED_DIGEST.md#digestview.
public struct DigestAppSection: View {
    // MARK: Lifecycle

    public init(section: DigestSection, onOpen: ((Int64) -> Void)? = nil) {
        self.section = section
        self.onOpen = onOpen
    }

    // MARK: Public

    public let section: DigestSection

    /// Fired on tap with the row's archive id. `nil` leaves the rows inert.
    public let onOpen: ((Int64) -> Void)?

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(section.items) { item in
                NotificationRow(item: item, mode: .compact, onOpen: onOpen)
            }
        }
    }

    // MARK: Private

    private var header: some View {
        HStack(spacing: 8) {
            AppIconView(bundleID: section.bundleID)
                .frame(width: 16, height: 16)

            Text(section.appName)
                .font(.caption.weight(.semibold))
            Text("(\(section.items.count))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(section.appName), \(section.items.count) notifications"))
        // A heading, so the VoiceOver rotor can jump app to app through a long digest
        // (docs/reference/ACCESSIBILITY.md#day-headers-and-grouping).
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Previews

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        DigestAppSection(
            section: .init(
                id: "app.backglance.fixture.mail",
                appName: "Fixture Mail",
                bundleID: "app.backglance.fixture.mail",
                items: Array(PreviewData.items.prefix(2))
            )
        )
        DigestAppSection(
            section: .init(
                id: "app.backglance.fixture.chat",
                appName: "Fixture Chat",
                bundleID: "app.backglance.fixture.chat",
                items: Array(PreviewData.items.suffix(2))
            )
        )
    }
    .padding(.vertical, 8)
    .frame(width: 360)
}
