import SwiftUI

// MARK: - CaptureStatusBanner

/// The one line the timeline shows when capture is not simply running.
///
/// Degraded is a *state*, not an error: there are no modal alerts anywhere on
/// the capture path, because the honest response to "macOS changed the store
/// format" or "Full Disk Access was revoked" is to keep showing the archive and
/// say what is happening above it (docs/features/CAPTURE.md#ui-components).
///
/// The banner is deliberately quiet when capture is fine — it renders nothing
/// at all for ``TimelineCaptureState/running``, so the popover's chrome does not
/// grow a permanent strip of green reassurance.
///
/// Only the state that the user can actually fix gets a button. "The store
/// changed shape" has no action behind it, and a disabled button that explains
/// nothing is worse than no button.
public struct CaptureStatusBanner: View {
    // MARK: Lifecycle

    public init(
        state: TimelineCaptureState,
        onGrantAccess: (() -> Void)? = nil,
        onResume: (() -> Void)? = nil
    ) {
        self.state = state
        self.onGrantAccess = onGrantAccess
        self.onResume = onResume
    }

    // MARK: Public

    public let state: TimelineCaptureState
    public let onGrantAccess: (() -> Void)?
    public let onResume: (() -> Void)?

    public var body: some View {
        if let message {
            HStack(spacing: 8) {
                Image(systemName: symbolName)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                if let button, let action {
                    Button(button, action: action)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Private

    /// A pause's end is a wall-clock time the user picked from a menu, so it is
    /// shown the way they chose it rather than as a duration counting down.
    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    /// `nil` while capture is running — the banner's whole job is to be absent then.
    private var message: String? {
        switch state {
        case .running:
            nil

        case let .paused(until):
            if let until {
                String(localized: "Capture is paused until \(Self.time.string(from: until)).")
            } else {
                String(localized: "Capture is paused.")
            }

        case .noFullDiskAccess:
            String(localized: "Backglance needs Full Disk Access to read new notifications.")

        case let .degraded(message):
            message

        case .stopped:
            String(localized: "Capture isn't running.")
        }
    }

    private var symbolName: String {
        switch state {
        case .paused:
            "pause.circle"

        case .noFullDiskAccess:
            "lock.shield"

        case .running,
             .degraded,
             .stopped:
            "exclamationmark.triangle"
        }
    }

    private var button: String? {
        switch state {
        case .noFullDiskAccess:
            String(localized: "Grant Full Disk Access…")

        case .paused:
            String(localized: "Resume")

        case .running,
             .degraded,
             .stopped:
            nil
        }
    }

    private var action: (() -> Void)? {
        switch state {
        case .noFullDiskAccess:
            onGrantAccess

        case .paused:
            onResume

        case .running,
             .degraded,
             .stopped:
            nil
        }
    }
}

// MARK: - Previews

#Preview("Degraded") {
    CaptureStatusBanner(state: .noFullDiskAccess, onGrantAccess: PreviewBannerAction.none)
        .frame(width: 380)
}

#Preview("Paused") {
    CaptureStatusBanner(state: .paused(until: nil), onResume: PreviewBannerAction.none)
        .frame(width: 380)
}

// MARK: - PreviewBannerAction

/// A no-op the previews pass by name; a closure literal would trip SwiftLint's
/// trailing-closure rule and a trailing closure would bind to the wrong argument.
private enum PreviewBannerAction {
    static let none: @Sendable () -> Void = {}
}
