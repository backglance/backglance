import SwiftUI

// MARK: - EmptyStateView

/// The four reasons the timeline has nothing to draw, and the sentence — plus,
/// for three of the four, a button — that explains which one this is.
///
/// `TimelineStore.emptyStateKind` (`EmptyStateKind`, in `TimelineCaptureState.swift`)
/// decides which kind applies; this view only renders it. Conflating "no Full
/// Disk Access" with "nothing archived yet" is exactly the bug this file exists
/// to prevent — a permissions problem must never read like an empty, working
/// app. Copy is reproduced verbatim from
/// docs/features/TIMELINE.md#edge-cases-and-error-handling; do not paraphrase it
/// here without updating that table too.
///
/// A button only appears when the matching closure is supplied, so a host that
/// cannot act on a kind (a preview, a read-only surface) simply omits it rather
/// than wiring a disabled control.
public struct EmptyStateView: View {
    // MARK: Lifecycle

    public init(
        kind: EmptyStateKind,
        onGrantAccess: (() -> Void)? = nil,
        onResume: (() -> Void)? = nil,
        onClearFilters: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.onGrantAccess = onGrantAccess
        self.onResume = onResume
        self.onClearFilters = onClearFilters
    }

    // MARK: Public

    public let kind: EmptyStateKind
    public var onGrantAccess: (() -> Void)?
    public var onResume: (() -> Void)?
    public var onClearFilters: (() -> Void)?

    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbolName)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)

            if let secondary {
                Text(secondary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Private

    private var symbolName: String {
        switch kind {
        case .noFullDiskAccess: "lock.shield"
        case .paused: "pause.circle"
        case .nothingYet: "tray"
        case .allFiltered: "line.3.horizontal.decrease.circle"
        }
    }

    /// The line every kind has, verbatim from the TIMELINE.md table.
    private var title: String {
        switch kind {
        case .noFullDiskAccess:
            String(localized: "Backglance can't read notifications yet.")

        case .paused:
            String(localized: "Capture is paused.")

        case .nothingYet:
            String(localized: "Nothing here yet. New notifications will appear as they arrive.")

        case .allFiltered:
            String(localized: "No notifications match.")
        }
    }

    /// Only `.paused` has a second line explaining what "paused" costs the user.
    private var secondary: String? {
        switch kind {
        case .paused:
            String(localized: "Notifications that arrive while paused are not archived.")

        case .noFullDiskAccess,
             .nothingYet,
             .allFiltered:
            nil
        }
    }

    private var buttonTitle: String? {
        switch kind {
        case .noFullDiskAccess:
            String(localized: "Grant Full Disk Access…")

        case .paused:
            String(localized: "Resume")

        case .allFiltered:
            String(localized: "Clear filters")

        case .nothingYet:
            nil
        }
    }

    private var action: (() -> Void)? {
        switch kind {
        case .noFullDiskAccess: onGrantAccess
        case .paused: onResume
        case .allFiltered: onClearFilters
        case .nothingYet: nil
        }
    }
}

// MARK: - Previews

/// A no-op the previews can pass by name. A closure literal at the call site
/// would trip SwiftLint's trailing-closure rule, and a trailing closure would
/// bind to the wrong parameter.
private enum PreviewAction {
    static let none: @Sendable () -> Void = {}
}

#Preview("No Full Disk Access") {
    EmptyStateView(kind: .noFullDiskAccess, onGrantAccess: PreviewAction.none)
}

#Preview("Paused") {
    EmptyStateView(kind: .paused, onResume: PreviewAction.none)
}

#Preview("Nothing Yet") {
    EmptyStateView(kind: .nothingYet)
}

#Preview("All Filtered") {
    EmptyStateView(kind: .allFiltered, onClearFilters: PreviewAction.none)
}
