import Foundation

// MARK: - SystemSettingsLink

/// Builds and tries the per-macOS-version URL ladder that opens an app's own page in
/// System Settings ▸ Notifications — item 9 of the context menu, "Notification
/// Settings for ‹App›…". See
/// docs/features/ACTIONS.md#open-in-system-settings--notifications.
///
/// docs/features/ACTIONS.md sketches this as a `static func open(bundleID:workspace:)`
/// with `workspace: NSWorkspace = .shared` — a free function reaching `NSWorkspace`
/// directly. That sketch predates ``AppLaunching``, the seam ``OpenAction`` already
/// goes through for exactly the same reason it belongs here too: calling
/// `NSWorkspace.shared.open(_:)` for real in a test would actually ask macOS to open
/// System Settings on whatever machine is running the suite. This type holds an
/// injected `workspace: any AppLaunching` instead, constructed the same way
/// `OpenAction(workspace:)` is inside `NotificationActionHandler`, so
/// `SystemSettingsLinkTests` can script `open(_:)` to refuse the first two URLs and
/// accept the third and assert the fallback ladder actually ran, in order, without
/// ever opening a settings pane on the machine running CI.
///
/// A plain `struct`, internal like `OpenAction`, not `public`: nothing outside
/// `BackglanceUI` constructs one directly, only `NotificationActionHandler`.
/// `@MainActor` for the same reason `OpenAction` is — every call this makes into
/// `AppLaunching` is main-thread.
///
/// ⚠️ Everything about *which* URL wins is observed behaviour, not documented API.
/// `?id=<bundle id>` selecting a specific app's row in the Notifications pane is not
/// a public Apple interface — there is no header, no man page, nothing Apple ships
/// that promises it keeps working — and macOS 26 has already been observed to honour
/// it inconsistently, sometimes landing on the pane root instead of the named app.
/// The three-rung ladder in ``notificationSettingsURLs(for:)`` exists precisely
/// because the most specific URL is the least reliable one: try it first since it is
/// the best outcome when it works, but never let its failure be the end of the
/// story. This table needs re-verifying against every new macOS release, the same
/// discipline `docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md` requires of every
/// `StoreAdapter` — it is the same shape of risk, Apple changing something
/// undocumented out from under a fixed assumption.
@MainActor
struct SystemSettingsLink {
    let workspace: any AppLaunching

    /// The three-rung fallback ladder, in the order they must be tried, per the
    /// table in docs/features/ACTIONS.md#open-in-system-settings--notifications:
    /// 1. the Notifications pane with `?id=<percent-encoded bundle id>` — most
    ///    specific, least reliable (see the type's doc comment above);
    /// 2. the same pane with no query — opens Notifications and lets the user find
    ///    the app themselves;
    /// 3. the legacy `com.apple.preference.notifications` id (macOS ≤ 12) — harmless
    ///    to try even on a system that ignores it.
    ///
    /// Percent-encodes `bundleID` with `.urlQueryAllowed`, falling back to the raw
    /// id if encoding somehow fails — a bundle id is already a restricted character
    /// set in practice, so this is defensive, not expected to trigger.
    /// `compactMap`s the `URL(string:)` results rather than force-unwrapping: three
    /// literal, well-formed strings should never fail to parse, but nothing about
    /// this method needs to crash if one somehow did.
    static func notificationSettingsURLs(for bundleID: String) -> [URL] {
        let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        let encoded = bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bundleID
        return [
            URL(string: "\(pane)?id=\(encoded)"),
            URL(string: pane),
            URL(string: "x-apple.systempreferences:com.apple.preference.notifications"),
        ].compactMap { $0 }
    }

    /// Tries each URL from ``notificationSettingsURLs(for:)`` in order, returning the
    /// moment `workspace.open(_:)` accepts one. Unlike ``OpenAction/run(deepLink:bundleID:)``,
    /// a refusal here is never a signal to fall through to a *different kind* of
    /// action — there is no app-activation equivalent for System Settings — so a
    /// `false` from `open(_:)` only ever means "try the next rung", and running out
    /// of rungs is the one and only way this can fail.
    ///
    /// - Throws: ``ActionError/systemSettingsUnavailable`` when all three URLs are
    ///   refused.
    func open(bundleID: String) throws {
        for url in Self.notificationSettingsURLs(for: bundleID) where workspace.open(url) {
            return
        }
        throw ActionError.systemSettingsUnavailable
    }
}
