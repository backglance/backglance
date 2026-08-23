import BackglanceUI
import Foundation
import ServiceManagement

// MARK: - LaunchAtLogin

/// Wraps `SMAppService.mainApp`: the modern launch-at-login API, tied to *this app's own
/// bundle* — which is exactly why it lives in the app target rather than a package.
/// `BackglanceUI` needs the answer, but asking `ServiceManagement` for it is app-shell
/// plumbing in the same sense the status item and the Carbon hotkey are
/// (docs/getting-started/DEVELOPMENT_GUIDE.md#project-structure: "the status item, the
/// popover, the Carbon hotkey, launch-at-login, the URL scheme handler, and the Sparkle
/// controller" all have to stay here).
///
/// `SMAppService.register()`/`.unregister()` both `throws`, and `.status` is not a plain
/// on/off: `.requiresApproval` means the call succeeded but macOS is holding the switch
/// until the user flips it in System Settings ▸ General ▸ Login Items
/// (docs/operations/TROUBLESHOOTING.md#launch-at-login-not-working). Every entry point here
/// answers with ``LoginItemStatus`` — `BackglanceUI`'s reduction of `SMAppService.Status` —
/// so General's toggle and Permissions' read-only row agree on the same three words, and a
/// thrown error becomes a ``LaunchAtLoginOutcome/failure(_:)`` message rather than a crash
/// or a switch that silently stays where it was.
///
/// See docs/features/PERMISSIONS_PRIVACY.md#launch-at-login.
enum LaunchAtLogin {
    // MARK: Internal

    /// The current registration state, translated for the pane. Safe to read as often as
    /// Settings likes — `SMAppService` does not round-trip to a daemon for this, it reads
    /// its own cached record.
    static var status: LoginItemStatus {
        status(for: SMAppService.mainApp.status)
    }

    /// Registers or unregisters, and reports what actually happened.
    ///
    /// One entry point rather than two, because `GeneralSettingsModel`'s toggle has exactly
    /// one write it needs to make and no reason to pick between two method names to make it.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> LaunchAtLoginOutcome {
        enabled ? register() : unregister()
    }

    /// The pure part of this file: `SMAppService.Status` reduced to what a pane says, with
    /// nothing else going on — no I/O, no `self`, no side effect. It stays a free function
    /// rather than folding into ``status`` so the mapping itself is at least *readable* in
    /// isolation, even though there is nowhere in this target to prove that automatically:
    /// `Backglance/App/` has no unit test bundle (`Tests/BackglanceAppUITests` is XCUITest
    /// only, driving the built app rather than importing its types), so this switch is
    /// exercised only by hand and by `PermissionsSettingsModelTests`/
    /// `GeneralSettingsModelTests` exercising the ``LoginItemStatus`` values it produces,
    /// one level up. Moving it into `BackglanceUI` — where it *could* be unit-tested — was
    /// considered and rejected: `LoginItemStatus` lives there already, but
    /// `SMAppService.Status` does not, and taking this `switch` across the boundary would
    /// mean importing `ServiceManagement` into a package that otherwise never touches an OS
    /// permission API directly (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction).
    static func status(for smStatus: SMAppService.Status) -> LoginItemStatus {
        switch smStatus {
        case .enabled: .registered
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    // MARK: Private

    private static func register() -> LaunchAtLoginOutcome {
        do {
            try SMAppService.mainApp.register()
            return .success(status)
        } catch {
            return .failure(message(for: error))
        }
    }

    private static func unregister() -> LaunchAtLoginOutcome {
        do {
            try SMAppService.mainApp.unregister()
            return .success(status)
        } catch {
            return .failure(message(for: error))
        }
    }

    /// `error.localizedDescription`, not a bundle id or a path: the two things worth
    /// telling the user are "it didn't work" and, where macOS supplies one, why — nothing
    /// here is notification content, so this is one of the few app-shell error paths this
    /// project is not obliged to keep off the pane.
    private static func message(for error: Error) -> String {
        String(
            localized: "Backglance couldn’t change this: \(error.localizedDescription)",
            comment: "Error under the launch-at-login toggle; the placeholder is a system error message"
        )
    }
}
