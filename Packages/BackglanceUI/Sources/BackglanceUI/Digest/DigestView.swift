import BackglanceCore
import SwiftUI

// MARK: - DigestView

/// The "what did I miss" card, shown at the top of the popover the first time it opens
/// after a digest is built, and reachable later via `backglance://digest` and the
/// "Last digest" menu item.
///
/// Two things this view deliberately does not do. It does not decide *whether* it should
/// appear — that is the never-nagging contract
/// (docs/features/MISSED_DIGEST.md#never-nagging-rules), and it lives in the host that
/// owns the popover. And it does not build its own rows: ``DigestViewModel`` hands it
/// sections that are already grouped and ranked, so what is drawn here is exactly what
/// `DigestEngine` decided, in that order.
///
/// Loading and the once-only `shown_at` stamp happen in `.task`, together: the moment
/// the card is on screen is the moment it has been shown.
///
/// See docs/features/MISSED_DIGEST.md#digestview.
public struct DigestView: View {
    // MARK: Lifecycle

    public init(model: DigestViewModel) {
        self.model = model
    }

    // MARK: Public

    public let model: DigestViewModel

    public var body: some View {
        DigestCard(
            reasonSymbol: model.primaryReasonSymbol,
            headline: model.headline,
            subheadline: model.subheadline,
            isPartial: model.isPartial,
            isReconstructed: model.isReconstructed,
            dayCounts: model.dayCounts,
            appSections: model.appSections,
            mutedItems: model.mutedItems,
            overflowCount: model.overflowCount,
            loadError: model.loadError,
            canOpenTimeline: model.session != nil,
            onDismiss: { model.dismiss() },
            onOpenTimeline: { model.openTimelineAtSession() },
            onMarkAllRead: { model.markAllRead() }
        )
        .task {
            model.load()
            model.markShown()
        }
    }
}

// MARK: - DigestCard

/// ``DigestView`` with the view model taken out of it.
///
/// The split is what makes the card previewable and testable: every state it can be in —
/// overflowing, muted-only, a failed read — is reachable from plain values here, where
/// reaching them through the model would mean seeding an archive first. It is public for
/// the same reason: a host that already has the numbers (a preview, a screenshot harness,
/// a widget) can draw the card without standing up an archive to get them from.
public struct DigestCard: View {
    // MARK: Lifecycle

    public init(
        reasonSymbol: String,
        headline: String,
        subheadline: String,
        isPartial: Bool = false,
        isReconstructed: Bool = false,
        dayCounts: [DigestDayCount] = [],
        appSections: [DigestSection],
        mutedItems: [TimelineItem] = [],
        overflowCount: Int = 0,
        loadError: String? = nil,
        canOpenTimeline: Bool = true,
        onDismiss: @escaping () -> Void,
        onOpenTimeline: @escaping () -> Void,
        onMarkAllRead: @escaping () -> Void,
        onOpenRow: ((Int64) -> Void)? = nil
    ) {
        self.reasonSymbol = reasonSymbol
        self.headline = headline
        self.subheadline = subheadline
        self.isPartial = isPartial
        self.isReconstructed = isReconstructed
        self.dayCounts = dayCounts
        self.appSections = appSections
        self.mutedItems = mutedItems
        self.overflowCount = overflowCount
        self.loadError = loadError
        self.canOpenTimeline = canOpenTimeline
        self.onDismiss = onDismiss
        self.onOpenTimeline = onOpenTimeline
        self.onMarkAllRead = onMarkAllRead
        self.onOpenRow = onOpenRow
    }

    // MARK: Public

    public let reasonSymbol: String
    public let headline: String
    public let subheadline: String
    public let isPartial: Bool
    public let isReconstructed: Bool
    public let dayCounts: [DigestDayCount]
    public let appSections: [DigestSection]
    public let mutedItems: [TimelineItem]
    public let overflowCount: Int
    public let loadError: String?

    /// Whether the digest has a session to open the timeline at. `false` leaves the
    /// footer button out rather than showing one that would do nothing.
    public let canOpenTimeline: Bool

    public let onDismiss: () -> Void
    public let onOpenTimeline: () -> Void
    public let onMarkAllRead: () -> Void

    /// Fired on a row tap with its archive id. `nil` leaves the rows inert.
    public let onOpenRow: ((Int64) -> Void)?

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DigestHeader(
                reasonSymbol: reasonSymbol,
                headline: headline,
                subheadline: subheadline,
                isPartial: isPartial,
                isReconstructed: isReconstructed,
                dayCounts: dayCounts,
                onDismiss: onDismiss
            )

            Divider()

            // A failed read is a line on the card, not a dialog: the notifications are
            // archived either way, and the timeline underneath still works.
            if let loadError {
                ArchiveHealthBanner(message: loadError)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(appSections) { section in
                        DigestAppSection(section: section, onOpen: onOpenRow)
                    }

                    if !mutedItems.isEmpty {
                        mutedGroup
                    }

                    if overflowCount > 0 {
                        Button(action: onOpenTimeline) {
                            Text("and \(overflowCount) more…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("digest.overflow")
                    }
                }
            }
            .frame(maxHeight: Self.listMaxHeight)

            footer
        }
        .padding(12)
        .accessibilityIdentifier("digest.card")
    }

    // MARK: Private

    /// The card is a summary, not a second timeline: past this the list scrolls and the
    /// popover's own timeline stays visible underneath.
    private static let listMaxHeight: CGFloat = 380

    /// Muted rows start collapsed, exactly as they do in the timeline
    /// (docs/features/TIMELINE.md#grouping). They are in the digest — muting
    /// de-prioritizes rather than hides — just not in the way of everything else.
    @State private var isMutedExpanded = false

    private var mutedGroup: some View {
        DisclosureGroup(isExpanded: $isMutedExpanded) {
            ForEach(mutedItems) { item in
                NotificationRow(item: item, mode: .compact, onOpen: onOpenRow)
            }
        } label: {
            Text("\(mutedItems.count) more from muted apps")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .accessibilityIdentifier("digest.mutedGroup")
    }

    private var footer: some View {
        HStack {
            if canOpenTimeline {
                Button("Open timeline at this point", action: onOpenTimeline)
                    .accessibilityIdentifier("digest.openTimeline")
            }
            Spacer()
            Button("Mark all read", action: onMarkAllRead)
                .accessibilityIdentifier("digest.markAllRead")
        }
        .font(.callout)
    }
}

// MARK: - Previews

#Preview("Digest") {
    DigestCard(
        reasonSymbol: "lock.fill",
        headline: "You missed 12 notifications from 4 apps",
        subheadline: "while locked · 47 min · ended 09:12",
        isPartial: false,
        isReconstructed: false,
        dayCounts: [],
        appSections: PreviewData.digestSections,
        mutedItems: [],
        overflowCount: 0,
        loadError: nil,
        canOpenTimeline: true,
        onDismiss: {},
        onOpenTimeline: {},
        onMarkAllRead: {}
    )
    .frame(width: 380)
}

#Preview("Muted, overflowing and partial") {
    DigestCard(
        reasonSymbol: "moon.fill",
        headline: "You missed 87 notifications from 9 apps",
        subheadline: "while in a Focus · 2 h 05 min · ended 18:40",
        isPartial: true,
        isReconstructed: false,
        dayCounts: [],
        appSections: PreviewData.digestSections,
        mutedItems: Array(PreviewData.items.suffix(2)),
        overflowCount: 37,
        loadError: nil,
        canOpenTimeline: true,
        onDismiss: {},
        onOpenTimeline: {},
        onMarkAllRead: {}
    )
    .frame(width: 380)
}
