import Observation
import SwiftUI

// MARK: - CaptureBannerModel

/// Whether the Full Disk Access banner is showing, and what its buttons do.
///
/// One instance for the whole app, so dismissing the banner in the popover also dismisses it
/// in the window — they are the same banner about the same condition, and having to close it
/// twice would read as it not having been closed.
///
/// The dismissal is per *session*: it comes back on the next launch. That is deliberate and
/// worth defending, because a banner that returns is annoying by design. Capture being off is
/// silent — no missing rows announce themselves — and someone who dismissed this three months
/// ago has an app that has quietly archived nothing since. Once per launch is the least
/// nagging thing that still tells the truth.
@MainActor
@Observable
public final class CaptureBannerModel {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - openSystemSettings: opens the Full Disk Access pane.
    ///   - checkAgain: re-probes now.
    ///   - learnWhy: shows the explanation — the same screen setup uses.
    ///   - resumeCapture: ends a pause.
    public init(
        openSystemSettings: @escaping () -> Void = {},
        checkAgain: @escaping () -> Void = {},
        learnWhy: @escaping () -> Void = {},
        resumeCapture: @escaping () -> Void = {}
    ) {
        self.openSystemSettings = openSystemSettings
        self.checkAgain = checkAgain
        self.learnWhy = learnWhy
        self.resumeCapture = resumeCapture
    }

    // MARK: Public

    /// Whether the user has closed the banner this launch.
    public private(set) var isDismissed = false

    public let openSystemSettings: () -> Void
    public let checkAgain: () -> Void
    public let learnWhy: () -> Void
    public let resumeCapture: () -> Void

    public func dismiss() {
        isDismissed = true
    }
}

// MARK: - CaptureBannerStrip

/// Whichever banner the capture state calls for, in whichever surface is showing.
///
/// The popover and the window both end in this one view rather than each deciding for
/// themselves, so a state that grows a banner grows it in both places at once.
public struct CaptureBannerStrip: View {
    // MARK: Lifecycle

    public init(state: TimelineCaptureState, model: CaptureBannerModel) {
        self.state = state
        self.model = model
    }

    // MARK: Public

    public var body: some View {
        switch state {
        case .noFullDiskAccess:
            if !model.isDismissed {
                Divider()
                FDABanner(model: model)
            }

        case .paused,
             .degraded,
             .stopped:
            Divider()
            CaptureStatusBanner(state: state, onResume: model.resumeCapture)

        case .running:
            EmptyView()
        }
    }

    // MARK: Private

    private let state: TimelineCaptureState
    private let model: CaptureBannerModel
}

// MARK: - FDABanner

/// The one persistent line shown while capture is off for want of Full Disk Access.
///
/// Everything about it is a decision not to nag. No modal, because there is nothing to
/// confirm. No local notification, because an app asking for permission through a
/// notification is the behaviour this app exists to keep a record of. No badge, and no
/// gating of unrelated features to apply pressure — the timeline, search, export and every
/// privacy control keep working without the permission, and pretending otherwise would be a
/// way of holding the user's own archive hostage.
///
/// The second line is the honest part: Backglance cannot request this permission. macOS has
/// no prompt for `SystemPolicyAllFiles`, so the button below opens System Settings and that
/// is the most any app can do. Saying so is what stops "Open System Settings" reading as a
/// button that failed to work.
///
/// See docs/features/PERMISSIONS_PRIVACY.md#degraded-mode-without-fda.
public struct FDABanner: View {
    // MARK: Lifecycle

    public init(model: CaptureBannerModel) {
        self.model = model
    }

    // MARK: Public

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Full Disk Access needed to capture new notifications."))
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(String(localized: """
                Your existing archive still works. Backglance can only guide you to the setting — \
                macOS has no prompt for this permission.
                """))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                buttons
            }

            Spacer(minLength: 4)
            dismissButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture.fdaBanner")
    }

    // MARK: Private

    private let model: CaptureBannerModel

    private var buttons: some View {
        HStack(spacing: 8) {
            Button(String(localized: "Open System Settings")) { model.openSystemSettings() }
                .accessibilityIdentifier("capture.fdaBanner.openSettings")

            Button(String(localized: "Check again")) { model.checkAgain() }
                .accessibilityIdentifier("capture.fdaBanner.checkAgain")

            Button(String(localized: "Learn why")) { model.learnWhy() }
                .buttonStyle(.link)
                .accessibilityIdentifier("capture.fdaBanner.learnWhy")
        }
        .controlSize(.small)
    }

    /// Small, and last in the reading order. Closing is allowed — being unable to dismiss a
    /// banner is its own kind of nagging — but it should not be the easiest thing on it.
    private var dismissButton: some View {
        Button {
            model.dismiss()
        } label: {
            Image(systemName: "xmark")
                .imageScale(.small)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel(Text(String(localized: "Dismiss until next launch")))
        .accessibilityIdentifier("capture.fdaBanner.dismiss")
    }
}

#Preview {
    FDABanner(model: CaptureBannerModel())
        .frame(width: 380)
}
