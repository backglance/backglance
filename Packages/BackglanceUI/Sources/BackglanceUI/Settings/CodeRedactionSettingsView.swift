import BackglanceCore
import SwiftUI

// MARK: - CodeRedactionSettingsView

/// Settings ▸ Privacy ▸ One-time code redaction: the global override, and a toggle per
/// app.
///
/// A `Section` rather than a whole pane, so that the Privacy pane can host it beside
/// retention, exclusions and the wipe without this file knowing anything about them
/// (docs/features/PRIVACY_CONTROLS.md#ui-components). Until that pane exists it sits in
/// the Settings form directly, which is also how the Digest section got here.
///
/// The footer is not decoration. Redaction is the one control that removes information
/// rather than hiding it, and the two facts a user needs before touching a toggle — that
/// the digits are never written, and that turning it off cannot bring back the ones that
/// already were not — belong next to the toggles rather than in a help page.
public struct CodeRedactionSettingsView: View {
    // MARK: Lifecycle

    public init(model: CodeRedactionSettingsModel) {
        self.model = model
    }

    // MARK: Public

    public var body: some View {
        @Bindable var model = model

        Section {
            Toggle(
                String(localized: "Redact codes in all apps", comment: "Toggle: apply code redaction to every app"),
                isOn: $model.redactsAllApps
            )
            .accessibilityIdentifier("privacy.redaction.allApps")

            Text(allAppsExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            RedactionAppList(model: model)
            addAppRow

            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: "One-time code redaction", comment: "Section header in Privacy settings"))
        } footer: {
            Text(footer)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await model.load() }
        .alert(
            String(localized: "Codes from this app will be stored in plain text"),
            isPresented: Binding(
                get: { model.plainTextWarningBundleID != nil },
                set: { presented in
                    if !presented {
                        model.dismissPlainTextWarning()
                    }
                }
            )
        ) {
            Button(String(localized: "OK", comment: "Button: dismiss the alert")) { model.dismissPlainTextWarning() }
        } message: {
            Text(String(localized: """
            Future verification codes from this app will be archived exactly as they arrive. \
            Codes that were already redacted stay redacted — Backglance never stored them.
            """))
        }
    }

    // MARK: Private

    private let model: CodeRedactionSettingsModel

    /// Why the global override is off by default, in the words the pane owes the user:
    /// it is not caution for its own sake, it is that the patterns are tuned for one kind
    /// of message and misfire on another.
    private var allAppsExplanation: String {
        String(localized: """
        Off by default. The patterns are written for the way text messages and e-mail \
        announce a code, so running them everywhere turns the occasional ticket or order \
        number into “[code redacted]” too.
        """, comment: "Keep '[code redacted]' verbatim — it must match the stored replacement text")
    }

    private var footer: String {
        String(localized: """
        Verification codes are replaced with “[code redacted]” before they are stored. \
        The original digits are never written to your archive, the search index or an \
        export. Turning redaction off cannot restore codes that were already redacted.
        """, comment: "Keep '[code redacted]' verbatim — it must match the stored replacement text")
    }

    /// Adding an app the archive has not seen. A plain text field rather than an app
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
            .accessibilityIdentifier("privacy.redaction.addField")
            .onSubmit { Task { await model.addPendingBundleID() } }

            Button(String(localized: "Add", comment: "Button: add the typed bundle identifier to the list")) {
                Task { await model.addPendingBundleID() }
            }
            .disabled(!model.canAddPendingBundleID)
            .accessibilityIdentifier("privacy.redaction.add")
        }
    }
}

// MARK: - RedactionAppList

/// One toggle per app the archive knows about.
///
/// Flat rather than split into "on" and "off" groups: a row that jumps to another part of
/// the list the moment it is switched is a row the user has to go and find again to undo,
/// and this is a control where undoing is exactly what someone does after a false
/// positive.
struct RedactionAppList: View {
    let model: CodeRedactionSettingsModel

    var body: some View {
        ForEach(model.rows) { row in
            Toggle(
                row.name,
                isOn: Binding(
                    get: { row.isOn },
                    set: { on in
                        Task { await model.setRedaction(on, forBundleID: row.bundleID) }
                    }
                )
            )
            .accessibilityIdentifier("privacy.redaction.app.\(row.bundleID)")
        }
    }
}

// MARK: - Preview

#Preview {
    Form {
        CodeRedactionSettingsView(
            model: CodeRedactionSettingsModel(
                archive: nil,
                defaults: UserDefaults(suiteName: "app.backglance.preview.redaction") ?? .standard
            )
        )
    }
    .formStyle(.grouped)
    .frame(width: 460)
}
