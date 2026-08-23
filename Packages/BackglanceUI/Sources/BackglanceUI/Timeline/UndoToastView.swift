import SwiftUI

// MARK: - UndoToastView

/// The 5-second toast that follows a delete — see docs/features/ACTIONS.md#undo-toast
/// and docs/features/ACTIONS.md#delete-and-undo.
///
/// A plain, stateless view: `count` and `onUndo` are everything it needs, the same
/// shape as ``CaptureStatusBanner`` (state in, callback out) rather than a reference
/// to ``NotificationActionHandler`` itself. That keeps it previewable with no archive
/// behind it and, more importantly, keeps the *timing* — when the toast appears, how
/// long it stays, what "Undo" actually restores — entirely in the handler, where
/// ``NotificationActionHandlerTests``/``DeleteUndoTests`` can drive it with an
/// injected ``UndoClock`` instead of a real 5-second wait. This view draws whatever
/// count it is handed, for exactly as long as its host chooses to keep it on screen.
///
/// > Note: Not wired into ``TimelineView`` yet. Doing that needs a place to read
/// > `NotificationActionHandler.pendingUndo` from and a selection to build `ids` out
/// > of for the row context menu's Delete item — both are the multi-select model and
/// > context menu that ship in BACKGLANCE-202/203. The connection, once that lands,
/// > is exactly this shape:
/// > ```swift
/// > if !handler.pendingUndo.isEmpty {
/// >     UndoToastView(count: handler.pendingUndo.count) {
/// >         try? handler.undoDelete()
/// >     }
/// > }
/// > ```
/// > This task ships the view and ``NotificationActionHandler``'s delete/undo API on
/// > their own so that shape is ready the moment the selection model exists.
public struct UndoToastView: View {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - count: how many notifications the delete that triggered this toast
    ///     actually flipped — ``NotificationActionHandler/pendingUndo``'s count, not
    ///     the size of whatever selection was acted on (docs/features/ACTIONS.md#delete-and-undo:
    ///     a row already deleted by another window is not part of what this undo
    ///     restores, so it should not be part of what the toast claims either).
    ///   - onUndo: fired by the Undo button and by ⌘Z while this view is on screen.
    public init(count: Int, onUndo: @escaping () -> Void) {
        self.count = count
        self.onUndo = onUndo
    }

    // MARK: Public

    public let count: Int
    public let onUndo: () -> Void

    public var body: some View {
        ToastPresentation(accessibilityIdentifier: "timeline.undoToast") {
            Text(Self.message(count: count))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button(String(localized: "Undo"), action: onUndo)
                .buttonStyle(.link)
                // Also reachable the way docs/features/ACTIONS.md's keyboard table
                // specifies: ⌘Z while the toast is visible, no different from a click.
                // SwiftUI only honours a `.keyboardShortcut` while the view carrying it
                // is actually in the hierarchy, which is exactly "while the toast is
                // visible" — no separate visibility check needed here.
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityIdentifier("timeline.undoToast.undo")
        }
    }

    // MARK: Internal

    /// "Deleted 1 notification" / "Deleted 3 notifications".
    ///
    /// docs/reference/INTERNATIONALIZATION.md#plural-rules asks for an interpolated
    /// count left to the string catalog's plural variants rather than a hand-written
    /// `count == 1 ? … : …`, and ``DigestViewModel/headline`` does exactly that. This
    /// does not: `Backglance/Resources/Localizable.xcstrings` ships with no entries
    /// yet (every string in the app is in the same boat, awaiting a dedicated
    /// localization pass), and this package's tests have no host application — their
    /// `Bundle.main` is the test runner, not `Backglance.app` — so a catalog entry
    /// here would compile correctly and then silently never resolve in
    /// ``UndoToastViewTests``, or in the running app until that pass lands. Two
    /// `String(localized:)` calls, one per branch, are each independently
    /// translatable today and correct *right now* without depending on that pass —
    /// the same trade ``StatusItemAccessibility/label(unreadCount:state:)`` already
    /// makes for its own count-dependent text, for the same reason.
    ///
    /// A `static func` rather than a computed property on the view so
    /// ``UndoToastViewTests`` can assert the exact copy for `1` and for `n` without
    /// standing up a SwiftUI hierarchy to inspect.
    static func message(count: Int) -> String {
        if count == 1 {
            String(localized: "Deleted 1 notification")
        } else {
            String(localized: "Deleted \(count) notifications")
        }
    }
}

// MARK: - Previews

#Preview("Singular") {
    UndoToastView(count: 1) {}
        .frame(width: 380)
}

#Preview("Plural") {
    UndoToastView(count: 3) {}
        .frame(width: 380)
}
