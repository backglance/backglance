import SwiftUI

// MARK: - ImportState

/// How the first-launch import is going, as far as the UI needs to know.
///
/// A mirror of what `CaptureEngine.importExisting` reports, for the reason
/// ``TimelineCaptureState`` gives — `BackglanceUI` cannot see `BackglanceCapture` — and
/// reduced to what the screen actually draws: a running count, then a final one.
public enum ImportState: Equatable, Sendable {
    /// Not running. Setup was skipped, or access was never granted.
    case idle

    /// Reading. `archived` is what has been written so far; `expectedTotal` is the store's
    /// own count where the adapter could get one, and `nil` where it could not — which is why
    /// the bar is indeterminate rather than pretending to a percentage.
    case running(archived: Int, expectedTotal: Int?)

    /// Done. `archived` is the final count.
    case finished(archived: Int)

    /// The import failed. Not fatal to setup: live capture is unaffected, and what was
    /// already written stays.
    case failed

    // MARK: Public

    public var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }
}

// MARK: - ImportProgressView

/// The first-launch import, while it runs and after it stops.
///
/// The line that does the real work here is the last one: *this is everything the system
/// still had*. macOS prunes its own notification store after a few days, so a new user who
/// installs Backglance expecting to recover last month gets last Tuesday — and without that
/// sentence they will reasonably conclude the import is broken rather than that the data was
/// already gone. It is the single most important piece of copy in onboarding, and it is why
/// the finished state says it every time rather than only when the count looks low.
///
/// See docs/features/CAPTURE.md#first-launch-import.
public struct ImportProgressView: View {
    // MARK: Lifecycle

    public init(progress: ImportState) {
        self.progress = progress
    }

    // MARK: Public

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch progress {
            case .idle:
                EmptyView()

            case let .running(archived, expectedTotal):
                running(archived: archived, expectedTotal: expectedTotal)

            case let .finished(archived):
                Text(countSentence(archived: archived))
                    .accessibilityIdentifier("onboarding.import.finished")
                Text(String(localized: "This is everything the system still had."))
                    .font(.callout)
                    .foregroundStyle(.secondary)

            case .failed:
                Label(Self.failureText, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onboarding.import.failed")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Private

    private static var failureText: String {
        String(localized: """
        Backglance couldn’t import the older notifications. New ones are still being archived.
        """)
    }

    private let progress: ImportState

    @ViewBuilder
    private func running(archived: Int, expectedTotal: Int?) -> some View {
        // Determinate only when the adapter could count the store. A bar that invents a
        // percentage and then jumps is worse than one that honestly says "working".
        if let expectedTotal, expectedTotal > 0 {
            ProgressView(value: Double(archived), total: Double(expectedTotal))
                .accessibilityIdentifier("onboarding.import.progress")
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .accessibilityIdentifier("onboarding.import.progress")
        }

        Text(countSentence(archived: archived))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    /// "Imported 143 notifications." Pluralised through the string catalog rather than by
    /// hand, because "1 notifications" is the kind of thing that survives review and then
    /// ships (docs/reference/INTERNATIONALIZATION.md#plural-rules).
    ///
    /// The count is interpolated plainly and the plural lives in the catalog entry's
    /// variations. It was written as `^[…](inflect: true)` until BACKGLANCE-248: automatic
    /// grammar agreement compiles to nothing here, so the markup reached the screen.
    private func countSentence(archived: Int) -> String {
        String(localized: "Imported \(archived) notifications.")
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 20) {
        ImportProgressView(progress: .running(archived: 143, expectedTotal: 400))
        ImportProgressView(progress: .running(archived: 143, expectedTotal: nil))
        ImportProgressView(progress: .finished(archived: 143))
        ImportProgressView(progress: .failed)
    }
    .padding()
    .frame(width: 420)
}
