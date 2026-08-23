import BackglanceCore
import Foundation
import Observation

// MARK: - UpdaterControl

/// What the Updates pane can ask the app shell's `SparkleUpdaterController` about, and the
/// two things it can ask it to do.
///
/// A closure bundle rather than the controller itself, for the reason ``LaunchAtLoginControl``
/// and ``SemanticSearchControl`` already give: `BackglanceUI` must never import Sparkle
/// (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction), and Sparkle is linked
/// into the app target alone. It is also what lets a test drive this pane without a
/// framework that would open a connection if it were started.
public struct UpdaterControl: Sendable {
    // MARK: Lifecycle

    public init(
        isConfigured: @escaping @Sendable () -> Bool = { false },
        readAutomaticChecks: @escaping @Sendable () -> Bool = { true },
        setAutomaticChecks: @escaping @Sendable (Bool) -> Void = { _ in },
        canCheckForUpdates: @escaping @Sendable () -> Bool = { false },
        checkForUpdates: @escaping @Sendable () -> Void = {}
    ) {
        self.isConfigured = isConfigured
        self.readAutomaticChecks = readAutomaticChecks
        self.setAutomaticChecks = setAutomaticChecks
        self.canCheckForUpdates = canCheckForUpdates
        self.checkForUpdates = checkForUpdates
    }

    // MARK: Public

    /// Whether this build carries a usable `SUPublicEDKey` — ``UpdaterPolicy/hasUsablePublicKey(_:)``
    /// asked of the running bundle. `false` in every Debug build on purpose, and the pane
    /// says so rather than offering a toggle that could not do anything.
    public let isConfigured: @Sendable () -> Bool

    /// ``UpdaterPolicy/automaticChecksDefaultsKey``, read fresh. Nothing outside this pane
    /// and the controller writes it, so a read on appearance is enough.
    public let readAutomaticChecks: @Sendable () -> Bool

    /// Persists the preference *and* applies it: turning it off cancels Sparkle's scheduled
    /// check immediately, which is the half of "off means off" that matters while the app
    /// is already running.
    public let setAutomaticChecks: @Sendable (Bool) -> Void

    /// Sparkle's `canCheckForUpdates`, which is false while a check is already in flight.
    public let canCheckForUpdates: @Sendable () -> Bool

    /// Backglance ▸ Check for Updates… — one deliberate request, allowed even when
    /// automatic checks are off (``UpdaterTrigger/userInitiated``).
    public let checkForUpdates: @Sendable () -> Void
}

// MARK: - UpdatesSettingsModel

/// Settings ▸ Updates: the one switch that decides whether Backglance ever touches the
/// network, and the button that overrides it for exactly one request.
///
/// 🔒 The pane's copy is a promise the rest of the app has to keep — with the toggle off,
/// there is no telemetry, no crash reporting and no update check, so the process opens no
/// connections at all (docs/security/SECURITY.md#the-updater). The decision itself is
/// ``UpdaterPolicy``'s, in `BackglanceCore`, where it can be unit-tested; this model only
/// reflects it and relays the user's two choices.
///
/// See docs/deployment/PACKAGING_NOTARIZATION.md#sparkleupdatercontroller-and-the-off-means-off-guarantee.
@MainActor
@Observable
public final class UpdatesSettingsModel {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - updater: the app shell's Sparkle bridge. The default leaves the pane inert, for
    ///     previews and for tests that only care that it renders.
    ///   - version: what to show as the running version. Defaults to the main bundle's
    ///     `CFBundleShortVersionString`, which is the string Sparkle compares against the
    ///     appcast.
    public init(updater: UpdaterControl = UpdaterControl(), version: String? = nil) {
        self.updater = updater
        self.version = version ?? Self.bundleVersion()
        isConfigured = updater.isConfigured()
        canCheckForUpdates = updater.canCheckForUpdates()
        isSyncing = true
        automaticChecksEnabled = updater.readAutomaticChecks()
        isSyncing = false
    }

    // MARK: Public

    /// The running version, for the "Backglance 1.0.0" line above the toggle.
    public let version: String

    /// Whether this build could check for updates at all. A Debug build carries no public
    /// key, so the pane explains that instead of pretending the toggle does something.
    public private(set) var isConfigured: Bool

    public private(set) var canCheckForUpdates: Bool

    /// Whether Backglance looks for updates once a day.
    ///
    /// Writes through immediately — this is not a preference that waits for an "Apply"
    /// step, because the whole point of turning it off is that the next scheduled check
    /// does not happen.
    public var automaticChecksEnabled: Bool {
        didSet {
            guard automaticChecksEnabled != oldValue, !isSyncing else {
                return
            }
            updater.setAutomaticChecks(automaticChecksEnabled)
            canCheckForUpdates = updater.canCheckForUpdates()
        }
    }

    /// Re-reads what can change while Settings sits open: a check started from the
    /// status-item menu flips `canCheckForUpdates` for as long as it runs.
    public func refresh() {
        isConfigured = updater.isConfigured()
        canCheckForUpdates = updater.canCheckForUpdates()
        isSyncing = true
        automaticChecksEnabled = updater.readAutomaticChecks()
        isSyncing = false
    }

    /// The user asked, so the request is made even when ``automaticChecksEnabled`` is off.
    public func checkForUpdates() {
        updater.checkForUpdates()
        canCheckForUpdates = updater.canCheckForUpdates()
    }

    // MARK: Private

    private let updater: UpdaterControl

    /// Guards ``automaticChecksEnabled``'s `didSet` while the model assigns it from a read,
    /// so refreshing does not write the value straight back through the control.
    private var isSyncing = false

    private static func bundleVersion() -> String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? String(localized: "unknown", comment: "Fallback shown when the app version can’t be read")
    }
}
