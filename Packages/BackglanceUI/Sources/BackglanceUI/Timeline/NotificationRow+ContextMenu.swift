import AppKit
import BackglanceCore
import SwiftUI

// MARK: - NotificationRow + context menu

/// The row's `.contextMenu` — docs/features/ACTIONS.md#context-menu-specification.
///
/// Split out of `NotificationRow.swift` rather than living beside `body`: the row
/// proper is a value renderer (item in, pixels out), and this is the one part of it
/// that *does* things — dispatches actions, launches tasks, beeps. Keeping the two in
/// separate files means a reader asking "what does this row look like" never has to
/// scroll past a dispatch switch to find out, and it is why `NotificationRow.swift`
/// stays inside SwiftLint's `file_length` limit as the menu grows.
///
/// What each item *says* is not here either — ``NotificationRowMenu`` owns that, and
/// is testable without SwiftUI. This extension only turns those values into
/// `Button`s and sends the result somewhere.
extension NotificationRow {
    /// Whether item 1 ("Open in ‹App›") should render enabled —
    /// ``NotificationActionHandler/canActivateApp(bundleID:)``. That method
    /// is not on ``ActionDispatching`` — its own doc comment says why: it is
    /// a question about menu state, not an action to dispatch, and keeping
    /// the protocol to actions only is what keeps a fake `ActionDispatching`
    /// in a test honest about what it stands in for. So this reaches past
    /// the protocol to the concrete type, the same module-internal step
    /// `NotificationActionHandler.showsOpenLink(deepLink:)` below takes.
    /// `nil`/non-`NotificationActionHandler` dispatchers (a preview, or a
    /// future fake) fall back to `false` — "disabled" is the safe answer
    /// when the row cannot actually check.
    private var canActivateApp: Bool {
        guard let handler = actionDispatcher as? NotificationActionHandler, let bundleID = item.bundleID else {
            return false
        }
        return handler.canActivateApp(bundleID: bundleID)
    }

    /// This row's ``targetIDs(rightClicked:selectionIDs:)``.
    private var targetIDs: [Int64] {
        Self.targetIDs(rightClicked: item.id, selectionIDs: selectionIDs)
    }

    /// The menu itself: `NotificationRowMenu.items(...)` decides what each
    /// entry says, this turns that into `Button`/`Divider` and wires the
    /// dispatch — see `NotificationRowMenu`'s own doc comment for why the
    /// two are split.
    @ViewBuilder
    func contextMenuContent(dispatcher: any ActionDispatching) -> some View {
        let items = NotificationRowMenu.items(
            for: item,
            appName: item.appName,
            selectionCount: targetIDs.count,
            host: host,
            canActivateApp: canActivateApp,
            showsOpenLink: NotificationActionHandler.showsOpenLink(deepLink: item.notification.deepLink)
        )
        // `id: \.offset`, not `Item` itself: this array is rebuilt fresh on
        // every menu presentation from values that do not need a stable
        // identity across redraws — a context menu's content only exists for
        // the moment it is on screen.
        ForEach(Array(items.enumerated()), id: \.offset) { _, menuItem in
            if menuItem.kind == .separator {
                Divider()
            } else {
                Button(menuItem.title) {
                    perform(menuItem.kind, dispatcher: dispatcher)
                }
                .disabled(!menuItem.isEnabled)
            }
        }
    }

    /// Dispatches one tapped menu item.
    ///
    /// Selection-wide items pass ``targetIDs``; the three that are about one
    /// app — Open, Open Link and Notification Settings — pass this row's own
    /// id or bundle id, never the selection's, since "open 3 apps at once" is
    /// not a thing the menu offers.
    private func perform(_ kind: NotificationRowMenu.Kind, dispatcher: any ActionDispatching) {
        switch kind {
        case .open:
            dispatchAsync { try await dispatcher.openNotification(id: item.id) }

        case .openLink:
            dispatchThrowing { try dispatcher.openLink(id: item.id) }

        case .copy:
            dispatchThrowing { try dispatcher.copy(ids: targetIDs, includeAppAndTimestamp: false) }

        case .copyWithAppAndTime:
            dispatchThrowing { try dispatcher.copy(ids: targetIDs, includeAppAndTimestamp: true) }

        case .pin:
            dispatchThrowing { try dispatcher.setPinned(ids: targetIDs, true) }

        case .unpin:
            dispatchThrowing { try dispatcher.setPinned(ids: targetIDs, false) }

        case .markRead:
            dispatchThrowing { try dispatcher.setRead(ids: targetIDs, true) }

        case .markUnread:
            dispatchThrowing { try dispatcher.setRead(ids: targetIDs, false) }

        case .notificationSettings:
            // No bundle id, no app to send System Settings to. The menu
            // still shows this item enabled (docs/features/ACTIONS.md lists
            // no disabled state for it), so the guard is silent rather than
            // surfacing an error for a condition the item's own label never
            // warned about.
            guard let bundleID = item.bundleID else {
                return
            }
            dispatchThrowing { try dispatcher.openNotificationSettings(bundleID: bundleID) }

        case .exportSelection:
            // Hands the ids up rather than exporting: the format is the
            // user's choice, `ExportSheet` is where it is made, and a sheet
            // is the host's to present. Picking CSV here would silently
            // answer the one question this menu item exists to ask.
            onRequestExport?(targetIDs)

        case .delete:
            dispatchThrowing { try dispatcher.delete(ids: targetIDs) }

        case .separator:
            break // Never tapped: `contextMenuContent` draws a `Divider()` for this kind instead of a `Button`.
        }
    }

    /// Runs a synchronous dispatch call, routing a thrown ``ActionError`` to
    /// ``handle(_:)``. Shared by every non-`async` branch in ``perform(_:dispatcher:)``
    /// so each one is a single line instead of repeating the same `do`/`catch`.
    private func dispatchThrowing(_ action: () throws -> Void) {
        do {
            try action()
        } catch let error as ActionError {
            handle(error)
        } catch {}
    }

    /// The `async` counterpart to ``dispatchThrowing(_:)``, for
    /// ``ActionDispatching/openNotification(id:)`` and
    /// ``ActionDispatching/exportSelection(_:format:)`` — the two branches in
    /// ``perform(_:dispatcher:)`` that need a `Task` at all. Splitting this out
    /// (rather than inlining `Task { do { ... } catch { ... } }` twice) is what
    /// keeps `perform(_:dispatcher:)`'s `switch` at one branch per menu kind
    /// instead of one branch per menu kind *plus* a nested `catch`.
    private func dispatchAsync(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch let error as ActionError {
                handle(error)
            } catch {}
        }
    }

    /// Routes a dispatch failure per docs/features/ACTIONS.md's error table:
    /// `.deepLinkUnresolvable` is the one case whose ``ActionError/userMessage``
    /// is `nil` by design, mapped to a system beep instead of text; every
    /// other case is handed to ``onActionError`` for the caller to show —
    /// this row never builds its own alert.
    private func handle(_ error: ActionError) {
        if error.userMessage == nil {
            NSSound.beep()
        } else {
            onActionError?(error)
        }
    }
}
