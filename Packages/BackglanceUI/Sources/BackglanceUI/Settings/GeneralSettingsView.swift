import SwiftUI

// MARK: - GeneralSettingsView

/// Settings ▸ General: how Backglance starts, how it is opened, and how it searches.
///
/// Three subjects that share nothing in common except that they are the first things
/// someone tunes about an app that otherwise lives quietly in the menu bar: whether it opens
/// itself, the shortcut that summons it, and whether it understands what a notification
/// *means* rather than only what it says. Privacy holds every control that decides what gets
/// kept; Rules holds every control that decides how a kept notification is triaged; General
/// is what is left, plus the digest it composes rather than reimplements.
///
/// See docs/features/PERMISSIONS_PRIVACY.md#launch-at-login, docs/features/SEARCH.md,
/// docs/features/MISSED_DIGEST.md#settings.
public struct GeneralSettingsView: View {
    // MARK: Lifecycle

    public init(model: GeneralSettingsModel) {
        self.model = model
    }

    // MARK: Public

    public var body: some View {
        Form {
            startupSection
            searchSection
            DigestSettingsView(model: model.digest)
        }
        .formStyle(.grouped)
        .task { model.refresh() }
        .task { await pollIndexProgress() }
    }

    // MARK: Private

    @Bindable private var model: GeneralSettingsModel

    /// The honest version, not the marketing one: what it does, what it costs, and what it
    /// cannot do (docs/features/SEARCH.md#what-semantic-search-cannot-do).
    private var searchExplanation: String {
        guard model.isSemanticAvailable else {
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

    /// Only shown for the one status that is not self-explanatory. `.registered` and
    /// `.notRegistered` already match what the toggle itself shows; `.unavailable` is rare
    /// enough (a build run outside a proper app bundle) that ``model/launchAtLoginFailure``,
    /// set the moment a real toggle press hits it, says more than a permanent note would.
    private var loginItemStatusText: String? {
        guard model.loginItemStatus == .requiresApproval else {
            return nil
        }
        return String(localized: "Waiting for approval in System Settings ▸ General ▸ Login Items.")
    }

    private var hotKeyStatusText: String {
        model.isHotKeyRegistered
            ? String(localized: "⌃⌥N opens Backglance from anywhere.")
            : String(localized: "⌃⌥N is unavailable — another app may already be using it.")
    }

    private var startupSection: some View {
        Section {
            Toggle(String(localized: "Open Backglance at login"), isOn: $model.launchAtLoginEnabled)
                .accessibilityIdentifier("general.launchAtLogin")

            if let loginItemStatusText {
                Label(loginItemStatusText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("general.launchAtLogin.status")
            }

            if let failure = model.launchAtLoginFailure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("general.launchAtLogin.failure")
            }

            LabeledContent(String(localized: "Global shortcut")) {
                Text(hotKeyStatusText)
                    .font(.caption)
                    .foregroundStyle(model.isHotKeyRegistered ? .secondary : .primary)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityIdentifier("general.hotKey.status")

            if !model.isHotKeyRegistered {
                Button(String(localized: "Try Again")) {
                    model.retryHotKeyRegistration()
                }
                .accessibilityIdentifier("general.hotKey.retry")
            }
        } header: {
            Text(String(localized: "Startup"))
        } footer: {
            Text(String(localized: """
            Backglance only archives notifications while it is running, so anything delivered \
            before you open it is gone by the time it starts. ⌃⌥N opens it from wherever you are.
            """))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var searchSection: some View {
        Section {
            Toggle(String(localized: "Semantic search"), isOn: $model.semanticEnabled)
                .disabled(!model.isSemanticAvailable)
                .accessibilityIdentifier("general.search.semantic")

            Text(searchExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let progress = model.indexProgress {
                SemanticIndexProgress(done: progress.done, total: progress.total)
            }

            Button(String(localized: "Delete embeddings")) {
                model.deleteEmbeddings()
            }
            .disabled(model.indexProgress == nil && !model.semanticEnabled)
            .accessibilityIdentifier("general.search.deleteEmbeddings")
        } header: {
            Text(String(localized: "Search"))
        }
    }

    /// Polls the indexer's progress while General is open, rather than binding to
    /// `SearchService` directly the way this pane's inline predecessor in `SettingsView.swift`
    /// did — `BackglanceUI` cannot see that type at all
    /// (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction), so a redraw during an
    /// active index run comes from re-reading ``SemanticSearchControl/progress`` on a timer
    /// instead of Observation crossing the package boundary. Half a second is fast enough that
    /// a progress bar filling in still reads as live, and cheap enough that a synchronous
    /// tuple read every tick costs nothing worth measuring. `.task` cancels this the moment
    /// the pane is not the one showing, so nothing polls in the background.
    private func pollIndexProgress() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else {
                return
            }
            model.refreshIndexProgress()
        }
    }
}

// MARK: - Preview

#Preview {
    GeneralSettingsView(model: GeneralSettingsModel(
        digest: DigestSettingsModel(
            defaults: UserDefaults(suiteName: "app.backglance.preview.general") ?? .standard,
            authorization: BannerAuthorizing(read: { .notDetermined }, request: { .authorized })
        ),
        search: SemanticSearchControl(isAvailable: { true }, isEnabled: { true }, progress: { (12_000, 41_000) }),
        launchAtLogin: LaunchAtLoginControl(readStatus: { .registered }, setEnabled: { _ in .success(.registered) }),
        hotKey: HotKeyControl(isRegistered: { true }, retry: { true })
    ))
    .frame(width: 460, height: 520)
}
