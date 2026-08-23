import AppKit
import BackglanceCore
import BackglanceUI
import Foundation
import Sparkle

// MARK: - SparkleUpdaterController

/// Owns the Sparkle updater, and therefore every network request Backglance ever makes.
///
/// 🔒 The guarantee is docs/security/SECURITY.md#the-updater: updates are the only thing
/// this app fetches, and turning them off makes that zero. What keeps that true here is
/// that `SPUStandardUpdaterController` is constructed with `startingUpdater: false` — an
/// unstarted Sparkle schedules nothing and opens nothing — and that ``start()`` is the only
/// place that changes, gated by ``UpdaterPolicy``.
///
/// The decision itself deliberately lives in `BackglanceCore` rather than in this file: no
/// test bundle in this project has a `TEST_HOST`, so nothing can `@testable import Backglance`
/// (BACKGLANCE-238), and "no request is made when the toggle is off" is exactly the kind of
/// claim that has to be provable. This class is the part that genuinely cannot move — it is
/// the only thing in the repository that can see the Sparkle framework at all.
///
/// See docs/deployment/PACKAGING_NOTARIZATION.md#sparkleupdatercontroller-and-the-off-means-off-guarantee.
@MainActor
final class SparkleUpdaterController {
    // MARK: Lifecycle

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [UpdaterPolicy.automaticChecksDefaultsKey: true])
        // startingUpdater: false — nothing is scheduled and nothing touches the network
        // until start() decides it may, based on the setting.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    // MARK: Internal

    /// Whether this build carries a key Sparkle could verify a download with. False in
    /// every Debug build, because only `Config/Release.xcconfig` defines `SU_PUBLIC_ED_KEY`.
    var isConfigured: Bool {
        UpdaterPolicy.hasUsablePublicKey(publicEDKey)
    }

    /// Sparkle's own answer, which is false while a check is already running. Reported as
    /// `false` before the updater has started, since there is nothing to check with yet.
    var canCheckForUpdates: Bool {
        started && controller.updater.canCheckForUpdates
    }

    var automaticChecksEnabled: Bool {
        defaults.bool(forKey: UpdaterPolicy.automaticChecksDefaultsKey)
    }

    /// The Updates pane's bridge into this object. Every closure hops to the main actor by
    /// being `@MainActor`-isolated already: `UpdaterControl` is called from
    /// `UpdatesSettingsModel`, which is `@MainActor` too.
    var control: UpdaterControl {
        UpdaterControl(
            isConfigured: { MainActor.assumeIsolated { self.isConfigured } },
            readAutomaticChecks: { MainActor.assumeIsolated { self.automaticChecksEnabled } },
            setAutomaticChecks: { enabled in
                MainActor.assumeIsolated { self.setAutomaticChecks(enabled) }
            },
            canCheckForUpdates: { MainActor.assumeIsolated { self.canCheckForUpdates } },
            checkForUpdates: { MainActor.assumeIsolated { self.checkForUpdates() } }
        )
    }

    /// Called once, from `applicationDidFinishLaunching`.
    func start() {
        let decision = decision(for: .launch)
        guard decision == .start else {
            log(decision)
            return
        }
        startUpdaterIfNeeded()
    }

    /// Backglance ▸ Check for Updates… — user-initiated, so it works even when automatic
    /// checks are off. It still cannot run in a build with no public key: there would be
    /// nothing to verify the download against.
    func checkForUpdates() {
        let decision = decision(for: .userInitiated)
        guard decision == .start else {
            log(decision)
            return
        }
        startUpdaterIfNeeded()
        guard started else {
            return
        }
        controller.checkForUpdates(nil)
    }

    // MARK: Private

    private let controller: SPUStandardUpdaterController
    private let defaults: UserDefaults
    private var started = false

    private var publicEDKey: String? {
        Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
    }

    private func decision(for trigger: UpdaterTrigger) -> UpdaterStartDecision {
        UpdaterPolicy.decision(
            trigger: trigger,
            disableEnvironmentValue: ProcessInfo.processInfo
                .environment[UpdaterPolicy.disableEnvironmentKey],
            publicEDKey: publicEDKey,
            automaticChecksEnabled: automaticChecksEnabled
        )
    }

    private func startUpdaterIfNeeded() {
        guard !started else {
            return
        }
        let updater = controller.updater
        // Set before start(), so the first scheduled check already obeys them — and so
        // Sparkle never shows its own "check automatically?" prompt, which would ask the
        // user a question Settings ▸ Updates has already answered.
        updater.automaticallyChecksForUpdates = automaticChecksEnabled
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false
        updater.updateCheckInterval = UpdaterPolicy.checkInterval
        do {
            try updater.start()
            started = true
            Log.updater.notice("updater started; automatic=\(automaticChecksEnabled)")
        } catch {
            // Typical causes: SUFeedURL missing or not https, SUPublicEDKey malformed.
            Log.updater.error("updater failed to start: \(error.localizedDescription)")
        }
    }

    private func setAutomaticChecks(_ enabled: Bool) {
        defaults.set(enabled, forKey: UpdaterPolicy.automaticChecksDefaultsKey)
        if enabled {
            startUpdaterIfNeeded()
        }
        // The other half of "off means off": Sparkle cancels its scheduled check the moment
        // this becomes false, so an app already running stops reaching the network without
        // needing a relaunch. When the updater was never started there is nothing to tell.
        if started {
            controller.updater.automaticallyChecksForUpdates = enabled
        }
        Log.updater.notice("automatic update checks \(enabled ? "enabled" : "disabled")")
    }

    /// Why the updater did not start. The reason is the whole point of the line — it is what
    /// a user or an auditor checks against `nettop` showing no connections.
    private func log(_ decision: UpdaterStartDecision) {
        switch decision {
        case .start:
            break

        case .disabledByEnvironment:
            Log.updater.notice("updater disabled by \(UpdaterPolicy.disableEnvironmentKey)")

        case .noPublicKey:
            Log.updater.notice("no SUPublicEDKey — updater not started")

        case .automaticChecksOff:
            Log.updater.notice("automatic update checks are off — updater not started")
        }
    }
}
