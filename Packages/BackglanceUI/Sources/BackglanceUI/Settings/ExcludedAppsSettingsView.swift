import BackglanceCore
import SwiftUI

// MARK: - ExcludedAppsSettingsView

/// Settings ▸ Privacy ▸ Excluded apps: which apps are never archived, and the two ways to
/// change that.
///
/// A `Section` rather than a whole pane, so the Privacy pane can host it beside retention,
/// redaction and the wipe without this file knowing anything about them
/// (docs/features/PRIVACY_CONTROLS.md#ui-components). Until that pane exists it sits in
/// the Settings form directly, which is also how Digest and Code Redaction got here.
///
/// The footer is not decoration. Backglance ships a short list because a bundle identifier
/// does not say "this is a bank" — the user is the one who knows that, and the sentence
/// below is the ask.
public struct ExcludedAppsSettingsView: View {
    // MARK: Lifecycle

    public init(model: ExcludedAppsSettingsModel) {
        self.model = model
    }

    // MARK: Public

    public var body: some View {
        Section {
            ExcludedAppsList(model: model)
            addAppRow

            Button(String(localized: "Restore defaults", comment: "Button: put the shipped exclusions back")) {
                Task { await model.restoreDefaults() }
            }
            .accessibilityIdentifier("privacy.exclusions.restore")

            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: "Excluded apps", comment: "Section header in Privacy settings"))
        } footer: {
            Text(footer)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await model.load() }
    }

    // MARK: Private

    private let model: ExcludedAppsSettingsModel

    private var footer: String {
        String(localized: """
        Notifications from these apps are never stored. Backglance cannot tell which apps \
        are sensitive — add your bank, brokerage or health apps here.
        """)
    }

    /// Excluding an app the archive has not seen. A plain text field rather than an app
    /// picker: the thing being named is a bundle identifier, and a picker over installed
    /// applications would not list the ones that notify through a helper process.
    @ViewBuilder private var addAppRow: some View {
        @Bindable var model = model

        HStack {
            TextField(
                String(localized: "Bundle identifier", comment: "Text field label: the app's bundle identifier"),
                text: $model.pendingBundleID,
                prompt: Text(verbatim: "com.example.app")
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("privacy.exclusions.addField")
            .onSubmit { Task { await model.addPendingBundleID() } }

            Button(String(localized: "Add app…", comment: "Button: exclude the typed bundle identifier")) {
                Task { await model.addPendingBundleID() }
            }
            .disabled(!model.canAddPendingBundleID)
            .accessibilityIdentifier("privacy.exclusions.add")
        }
    }
}

// MARK: - ExcludedAppsList

/// One row per excluded app, each with a way to remove it.
///
/// Flat, and with no toggle: unlike redaction, an app either belongs on this list or it
/// does not, and "Remove" is the entire vocabulary a membership list needs. Adding it back
/// is what the text field above and "Restore defaults" are for.
struct ExcludedAppsList: View {
    // MARK: Internal

    let model: ExcludedAppsSettingsModel

    var body: some View {
        ForEach(model.rows) { row in
            HStack {
                // The identifier goes on the label rather than on the row: SwiftUI pushes
                // it down to every descendant, so an identifier on the `HStack` would land
                // on the button too and shadow its own — leaving the one control in the
                // row that a test needs to press addressable only by the row it sits in.
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)

                    if let reason = row.reason {
                        Text(Self.reasonText(reason))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("privacy.exclusions.app.\(row.bundleID)")

                Spacer()

                Button(String(localized: "Remove", comment: "Button: take this app off the exclusion list")) {
                    Task { await model.remove(bundleID: row.bundleID) }
                }
                .accessibilityIdentifier("privacy.exclusions.remove.\(row.bundleID)")
            }
        }
    }

    // MARK: Private

    /// Why a shipped default is on the list, in the words the row owes the user — a
    /// password manager and Backglance's own banners are excluded for different reasons,
    /// and a row that just said "default" either way would not let anyone judge for
    /// themselves whether it still applies to them.
    private static func reasonText(_ reason: ExclusionList.ShippedDefault.Reason) -> String {
        switch reason {
        case .passwordManager:
            String(localized: "Password manager", comment: "Caption: why this shipped default is excluded")

        case .ownNotifications:
            String(localized: "Backglance's own notifications", comment: "Caption: why this default is excluded")
        }
    }
}

// MARK: - Preview

#Preview {
    Form {
        ExcludedAppsSettingsView(model: ExcludedAppsSettingsModel(archive: nil))
    }
    .formStyle(.grouped)
    .frame(width: 460)
}
