import BackglanceUI
import Foundation

// MARK: - AppDelegate + General pane wiring

/// Builds the three closure bundles `GeneralSettingsModel` needs to reach `SearchService`,
/// `SMAppService` (via `LaunchAtLogin`) and `HotKeyCenter` — none of which `BackglanceUI` can
/// see (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction).
///
/// Split out of `AppDelegate.swift` along the same seam as `AppDelegate+Interface.swift` and
/// `AppDelegate+Onboarding.swift`: this is one more self-contained job — wiring one pane's
/// closures — that would otherwise just add to `AppDelegate.swift`'s length for no benefit to
/// a reader who is not looking at Settings.
///
/// The members below are `internal`, not `private`, for the reason `AppDelegate.swift`'s own
/// comment gives for `makePermissionsModel()` and `displayState(_:)`: `settingsWindow(...)`,
/// which calls all three, lives in that other file, and `private` does not reach across files
/// even for an extension of the same type.
extension AppDelegate {
    /// The General pane's bridge into `SearchService`. `[weak search]`, not `[weak self]`:
    /// this closure bundle outlives the call that builds it (it is held by
    /// `GeneralSettingsModel` for the life of the settings window), and the thing it must not
    /// keep alive past its own usefulness is the search service, not the delegate.
    static func semanticSearchControl(_ search: SearchService) -> SemanticSearchControl {
        SemanticSearchControl(
            isAvailable: { [weak search] in MainActor.assumeIsolated { search?.isSemanticAvailable ?? false } },
            isEnabled: { [weak search] in MainActor.assumeIsolated { search?.semanticEnabled ?? false } },
            setEnabled: { [weak search] enabled in
                MainActor.assumeIsolated { search?.semanticEnabled = enabled }
            },
            progress: { [weak search] in MainActor.assumeIsolated { search?.indexProgress } },
            deleteEmbeddings: { [weak search] in MainActor.assumeIsolated { search?.deleteEmbeddings() } }
        )
    }

    /// The General pane's bridge into `SMAppService`, via `LaunchAtLogin`. No `self` capture
    /// at all — `LaunchAtLogin` is a stateless wrapper around a system service, not something
    /// this delegate owns the lifetime of.
    static func launchAtLoginControl() -> LaunchAtLoginControl {
        LaunchAtLoginControl(
            readStatus: { LaunchAtLogin.status },
            setEnabled: { LaunchAtLogin.setEnabled($0) }
        )
    }

    /// The General pane's bridge into `HotKeyCenter`. `[weak self]`, the same as
    /// `makePermissionsModel()`'s closures: `hotKeys` is built after this method's caller
    /// returns (`startInterface()` calls `settingsWindow(...)` before it builds
    /// `HotKeyCenter`), so this has to read `self?.hotKeys` lazily, at the moment Settings is
    /// actually shown, rather than capture a reference that does not exist yet.
    func hotKeyControl() -> HotKeyControl {
        HotKeyControl(
            isRegistered: { [weak self] in MainActor.assumeIsolated { self?.hotKeys?.isRegistered ?? false } },
            retry: { [weak self] in
                MainActor.assumeIsolated {
                    self?.hotKeys?.register()
                    return self?.hotKeys?.isRegistered ?? false
                }
            }
        )
    }
}
