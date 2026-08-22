import BackglanceUI
import SwiftUI

// MARK: - SettingsView

/// Settings, as far as this milestone has settings.
///
/// Three tabs. General holds Search — semantic indexing is the first thing the app
/// does that needs the user's permission in the plain sense, since it reads every
/// notification they have ever received and writes a vector for each one — and
/// Digest, which owns the app's only permission prompt. Privacy holds everything
/// that decides what Backglance keeps, assembled by `PrivacySettingsView`
/// (docs/features/PRIVACY_CONTROLS.md#ui-components). Permissions reports what
/// macOS has allowed, and is the one place that can reopen setup
/// (docs/features/PERMISSIONS_PRIVACY.md#ui-components).
///
/// The split is the one the docs called for once the Privacy pane existed. General
/// gains its own controls — launch at login, the hotkey, updates — in Phase 4.3.
struct SettingsView: View {
    // MARK: Internal

    @Bindable var search: SearchService

    let digest: DigestSettingsModel

    let privacy: PrivacySettingsModel

    let permissions: PermissionsSettingsModel

    var body: some View {
        TabView {
            general
                .tabItem { Label(String(localized: "General"), systemImage: "gearshape") }
                .accessibilityIdentifier("settings.tab.general")

            PrivacySettingsView(model: privacy)
                .tabItem { Label(String(localized: "Privacy"), systemImage: "hand.raised") }
                .accessibilityIdentifier("settings.tab.privacy")

            PermissionsSettingsView(model: permissions)
                .tabItem { Label(String(localized: "Permissions"), systemImage: "lock.shield") }
                .accessibilityIdentifier("settings.tab.permissions")
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    // MARK: Private

    /// The honest version, not the marketing one: what it does, what it costs,
    /// and what it cannot do (docs/features/SEARCH.md#what-semantic-search-cannot-do).
    private var explanation: String {
        guard search.isSemanticAvailable else {
            return String(localized: """
            The on-device English sentence model isn't available on this Mac. \
            Semantic search is off; full-text search still works.
            """)
        }
        return String(localized: """
        Finds notifications by meaning as well as by wording — "the message about the invoice" \
        rather than the exact words. Everything is computed on this Mac and stored in your archive, \
        about 2 KB per notification. The model is English, so other languages fall back to \
        full-text search.
        """)
    }

    private var general: some View {
        Form {
            Section {
                Toggle(String(localized: "Semantic search"), isOn: $search.semanticEnabled)
                    .disabled(!search.isSemanticAvailable)

                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let progress = search.indexProgress {
                    SemanticIndexProgress(done: progress.done, total: progress.total)
                }

                Button(String(localized: "Delete embeddings")) {
                    search.deleteEmbeddings()
                }
                .disabled(search.indexProgress == nil && !search.semanticEnabled)
            } header: {
                Text(String(localized: "Search"))
            }

            DigestSettingsView(model: digest)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Preview

#Preview {
    Text(verbatim: "Settings")
        .frame(width: 460, height: 200)
}
