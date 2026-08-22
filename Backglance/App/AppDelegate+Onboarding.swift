import AppKit
import BackglanceCapture
import BackglanceUI
import ServiceManagement
import UserNotifications

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

    /// Reopens setup, from wherever it makes sense to resume.
    ///
    /// Behind the banner's "Learn why" and, later, Settings ▸ Permissions ▸ "Show setup
    /// again". `OnboardingModel.startingStep` picks the screen: someone whose banner is still
    /// there gets the one that explains the permission, not the welcome they have already
    /// read. The window is rebuilt each time so that step is recomputed rather than frozen at
    /// whatever it was the first time.
    func showOnboarding() {
        guard let monitor else {
            return
        }
        let onboarding = OnboardingWindowController(monitor: monitor, engine: engine)
        self.onboarding = onboarding
        onboarding.show()
    }

    /// The Permissions pane's model.
    ///
    /// All three readers live here because none of the three APIs is reachable from
    /// `BackglanceUI`: TCC through `open(2)`, `UNUserNotificationCenter`, and `SMAppService`.
    /// None of them *requests* anything — the pane reports, and the one place that asks for
    /// notification authorization is the Digest pane's banner toggle.
    func makePermissionsModel() -> PermissionsSettingsModel {
        PermissionsSettingsModel(
            readFullDiskAccess: { [weak self] in
                MainActor.assumeIsolated {
                    Self.displayState(self?.monitor?.checkNow() ?? .denied)
                }
            },
            readBannerAuthorization: { await Self.bannerAuthorization() },
            readLoginItemStatus: { MainActor.assumeIsolated { Self.loginItemStatus() } },
            actions: PermissionsActions(
                openFullDiskAccessSettings: { SystemSettingsLinks.openFullDiskAccess() },
                openNotificationSettings: { SystemSettingsLinks.openNotifications() },
                openLoginItemsSettings: { SystemSettingsLinks.openLoginItems() },
                showSetupAgain: { [weak self] in
                    MainActor.assumeIsolated { self?.showOnboarding() }
                },
                copyToPasteboard: { text in
                    MainActor.assumeIsolated {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            )
        )
    }

    static func displayState(_ state: FullDiskAccessState) -> FullDiskAccessDisplayState {
        switch state {
        case .granted: .granted
        case .denied: .denied
        case .storeMissing: .storeMissing
        }
    }

    /// What the notification centre would do with a banner, without asking for anything.
    private static func bannerAuthorization() async -> BannerAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized,
             .provisional,
             .ephemeral:
            .authorized

        case .denied:
            .denied

        case .notDetermined:
            .notDetermined

        @unknown default:
            // A status this build does not know about is not a reason to claim permission.
            .denied
        }
    }

    /// Read only. Registering is `LaunchAtLogin`'s, which arrives with its toggle in Phase 4.3;
    /// reporting the state now is what stops a Mac that is waiting for approval looking simply
    /// "off".
    private static func loginItemStatus() -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .registered
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }
}
