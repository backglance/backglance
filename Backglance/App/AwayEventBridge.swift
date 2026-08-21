import AppKit
import BackglanceCore

/// Turns the OS's away signals into ``AwaySessionTracker/Event`` values.
///
/// The tracker is deliberately AppKit-free so it can be driven from a scripted stream in
/// tests; this is the adapter that makes it useful in the real app. It owns nothing but
/// observer tokens.
///
/// Two sources, both public API except where noted:
///
/// - **Lock and unlock** — `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` on
///   the distributed centre. Technically undocumented names, but stable since macOS 10.x
///   and fired synchronously with the lock state
///   (docs/features/MISSED_DIGEST.md#detection-sources-and-their-reliability).
/// - **Sleep and wake** — `NSWorkspace`, including `screensDidSleep`/`screensDidWake`, so
///   a display that sleeps while the machine stays up still counts as away.
///
/// Focus and presenting arrive from their own detectors, which call ``send(_:)``.
@MainActor
final class AwayEventBridge {
    // MARK: Lifecycle

    init(tracker: AwaySessionTracker) {
        self.tracker = tracker
    }

    deinit {
        // Not `MainActor.assumeIsolated`: a deinit is nonisolated even on an isolated
        // class, so the last release landing off the main thread would turn a tidy
        // teardown into a trap. Removing an observer is thread-safe on both centres, and
        // by the time deinit runs no reference is left to race with — so the tokens are
        // handed to a nonisolated helper and unregistered directly.
        //
        // Without this, a bridge released without `stop()` leaves six observers firing
        // into a tracker nobody holds for the lifetime of the process.
        Self.remove(distributed: distributedObservers, workspace: workspaceObservers)
    }

    // MARK: Internal

    /// Registers the observers. Idempotent: calling it twice replaces the registrations
    /// rather than doubling them, so one lock never produces two events.
    func start() {
        removeObservers()

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), .screenLocked)
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), .screenUnlocked)

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification, .willSleep)
        observe(workspace, NSWorkspace.didWakeNotification, .didWake)
        // Display-only sleep counts as asleep: notifications still arrive, and nobody is
        // looking at them.
        observe(workspace, NSWorkspace.screensDidSleepNotification, .willSleep)
        observe(workspace, NSWorkspace.screensDidWakeNotification, .didWake)

        // A Mac that is already locked when Backglance launches is away, and the lock
        // notification for it fired before there was anything to hear it.
        if Self.screenIsLocked() {
            let tracker = tracker
            Task { await tracker.beginPartial(reason: .locked) }
        }
    }

    func stop() {
        removeObservers()
    }

    /// The seam the Focus and presentation detectors use.
    func send(_ event: AwaySessionTracker.Event) {
        let tracker = tracker
        Task { await tracker.handle(event) }
    }

    // MARK: Private

    private let tracker: AwaySessionTracker

    private var distributedObservers: [any NSObjectProtocol] = []
    private var workspaceObservers: [any NSObjectProtocol] = []

    /// Whether the screen is locked right now.
    ///
    /// `CGSessionCopyCurrentDictionary` is the only read-only way to ask, and the key is
    /// absent rather than `false` on an unlocked session — so a missing key means
    /// unlocked, and an unreadable dictionary means "assume not locked" rather than
    /// opening a session the user never had.
    private static func screenIsLocked() -> Bool {
        guard
            let session = CGSessionCopyCurrentDictionary() as? [String: Any],
            let locked = session["CGSSessionScreenIsLocked"] as? Bool
        else {
            return false
        }
        return locked
    }

    /// Unregisters a set of tokens. `nonisolated` so ``deinit`` can call it.
    nonisolated private static func remove(
        distributed: [any NSObjectProtocol],
        workspace: [any NSObjectProtocol]
    ) {
        let distributedCenter = DistributedNotificationCenter.default()
        for observer in distributed {
            distributedCenter.removeObserver(observer)
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspace {
            workspaceCenter.removeObserver(observer)
        }
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ event: AwaySessionTracker.Event
    ) {
        let tracker = tracker
        workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { await tracker.handle(event) }
        })
    }

    private func observe(
        _ center: DistributedNotificationCenter,
        _ name: Notification.Name,
        _ event: AwaySessionTracker.Event
    ) {
        let tracker = tracker
        distributedObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { await tracker.handle(event) }
        })
    }

    private func removeObservers() {
        Self.remove(distributed: distributedObservers, workspace: workspaceObservers)
        distributedObservers.removeAll()
        workspaceObservers.removeAll()
    }
}
