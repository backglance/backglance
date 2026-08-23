import BackglanceCore
import SwiftUI

// MARK: - AppsSettingsView

/// Settings ▸ Apps: an app picker on the left, every per-app setting that app carries on the
/// right.
///
/// A `NavigationSplitView` rather than another flat `Form` section, because this pane's whole
/// reason to exist is picking *one* app out of however many the archive holds and seeing its
/// settings together — a flat list would either repeat the picker per row (what Retention,
/// Excluded Apps and Code Redaction already do, each for one setting) or hide the point of
/// having a dedicated pane at all.
///
/// See ``AppsSettingsModel``'s doc comment for what this deliberately does not add, and
/// docs/features/PRIVACY_CONTROLS.md#ui-components.
public struct AppsSettingsView: View {
    // MARK: Lifecycle

    public init(model: AppsSettingsModel) {
        self.model = model
    }

    // MARK: Public

    public var body: some View {
        NavigationSplitView {
            appList
        } detail: {
            if let row = model.selectedRow {
                AppDetailForm(model: model, row: row)
            } else {
                emptySelection
            }
        }
        .task { await model.load() }
    }

    // MARK: Private

    @Bindable private var model: AppsSettingsModel

    @ViewBuilder private var appList: some View {
        if model.rows.isEmpty {
            emptyArchive
        } else {
            List(model.rows, selection: $model.selectedBundleID) { row in
                AppListRow(row: row)
                    .tag(row.bundleID)
                    .accessibilityIdentifier("apps.list.\(row.bundleID)")
            }
            .listStyle(.sidebar)
            .frame(minWidth: 180)
        }
    }

    private var emptyArchive: some View {
        VStack(spacing: 8) {
            Image(systemName: "app.dashed")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(String(localized: "No apps yet", comment: "Empty-state placeholder: the archive holds no apps"))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 180)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("apps.list.empty")
    }

    private var emptySelection: some View {
        Text(String(localized: "Select an app", comment: "Placeholder in the detail pane when no app is selected"))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Identified like its sibling `apps.list.empty`, and for a second reason: this
            // pane is a `NavigationSplitView`, so the `settings.tab.apps` identifier on it
            // does not surface the way the other six panes' do. This placeholder is how a
            // test knows the Apps pane is the one showing.
            .accessibilityIdentifier("apps.detail.empty")
    }
}

// MARK: - AppListRow

/// One app in the picker: its name, and how much it has spoken.
struct AppListRow: View {
    let row: RetentionAppRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.name)
            Text(String(
                localized: "\(row.notificationCount) notifications",
                comment: "Caption under the app's name; placeholder is a count of archived notifications"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - AppDetailForm

/// The selected app's three per-app settings, each one a plain read/write into the model
/// that already owns it — nothing here is a second copy of retention, exclusion or redaction
/// logic.
struct AppDetailForm: View {
    // MARK: Internal

    let model: AppsSettingsModel
    let row: RetentionAppRow

    var body: some View {
        Form {
            Section {
                Picker(
                    String(localized: "Keep notifications for", comment: "Picker label: per-app retention period"),
                    selection: retentionBinding
                ) {
                    Text(String(localized: "Inherit", comment: "Picker option: use the global retention setting"))
                        .tag(AppRetention.inherit)
                    ForEach(RetentionPolicy.allCases, id: \.self) { policy in
                        Text(retentionLabel(policy)).tag(AppRetention.policy(policy))
                    }
                }
                .accessibilityIdentifier("apps.detail.retention")

                Toggle(
                    String(localized: "Exclude this app", comment: "Toggle: never archive this app's notifications"),
                    isOn: excludedBinding
                )
                .accessibilityIdentifier("apps.detail.excluded")

                Toggle(
                    String(localized: "Redact one-time codes", comment: "Toggle: replace codes before storing"),
                    isOn: redactedBinding
                )
                .accessibilityIdentifier("apps.detail.redaction")

                if let failure = model.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(row.name)
            } footer: {
                Text(String(localized: """
                Choosing "Never store" above also turns on "Exclude this app", in the same write. \
                Turning "Exclude this app" off on its own does not change the retention policy — \
                pick a window above if you want capture to resume under one.
                """, comment: "Footer; the quoted phrases must match the picker option and toggle labels above"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("apps.detail.\(row.bundleID)")
    }

    // MARK: Private

    private var retentionBinding: Binding<AppRetention> {
        Binding(
            get: { row.retention },
            set: { policy in Task { await model.setRetention(policy) } }
        )
    }

    private var excludedBinding: Binding<Bool> {
        Binding(
            get: { model.isSelectedExcluded },
            set: { excluded in Task { await model.setExcluded(excluded) } }
        )
    }

    private var redactedBinding: Binding<Bool> {
        Binding(
            get: { model.isSelectedRedacted },
            set: { enabled in Task { await model.setRedaction(enabled) } }
        )
    }
}

// MARK: - Preview

#Preview {
    AppsSettingsView(model: AppsSettingsModel(
        retention: RetentionSettingsModel(archive: nil, job: nil),
        exclusions: ExcludedAppsSettingsModel(archive: nil),
        redaction: CodeRedactionSettingsModel(
            archive: nil,
            defaults: UserDefaults(suiteName: "app.backglance.preview.apps") ?? .standard
        )
    ))
    .frame(width: 520, height: 420)
}
