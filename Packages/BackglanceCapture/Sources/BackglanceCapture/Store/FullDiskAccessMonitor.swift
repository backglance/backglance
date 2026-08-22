import Foundation
import Observation

// MARK: - FullDiskAccessMonitor

/// When to ask ``FullDiskAccessProbe``, and what to do with the answer.
///
/// The cadence is the design. Granting Full Disk Access happens in another app, and the user
/// comes back expecting Backglance to have noticed — so the probe runs when the app becomes
/// active again, and that one event covers the overwhelming majority of grants. A timer is
/// the fallback for the case that event misses: someone reading the onboarding screen on a
/// second display while System Settings has focus on the first, who never "returns" to
/// anything. That timer runs *only* while an onboarding screen is visible, because outside
/// that window a poll would be waking the app every thirty seconds forever to ask a question
/// nobody is waiting on.
///
/// Callers push events in rather than this observing them: `NSApplication` notifications are
/// AppKit, and `BackglanceCapture` has no business importing it
/// (docs/architecture/ARCHITECTURE.md#dependency-graph). The app shell owns the wiring, the
/// same way it does for away-session events.
///
/// See docs/features/PERMISSIONS_PRIVACY.md#runtime-detection-fulldiskaccessprobe.
@MainActor
@Observable
public final class FullDiskAccessMonitor {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - probe: what actually asks. Injected so a test can decide the answers.
    ///   - pollInterval: how often to re-probe while onboarding is on screen.
    public init(
        probe: FullDiskAccessProbe = FullDiskAccessProbe(),
        pollInterval: Duration = .seconds(30)
    ) {
        self.probe = probe
        self.pollInterval = pollInterval
        state = probe.probe()
    }

    // MARK: Public

    /// The last answer. Read by the banner, the onboarding state machine and the Permissions
    /// pane; written only by ``checkNow()``.
    public private(set) var state: FullDiskAccessState

    /// How many times the probe has run, so a test can tell a poll from a no-op.
    public private(set) var probeCount = 0

    /// Called whenever the answer changes — never on a probe that confirms what was already
    /// true. The app shell uses it to start capture, or to degrade it.
    public var onChange: ((FullDiskAccessState) -> Void)?

    /// Whether the fallback timer is running.
    public private(set) var isPolling = false

    /// Probes now. The one entry point: "Check again", app activation and each poll tick all
    /// arrive here, so there is a single place where the answer is decided.
    @discardableResult
    public func checkNow() -> FullDiskAccessState {
        let result = probe.probe()
        probeCount += 1
        guard result != state else {
            return result
        }
        state = result
        onChange?(result)
        return result
    }

    /// The user came back from System Settings — or from anywhere. The event that catches
    /// nearly every real grant.
    public func applicationDidBecomeActive() {
        checkNow()
    }

    /// Starts the fallback poll. Idempotent: a second onboarding screen appearing does not
    /// start a second timer.
    public func startPolling() {
        guard !isPolling else {
            return
        }
        isPolling = true
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled else {
                    return
                }
                self?.checkNow()
            }
        }
    }

    /// Stops it. Called when onboarding closes, and it must be — a timer nobody is waiting on
    /// is the difference between a menu bar app that sleeps and one that does not.
    ///
    /// There is no `deinit` doing this for you: the task holds only a weak reference, so a
    /// monitor that goes away leaves a timer that wakes, finds nothing, and does nothing —
    /// wasteful rather than wrong, and the alternative is touching main-actor state from a
    /// nonisolated deinit.
    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    // MARK: Private

    private let probe: FullDiskAccessProbe
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?
}
