import SwiftUI

// MARK: - MessageToastView

/// A short, dismissable toast for a message that has nothing to undo — the general
/// sibling to ``UndoToastView``'s one specific action.
///
/// `backglance://open?id=` is the first caller: a uuid the archive has never seen, or
/// can no longer reach, becomes ``TimelineStore/message`` and shows up here
/// (docs/api/API_DOCUMENTATION.md#error-behavior, "Not in the archive"). Kept apart
/// from ``UndoToastView`` rather than folding an optional message into it: that view's
/// `count` and `onUndo` are load-bearing for one flow, and bending them to also carry
/// an arbitrary string would make both harder to read for what either actually does.
/// The two share their look through ``ToastPresentation``, not through one view
/// pretending to be two.
///
/// A plain, stateless view, the same shape ``UndoToastView`` and ``ActionErrorBanner``
/// already are: `message` in, nothing out. Timing — when it appears, how long it stays
/// — is `TimelineView`'s job, the same split ``UndoToastView``'s own doc comment
/// explains for `NotificationActionHandler`.
public struct MessageToastView: View {
    // MARK: Lifecycle

    public init(message: String) {
        self.message = message
    }

    // MARK: Public

    public let message: String

    public var body: some View {
        ToastPresentation(accessibilityIdentifier: "timeline.messageToast", accessibilityChildren: .combine) {
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Previews

#Preview("Not in the archive") {
    MessageToastView(message: String(localized: "Not in the archive"))
        .frame(width: 380)
}
