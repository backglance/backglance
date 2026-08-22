import AppKit
import Foundation

// MARK: - AppLaunching

/// The three `NSWorkspace` operations ``OpenAction`` needs, behind a seam.
///
/// `NSWorkspace` cannot be exercised in CI: calling `open(_:)` or
/// `openApplication(at:configuration:)` for real would actually open a URL or
/// launch an application on whatever machine is running the test suite. Every
/// other action in this coordinator reads through `Archive`, which already has
/// an in-memory seam (`Archive(inMemory: true)`); `OpenAction` has no such
/// thing to reach for, so it gets one here, the same way ``TriageEvaluating``
/// stands in for `RulesEngine` until that engine exists at all. A fake
/// conformance in `Tests/BackglanceUITests` records what it was asked to do
/// and returns scripted results, so `OpenActionTests` can assert the
/// click-time ordering in docs/features/ACTIONS.md#open-openaction-and-deeplinkresolver
/// without ever touching AppKit.
///
/// `@MainActor` because every `NSWorkspace` call this wraps is a main-thread
/// API, matching ``NotificationActionHandler`` itself.
@MainActor
public protocol AppLaunching {
    /// Mirrors `NSWorkspace.shared.open(_:) -> Bool`: hands `url` to whatever
    /// app has registered its scheme and reports whether one accepted it.
    /// `false` means "nothing opened it any more" — a deep-link handler that
    /// uninstalled or a scheme nobody claims — which is a dead link, not a
    /// system failure. ``OpenAction`` falls through to app activation on
    /// `false` and never throws for it; see
    /// docs/features/ACTIONS.md#edge-cases-and-error-handling.
    func open(_ url: URL) -> Bool

    /// Mirrors `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`.
    /// `nil` means the app is not installed on this Mac — the only signal
    /// ``OpenAction`` has for `ActionError.appNotInstalled`.
    func applicationURL(forBundleID bundleID: String) -> URL?

    /// Mirrors `NSWorkspace.shared.openApplication(at:configuration:)`,
    /// activating the app at `url` (`OpenConfiguration.activates = true`).
    ///
    /// `async throws`, matching the real API, rather than a synchronous
    /// `Bool`: `openApplication` launches out-of-process through `launchd`
    /// and only resolves once that round-trip completes, so there is no
    /// synchronous "did it launch" this seam could report instead. Modelling
    /// it as fire-and-forget would also hide the one case
    /// docs/features/ACTIONS.md calls out separately from "not installed" —
    /// an installed app whose launch itself fails
    /// (`ActionError.launchFailed`) — behind a `Bool` that cannot carry a
    /// reason.
    func launchApplication(at url: URL) async throws
}

// MARK: - NSWorkspaceAppLauncher

/// The real conformance: every call forwards straight to `NSWorkspace.shared`.
/// This is what `NotificationActionHandler`'s default initializer wires in;
/// only tests ever construct a different ``AppLaunching``.
public struct NSWorkspaceAppLauncher: AppLaunching {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    public func applicationURL(forBundleID bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    public func launchApplication(at url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
