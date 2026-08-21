import BackglanceCore
import SwiftUI

// MARK: - DigestHeader

/// The digest card's top line: reason glyph, headline, the "while locked · 47 min ·
/// ended 09:12" subheadline, the honesty badges, and the dismiss button.
///
/// A pure value renderer, like ``NotificationRow`` — it is handed strings and flags,
/// never the view model, so a preview can draw every combination of badges without an
/// archive behind it.
///
/// The badges are the part that matters. `isPartial` and `isReconstructed` are the two
/// ways a digest can be *incomplete*, and the feature's first design goal is that it be
/// trustworthy (docs/features/MISSED_DIGEST.md#feature-overview). A card that quietly
/// summarised half a window would be worse than no card, so when the data is partial the
/// card says so in words.
///
/// See docs/features/MISSED_DIGEST.md#digestview.
public struct DigestHeader: View {
    // MARK: Lifecycle

    public init(
        reasonSymbol: String,
        headline: String,
        subheadline: String,
        isPartial: Bool = false,
        isReconstructed: Bool = false,
        dayCounts: [DigestDayCount] = [],
        onDismiss: (() -> Void)? = nil
    ) {
        self.reasonSymbol = reasonSymbol
        self.headline = headline
        self.subheadline = subheadline
        self.isPartial = isPartial
        self.isReconstructed = isReconstructed
        self.dayCounts = dayCounts
        self.onDismiss = onDismiss
    }

    // MARK: Public

    /// SF Symbol for the session's primary reason — `lock.fill`, `powersleep`,
    /// `moon.fill`, `rectangle.on.rectangle`, `hand.raised.fill`.
    public let reasonSymbol: String

    /// "You missed 12 notifications from 4 apps".
    public let headline: String

    /// "while locked · 47 min · ended 09:12".
    public let subheadline: String

    /// Backglance started mid-session, so the window shown begins at launch.
    public let isPartial: Bool

    /// The session was rebuilt after the fact rather than observed live.
    public let isReconstructed: Bool

    /// Per-day counts for a session that spans days — "Fri 34 · Sat 12 · Sun 41". Empty
    /// for the ordinary same-day session, where it would only repeat the headline.
    public let dayCounts: [DigestDayCount]

    /// Fired by the close button. `nil` leaves the button out, which is how the
    /// read-only "Last digest" reopen renders a card that cannot be dismissed twice.
    public let onDismiss: (() -> Void)?

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: reasonSymbol)
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.headline)
                Text(subheadline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !dayCounts.isEmpty {
                    Text(dayBreakdown)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isPartial {
                    badge(
                        String(
                            localized: "Partial — counted from when Backglance started",
                            comment: "Digest badge: the app launched into an already-away Mac"
                        ),
                        systemImage: "hourglass.bottomhalf.filled"
                    )
                }
                if isReconstructed {
                    badge(
                        String(
                            localized: "Reconstructed — Backglance wasn't running for part of this time",
                            comment: "Digest badge: the session was rebuilt from store timestamps"
                        ),
                        systemImage: "clock.arrow.circlepath"
                    )
                }
            }

            Spacer(minLength: 4)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss digest"))
                .accessibilityIdentifier("digest.dismiss")
            }
        }
        // The glyph is hidden and the badges read as part of one element, so VoiceOver
        // hears the summary as a sentence instead of five fragments
        // (docs/reference/ACCESSIBILITY.md#voiceover). The dismiss button stays its own
        // element — it is the only thing here that does anything.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("digest.header")
    }

    // MARK: Private

    /// "Fri 34 · Sat 12 · Sun 41" — the weekday alone, because a session long enough to
    /// need this is short enough that the day names are unambiguous.
    private var dayBreakdown: String {
        dayCounts
            .map { "\($0.id.formatted(.dateTime.weekday(.abbreviated))) \($0.count)" }
            .joined(separator: " · ")
    }

    private func badge(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }
}

// MARK: - Previews

#Preview("Locked") {
    DigestHeader(
        reasonSymbol: "lock.fill",
        headline: "You missed 12 notifications from 4 apps",
        subheadline: "while locked · 47 min · ended 09:12"
    ) {}
        .padding()
        .frame(width: 360)
}

#Preview("Partial and reconstructed") {
    DigestHeader(
        reasonSymbol: "moon.fill",
        headline: "You missed 87 notifications from 9 apps",
        subheadline: "while in a Focus · 2 h 05 min · ended 18:40",
        isPartial: true,
        isReconstructed: true,
        dayCounts: [
            .init(id: Date(timeIntervalSince1970: 1_755_000_000), count: 34),
            .init(id: Date(timeIntervalSince1970: 1_755_086_400), count: 12),
            .init(id: Date(timeIntervalSince1970: 1_755_172_800), count: 41),
        ]
    ) {}
        .padding()
        .frame(width: 360)
}
