import Foundation
import Observation

// MARK: - LoginItemStatus

/// Whether Backglance opens at login.
///
/// A mirror of `SMAppService.Status`, reduced to what the pane says: `BackglanceUI` does not
/// import `ServiceManagement`, and the pane only needs to tell "on" from "off" from "macOS
/// wants you to confirm this in System Settings".
public enum LoginItemStatus: Sendable, Equatable {
    case notRegistered
    case registered

    /// Registered, but macOS is waiting for the user to approve it in System Settings ▸
    /// General ▸ Login Items. Its own case because it looks like "on" to the app and like
    /// "off" to the Mac, and only saying so gets the user to the switch.
    case requiresApproval

    /// The status could not be read — running from outside an app bundle, most often, which
    /// is a developer's problem rather than a user's.
    case unavailable
}

// MARK: - PermissionsSettingsModel

/// What Settings ▸ Permissions knows.
///
/// Three permissions with very different shapes. Full Disk Access cannot be requested at all,
/// only detected and pointed at. Notifications can be requested, but only from an explicit
/// action and only once, so this pane deliberately does not offer to — it reports, and the
/// Digest pane owns the one toggle that asks. Login Items can be set outright, and that
/// toggle arrives with `LaunchAtLogin` in Phase 4.3; until then this reports its state so a
/// Mac that is waiting for approval says so rather than looking simply "off".
///
/// Everything is read through injected closures because none of the three APIs is reachable
/// from `BackglanceUI` — TCC through `open(2)`, `UNUserNotificationCenter`, and
/// `SMAppService` all live in the app shell
/// (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction).
///
/// See docs/features/PERMISSIONS_PRIVACY.md#ui-components.
@MainActor
@Observable
public final class PermissionsSettingsModel {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - readFullDiskAccess: probes. Called on every appearance and on "Check again".
    ///   - readBannerAuthorization: asks the notification centre, without requesting.
    ///   - readLoginItemStatus: asks `SMAppService`.
    ///   - actions: what the buttons do.
    public init(
        readFullDiskAccess: @escaping @Sendable () -> FullDiskAccessDisplayState = { .denied },
        readBannerAuthorization: @escaping @Sendable () async -> BannerAuthorization = { .notDetermined },
        readLoginItemStatus: @escaping @Sendable () -> LoginItemStatus = { .unavailable },
        actions: PermissionsActions = PermissionsActions()
    ) {
        self.readFullDiskAccess = readFullDiskAccess
        self.readBannerAuthorization = readBannerAuthorization
        self.readLoginItemStatus = readLoginItemStatus
        self.actions = actions
        fdaState = readFullDiskAccess()
        loginItemStatus = readLoginItemStatus()
    }

    // MARK: Public

    /// The command that makes macOS forget Backglance's Full Disk Access decision.
    ///
    /// Shown rather than run. Backglance will not shell out to `tccutil` on the user's behalf:
    /// an app that resets its own TCC grants is indistinguishable from one probing what else
    /// it can reset, and the whole point of this pane is that the permission is the user's to
    /// give and take.
    public static let tccutilCommand = "tccutil reset SystemPolicyAllFiles app.backglance.Backglance"

    public private(set) var fdaState: FullDiskAccessDisplayState
    public private(set) var bannerAuthorization: BannerAuthorization = .notDetermined
    public private(set) var loginItemStatus: LoginItemStatus

    public let actions: PermissionsActions

    /// Re-reads all three. Called on appearance and after "Check again", because every one of
    /// them can change in System Settings while this window is open.
    public func refresh() async {
        fdaState = readFullDiskAccess()
        loginItemStatus = readLoginItemStatus()
        bannerAuthorization = await readBannerAuthorization()
    }

    // MARK: Private

    private let readFullDiskAccess: @Sendable () -> FullDiskAccessDisplayState
    private let readBannerAuthorization: @Sendable () async -> BannerAuthorization
    private let readLoginItemStatus: @Sendable () -> LoginItemStatus
}

// MARK: - PermissionsActions

/// What the Permissions pane's buttons do.
///
/// Bundled into one value for the reason ``BannerAuthorizing`` gives: these are same-typed
/// closures, and Swift's trailing-closure syntax binds to the last parameter, so passing them
/// separately makes a silent mis-wiring spellable.
public struct PermissionsActions: Sendable {
    // MARK: Lifecycle

    public init(
        openFullDiskAccessSettings: @escaping @Sendable () -> Void = {},
        openNotificationSettings: @escaping @Sendable () -> Void = {},
        openLoginItemsSettings: @escaping @Sendable () -> Void = {},
        showSetupAgain: @escaping @Sendable () -> Void = {},
        copyToPasteboard: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.openFullDiskAccessSettings = openFullDiskAccessSettings
        self.openNotificationSettings = openNotificationSettings
        self.openLoginItemsSettings = openLoginItemsSettings
        self.showSetupAgain = showSetupAgain
        self.copyToPasteboard = copyToPasteboard
    }

    // MARK: Public

    public let openFullDiskAccessSettings: @Sendable () -> Void
    public let openNotificationSettings: @Sendable () -> Void
    public let openLoginItemsSettings: @Sendable () -> Void
    public let showSetupAgain: @Sendable () -> Void
    public let copyToPasteboard: @Sendable (String) -> Void
}
