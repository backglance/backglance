import AppKit
import Foundation

// MARK: - ActionDispatchRouting

/// Where a dispatched ``ActionError`` goes, shared by every call site that
/// dispatches through ``ActionDispatching``: the row's context menu
/// (`NotificationRow+ContextMenu.swift`, BACKGLANCE-203 part 1) and the
/// timeline's keyboard shortcuts (`TimelineView+Keyboard.swift`,
/// BACKGLANCE-203 part 2).
///
/// Both call sites need to apply the exact same routing
/// docs/features/ACTIONS.md's error table specifies:
/// `.deepLinkUnresolvable` is a system beep and nothing else, every other
/// case is inline text for the caller to show, and no case ever becomes an
/// alert. Before this type existed that routing lived only in
/// `NotificationRow+ContextMenu.swift`'s private `handle(_:)`; lifting it
/// here is what lets the keyboard shortcuts reuse it instead of a second
/// `if error.userMessage == nil { NSSound.beep() } else { ... }` copy.
enum ActionDispatchRouting {
    /// Runs a synchronous dispatch call, routing a thrown ``ActionError``
    /// through ``route(_:onError:)``. A throw that is not an ``ActionError``
    /// is swallowed silently — every ``ActionDispatching`` method only ever
    /// throws ``ActionError``, so this `catch {}` is defensive, not a case
    /// either call site expects to hit.
    ///
    /// - Returns: whether `action` completed without throwing. Most callers
    ///   (a plain ⌘C, a pin toggle) discard this; ⌫'s "selection moves to
    ///   the next row" is the one place that needs to know the delete it
    ///   just ran actually succeeded before moving the keyboard focus onto
    ///   a row that was computed assuming it would.
    @discardableResult
    static func run(_ action: () throws -> Void, onError: (ActionError) -> Void) -> Bool {
        do {
            try action()
            return true
        } catch let error as ActionError {
            route(error, onError: onError)
            return false
        } catch {
            return false
        }
    }

    /// The `async` counterpart to ``run(_:onError:)``, for the two dispatch
    /// methods that are themselves `async` —
    /// ``ActionDispatching/openNotification(id:)`` and
    /// ``ActionDispatching/exportSelection(_:format:)``. Wraps `action` in
    /// its own `Task` so a caller sitting in a synchronous SwiftUI closure —
    /// a context-menu `Button`, an `.onKeyPress` handler, `ExportSheet`'s
    /// `onExport` — can fire it without itself needing to be `async`.
    static func runAsync(_ action: @escaping () async throws -> Void, onError: @escaping (ActionError) -> Void) {
        Task {
            do {
                try await action()
            } catch let error as ActionError {
                route(error, onError: onError)
            } catch {}
        }
    }

    /// docs/features/ACTIONS.md's error table: `.deepLinkUnresolvable` is
    /// the one case whose ``ActionError/userMessage`` is `nil` by design — a
    /// system beep (`NSSound.beep()`) instead of text, since ⌘↩ with no
    /// usable link is a keyboard miss, not a failure worth interrupting the
    /// timeline for. Every other case is handed to `onError`, which each
    /// call site wires to wherever it shows its inline message —
    /// `NotificationRow`'s `onActionError` callback, or `TimelineView`'s own
    /// `actionError` state.
    static func route(_ error: ActionError, onError: (ActionError) -> Void) {
        if error.userMessage == nil {
            NSSound.beep()
        } else {
            onError(error)
        }
    }
}
