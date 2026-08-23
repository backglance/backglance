import BackglanceUI
import SwiftUI

// MARK: - SettingsView

/// Settings, as far as this milestone has settings.
///
/// Seven tabs. General holds launch at login, the ⌃⌥N hotkey note, Search — semantic indexing
/// is the first thing the app does that needs the user's permission in the plain sense, since
/// it reads every notification they have ever received and writes a vector for each one — and
/// Digest, which owns the app's only permission prompt, assembled by `GeneralSettingsView`
/// (BACKGLANCE-213, BACKGLANCE-215). Apps is the one place a user picks a single app and sees
/// every per-app setting it carries together, assembled by `AppsSettingsView`
/// (docs/features/PRIVACY_CONTROLS.md#ui-components). Privacy holds everything that decides
/// what Backglance keeps across *every* app at once, assembled by `PrivacySettingsView`
/// (docs/features/PRIVACY_CONTROLS.md#ui-components). Rules holds the highlight, VIP, mute
/// and (v1.x) regex rules that triage the timeline, assembled by `RulesSettingsView`
/// (docs/features/RULES.md#ui-components, BACKGLANCE-209). Updates holds the one switch that
/// decides whether this app ever touches the network, assembled by `UpdatesSettingsView`
/// (docs/security/SECURITY.md#the-updater, BACKGLANCE-214). Permissions reports what macOS
/// has allowed, and is the one place that can reopen setup
/// (docs/features/PERMISSIONS_PRIVACY.md#ui-components). Status answers the one question
/// capture cannot answer for itself — is it working — because capture fails silently and the
/// timeline simply stops growing (docs/operations/MONITORING_LOGGING.md#health-indicators-in-the-ui).
struct SettingsView: View {
    let general: GeneralSettingsModel

    let apps: AppsSettingsModel

    let privacy: PrivacySettingsModel

    let rules: RulesSettingsModel

    let updates: UpdatesSettingsModel

    let permissions: PermissionsSettingsModel

    let status: StatusSettingsModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: general)
                .tabItem { Label(String(localized: "General"), systemImage: "gearshape") }
                .accessibilityIdentifier("settings.tab.general")

            AppsSettingsView(model: apps)
                .tabItem { Label(String(localized: "Apps"), systemImage: "square.grid.2x2") }
                .accessibilityIdentifier("settings.tab.apps")

            PrivacySettingsView(model: privacy)
                .tabItem { Label(String(localized: "Privacy"), systemImage: "hand.raised") }
                .accessibilityIdentifier("settings.tab.privacy")

            RulesSettingsView(model: rules)
                .tabItem { Label(String(localized: "Rules"), systemImage: "wand.and.stars") }
                .accessibilityIdentifier("settings.tab.rules")

            UpdatesSettingsView(model: updates)
                .tabItem { Label(String(localized: "Updates"), systemImage: "arrow.down.circle") }
                .accessibilityIdentifier("settings.tab.updates")

            PermissionsSettingsView(model: permissions)
                .tabItem { Label(String(localized: "Permissions"), systemImage: "lock.shield") }
                .accessibilityIdentifier("settings.tab.permissions")

            StatusSettingsView(model: status)
                .tabItem { Label(String(localized: "Status"), systemImage: "waveform.path.ecg") }
                .accessibilityIdentifier("settings.tab.status")
        }
        // 860 is where macOS 26 stops collapsing these seven tabs into the toolbar's
        // overflow menu with the Apps pane selected, measured in BACKGLANCE-249 — its sidebar
        // toggle shares the toolbar with them. The window opens wider still
        // (``SettingsWindowController/contentWidth``); this is the floor that keeps a preview,
        // or any other host, from drawing a settings window with no visible tabs.
        .frame(minWidth: 860, minHeight: 420)
    }
}

// MARK: - Preview

#Preview {
    Text(verbatim: "Settings")
        .frame(width: 460, height: 200)
}
