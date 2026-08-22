import Foundation

// MARK: - UndoClock

/// Time, as the undo toast's 5-second expiry sees it.
///
/// The same reasoning as `BackglanceCore`'s `AwayClock`, applied to a different timer:
/// a test that actually waited out five real seconds per case would make
/// ``NotificationActionHandlerTests`` (and every future test that touches delete)
/// slow, and the one thing the expiry path most needs proving —
/// that it clears ``NotificationActionHandler/pendingUndo`` *without* calling
/// `Archive.restore` — cannot be shown at all without a way to make five seconds pass
/// on command. Not `AwayClock` itself, reused: that protocol's own doc comment scopes
/// it to `AwaySessionTracker`'s merge gap, and the two timers have nothing to do with
/// each other beyond happening to share a shape — see ``AwaySessionTrackerTests``'
/// `ScriptedAwayClock` for the sibling technique this mirrors in `BackglanceCoreTests`.
///
/// A duration, not a deadline, unlike `AwayClock.sleep(until:)`: the undo window is
/// always "5 seconds from whenever this delete happened", restarted from zero on every
/// call to ``NotificationActionHandler/delete(ids:)``, so there is no absolute instant
/// worth computing ahead of time the way the away-session merge gap has one.
///
/// See docs/features/ACTIONS.md#delete-and-undo.
public protocol UndoClock: Sendable {
    /// Suspends for `seconds`, or returns early if the surrounding task is cancelled —
    /// which is exactly what a second, replacing delete does to the first delete's
    /// timer.
    func sleep(seconds: TimeInterval) async throws
}

// MARK: - SystemUndoClock

/// The production clock: `Task.sleep`, which already resolves early on cancellation by
/// throwing `CancellationError` — `NotificationActionHandler.delete(ids:)` swallows
/// that with `try?` and checks `Task.isCancelled` itself, the same pattern
/// `TimelineStore.rowBecameVisible(_:)` uses for its own one-second timer.
public struct SystemUndoClock: UndoClock {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}
