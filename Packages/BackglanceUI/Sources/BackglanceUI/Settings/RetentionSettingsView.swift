import BackglanceCore
import SwiftUI

// MARK: - RetentionSettingsView

/// Settings ▸ Privacy ▸ Retention: how long notifications stick around, globally and per
/// app.
///
/// A `Section` rather than a whole pane, so the Privacy pane can host it beside exclusions,
/// redaction and the wipe without this file knowing anything about them
/// (docs/features/PRIVACY_CONTROLS.md#ui-components). Until that pane exists it sits in the
/// Settings form directly, which is also how the other three sections got here.
///
/// The global picker and the per-app picker deliberately do not offer the same choices.
/// `RetentionSettings.globalChoices` leaves out "Never store" — as a global it would be a
/// way to switch the whole product off from a picker labelled "Keep notifications for" — but
/// it is exactly what a per-app override is for, so `PerAppRetentionList` offers every
/// `RetentionPolicy` case.
public struct RetentionSettingsView: View {
    // MARK: Lifecycle

    public init(model: RetentionSettingsModel) {
        self.model = model
    }

    // MARK: Public

    public var body: some View {
        @Bindable var model = model

        Section {
            Picker(String(localized: "Keep notifications for"), selection: $model.global) {
                ForEach(RetentionSettings.globalChoices, id: \.self) { policy in
                    Text(retentionLabel(policy)).tag(policy)
                }
            }
            .accessibilityIdentifier("privacy.retention.global")

            PerAppRetentionList(model: model)

            Button(String(localized: "Run cleanup now")) {
                Task { await model.runCleanupNow() }
            }
            .disabled(!model.canRunCleanupNow)
            .accessibilityIdentifier("privacy.retention.cleanup")

            if let report = model.lastReport {
                Text(reportText(report))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: "Retention"))
        } footer: {
            Text(footer)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await model.load() }
    }

    // MARK: Private

    private let model: RetentionSettingsModel

    private var footer: String {
        String(localized: """
        Notifications older than their app's retention window are removed automatically, \
        about every six hours. Pinned notifications are never removed by age.
        """)
    }
}

// MARK: - PerAppRetentionList

/// One retention picker per app the archive knows about.
///
/// Flat, like `ExcludedAppsList` and `RedactionAppList`: there is no "overridden" group to
/// promote a row into, because every app already has a row here and "Inherit" is simply one
/// of the choices rather than the row's absence.
struct PerAppRetentionList: View {
    let model: RetentionSettingsModel

    var body: some View {
        ForEach(model.rows) { row in
            Picker(
                row.name,
                selection: Binding(
                    get: { row.retention },
                    set: { retention in
                        Task { await model.setRetention(retention, forBundleID: row.bundleID) }
                    }
                )
            ) {
                Text(String(localized: "Inherit")).tag(AppRetention.inherit)
                // Every `RetentionPolicy` case, including `.never` — the one choice the
                // global picker above deliberately leaves out. Here it is the legitimate
                // "never store this app" answer, not a way to switch the whole product off.
                ForEach(RetentionPolicy.allCases, id: \.self) { policy in
                    Text(retentionLabel(policy)).tag(AppRetention.policy(policy))
                }
            }
            .accessibilityIdentifier("privacy.retention.app.\(row.bundleID)")
        }
    }
}

// MARK: - Shared labels

/// Human labels for a policy, shared by the global picker (which offers four of these) and
/// the per-app picker (which offers all five plus "Inherit").
///
/// A free function rather than a method on either view: both need it, and neither owns it
/// any more than the other does. `internal` rather than `private`, so ``AppsSettingsView``'s
/// consolidated per-app picker can show the same words this file's pickers do, instead of a
/// second copy of the same five strings drifting from these.
func retentionLabel(_ policy: RetentionPolicy) -> String {
    switch policy {
    case .hours24:
        String(localized: "24 hours")

    case .days7:
        String(localized: "7 days")

    case .days30:
        String(localized: "30 days")

    case .forever:
        String(localized: "Forever")

    case .never:
        String(localized: "Never store")
    }
}

/// What the last cleanup pass did, in the words the pane owes the user after they pressed a
/// button and watched it disable itself. Counts only — never a bundle id or a notification's
/// content — because a pass touches apps by the hundred and a per-app breakdown would say
/// more than "cleanup ran" needs to.
private func reportText(_ report: RetentionJob.Report) -> String {
    guard !report.isEmpty else {
        return String(localized: "Nothing needed cleaning up.")
    }
    return String(localized: """
    Hid \(report.softDeleted) notification(s) past their retention window and permanently \
    removed \(report.hardDeleted) from an earlier pass.
    """)
}

// MARK: - Preview

#Preview {
    Form {
        RetentionSettingsView(model: RetentionSettingsModel(archive: nil, job: nil))
    }
    .formStyle(.grouped)
    .frame(width: 460)
}
