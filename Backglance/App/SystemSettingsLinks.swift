import AppKit

// MARK: - SystemSettingsLinks

/// The System Settings panes Backglance sends people to.
///
/// > There is no API to *request* Full Disk Access. Unlike Notifications, Camera or
/// > Accessibility, TCC has no prompt for `SystemPolicyAllFiles` — an app can only detect the
/// > state and point at the pane. Every button in Backglance that looks like "Allow" is a
/// > button that opens another app, which is why these URLs matter more than they look.
///
/// Each opener returns whether the URL opened. A `false` is not an error to report: it means
/// this Mac did not recognise the scheme, and the caller shows the manual path — "System
/// Settings ▸ Privacy & Security ▸ Full Disk Access" — instead of a dead button. That is also
/// why the panes are held as strings and parsed on use rather than force-unwrapped at load: a
/// pane that cannot be reached is a case with a designed answer, not a reason to refuse to
/// launch.
///
/// See docs/features/PERMISSIONS_PRIVACY.md#deep-link.
enum SystemSettingsLinks {
    // MARK: Internal

    static let fullDiskAccess = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    static let notifications = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    static let loginItems = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"

    @discardableResult
    static func openFullDiskAccess() -> Bool {
        open(fullDiskAccess)
    }

    @discardableResult
    static func openNotifications() -> Bool {
        open(notifications)
    }

    @discardableResult
    static func openLoginItems() -> Bool {
        open(loginItems)
    }

    // MARK: Private

    private static func open(_ pane: String) -> Bool {
        guard let url = URL(string: pane) else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}
