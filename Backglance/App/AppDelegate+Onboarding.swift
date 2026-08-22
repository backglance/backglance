import AppKit
import BackglanceCapture
import BackglanceUI

// MARK: - AppDelegate + onboarding

extension AppDelegate {
    /// Shows setup on a Mac that has not been through it.
    ///
    /// Only on a Mac that has not: a returning user gets nothing, and someone who skipped
    /// gets nothing either — the banner is the only follow-up, by design
    /// (docs/features/PERMISSIONS_PRIVACY.md#skip-for-now-path). Reopening it deliberately is
    /// Settings ▸ Privacy's job.
    ///
    /// The monitor is built here whether or not setup runs, because the banner and the
    /// Permissions pane need the same answer, and because a grant made months later still has
    /// to be noticed on the next activation.
    func startOnboardingIfNeeded() {
        let monitor = FullDiskAccessMonitor()
        self.monitor = monitor
        // Pushed in rather than observed inside `BackglanceCapture`, which has no business
        // importing AppKit. This one event catches nearly every real grant: the user leaves
        // for System Settings, flips the switch, and comes back.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { monitor.applicationDidBecomeActive() }
        }

        guard !OnboardingModel.isComplete() else {
            return
        }
        let onboarding = OnboardingWindowController(monitor: monitor, engine: engine)
        self.onboarding = onboarding
        onboarding.show()
    }
}
