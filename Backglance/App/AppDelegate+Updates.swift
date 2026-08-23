import BackglanceUI
import Foundation

// MARK: - AppDelegate + updates

/// Builds the Sparkle owner and hands it to the two surfaces that can reach it.
///
/// Split out of `AppDelegate.swift` along the same seam as `AppDelegate+URLScheme.swift`
/// and `AppDelegate+CaptureStatus.swift`: one concern, kept out of the main file so that
/// one stays inside SwiftLint's length limit as this list grows.
///
/// See docs/deployment/PACKAGING_NOTARIZATION.md#sparkleupdatercontroller-and-the-off-means-off-guarantee.
extension AppDelegate {
    /// Builds the updater and lets it decide, once, whether it may run.
    ///
    /// 🔒 Unconditional construction is safe and deliberate: `SparkleUpdaterController`'s
    /// init creates an *unstarted* `SPUStandardUpdaterController`, which schedules nothing
    /// and opens no connection. Whether it starts is `UpdaterPolicy`'s call, made inside
    /// `start()` — so this does not weaken the "off means off" guarantee, and the pane and
    /// the menu still have an object to talk to in the builds where the answer is no
    /// (docs/security/SECURITY.md#the-updater).
    func startUpdater() {
        let updater = SparkleUpdaterController()
        self.updater = updater
        updater.start()
    }

    /// The Updates pane's model.
    ///
    /// `UpdaterControl()`'s defaults rather than a `nil` model when there is no controller:
    /// the pane then reports an unconfigured build, which is exactly what that state is,
    /// instead of the window losing a tab depending on how it was built.
    func makeUpdatesModel() -> UpdatesSettingsModel {
        UpdatesSettingsModel(updater: updater?.control ?? UpdaterControl())
    }
}
