import SwiftUI

// MARK: - ArchiveHealthBanner

/// A compact, inline notice that an archive read failed.
///
/// docs/features/TIMELINE.md#edge-cases-and-error-handling is explicit about
/// this: every failure on the read path — the live subscription throwing, a
/// page fetch throwing — is a banner, never a modal and never a crash. Rows
/// already loaded stay on screen underneath it, because a stale page with a
/// banner beats a blank timeline. This view only draws that banner; deciding
/// when one is warranted, and what the message says, belongs to
/// `TimelineStore.loadError`.
public struct ArchiveHealthBanner: View {
    // MARK: Lifecycle

    public init(message: String, onRetry: (() -> Void)? = nil) {
        self.message = message
        self.onRetry = onRetry
    }

    // MARK: Public

    /// A one-sentence, content-free explanation of the failure —
    /// `TimelineStore.message(for:)` never lets a notification's own text
    /// reach here.
    public let message: String

    /// Fired by the "Retry" button. `nil` hides the button entirely, which is
    /// how a preview renders the banner without wiring a retry path.
    public var onRetry: (() -> Void)?

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(message)
                .font(.callout)
                .lineLimit(2)

            Spacer(minLength: 4)

            if let onRetry {
                Button(
                    String(localized: "Retry", comment: "Banner button: tries the failed archive read again"),
                    action: onRetry
                )
                .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

#Preview("With retry") {
    ArchiveHealthBanner(message: "Backglance couldn't read the archive.") {}
}

#Preview("No retry") {
    ArchiveHealthBanner(message: "Backglance couldn't read the archive.")
}
