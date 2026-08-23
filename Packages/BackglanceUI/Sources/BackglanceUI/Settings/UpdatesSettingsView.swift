import SwiftUI

// MARK: - UpdatesSettingsView

/// Settings ▸ Updates: one toggle, one button, and the sentence that makes them mean
/// something.
///
/// 🔒 The footnote under the toggle is not marketing copy — it is the user-facing form of
/// docs/security/SECURITY.md#the-updater, and it is only true because nothing else in
/// Backglance links a networking API. If that ever stops being true, this text is the first
/// thing that has to change.
///
/// "Check for Updates…" stays enabled while automatic checks are off, because the user
/// clicking it *is* consent for that one request (``UpdaterTrigger/userInitiated``).
///
/// See docs/deployment/PACKAGING_NOTARIZATION.md#sparkleupdatercontroller-and-the-off-means-off-guarantee.
public struct UpdatesSettingsView: View {
    // MARK: Lifecycle

    public init(model: UpdatesSettingsModel) {
        self.model = model
    }

    // MARK: Public

    public var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Version"), value: model.version)
                    .accessibilityIdentifier("settings.updates.version")

                Toggle(String(localized: "Check for updates automatically"), isOn: Binding(
                    get: { model.automaticChecksEnabled },
                    set: { model.automaticChecksEnabled = $0 }
                ))
                .disabled(!model.isConfigured)
                .accessibilityIdentifier("settings.updates.automatic")

                Text(
                    """
                    When this is off, Backglance makes no network connections at all. \
                    Updates are the only thing it ever fetches — there is no telemetry and \
                    no crash reporting.
                    """
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } header: {
                Text(String(localized: "Updates"))
            }

            Section {
                Button(String(localized: "Check for Updates…")) {
                    model.checkForUpdates()
                }
                .disabled(!model.isConfigured || !model.canCheckForUpdates)
                .accessibilityIdentifier("settings.updates.check")

                if !model.isConfigured {
                    Text(
                        """
                        This build carries no update signing key, so it cannot check for \
                        updates. That is expected for a build you compiled yourself; \
                        released builds are signed.
                        """
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.updates.unconfigured")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
    }

    // MARK: Private

    private let model: UpdatesSettingsModel
}

// MARK: - Preview

#Preview {
    UpdatesSettingsView(model: UpdatesSettingsModel(
        updater: UpdaterControl(isConfigured: { true }, canCheckForUpdates: { true }),
        version: "1.0.0"
    ))
    .frame(width: 480, height: 360)
}
