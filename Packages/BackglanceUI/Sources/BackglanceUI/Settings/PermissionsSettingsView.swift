import SwiftUI

// MARK: - PermissionsSettingsView

/// Settings ▸ Permissions: what Backglance has been allowed to do, and how to change it.
///
/// Three permissions, three shapes, and the pane is honest about the difference. Full Disk
/// Access has no button that grants it — only one that opens System Settings, because macOS
/// has no prompt for it. Notifications is reported here but asked for in the Digest pane, on
/// the one toggle that needs it: a permissions pane that requests things while you read it is
/// how people end up denying something they would have allowed later. Login Items can simply
/// be set, and its toggle arrives with `LaunchAtLogin`.
///
/// The `tccutil` command is shown and copyable, never run. An app that resets its own TCC
/// grants is indistinguishable from one probing what else it can reset, and the point of this
/// pane is that the permission is the user's to give and take.
///
/// See docs/features/PERMISSIONS_PRIVACY.md#ui-components.
public struct PermissionsSettingsView: View {
    // MARK: Lifecycle

    public init(model: PermissionsSettingsModel) {
        self.model = model
    }

    // MARK: Public

    public var body: some View {
        Form {
            fullDiskAccessSection
            notificationsSection
            loginItemsSection
            troubleshootingSection
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
    }

    // MARK: Private

    private let model: PermissionsSettingsModel

    private var fdaStatus: PermissionStatus {
        switch model.fdaState {
        case .granted:
            .good(String(localized: "Granted"))

        case .denied:
            .attention(String(localized: "Not granted — capture is off"))

        // Not a permission problem, and this row must not imply one.
        case .storeMissing:
            .neutral(String(localized: "Granted, but macOS has no notification database yet"))
        }
    }

    private var bannerStatus: PermissionStatus {
        switch model.bannerAuthorization {
        case .authorized:
            .good(String(localized: "Allowed"))

        case .denied:
            .neutral(String(localized: "Not allowed — the digest opens in the popover instead"))

        case .notDetermined:
            .neutral(String(localized: "Not asked yet"))
        }
    }

    private var loginItemStatus: PermissionStatus {
        switch model.loginItemStatus {
        case .registered:
            .good(String(localized: "On"))

        case .notRegistered:
            .neutral(String(localized: "Off"))

        case .requiresApproval:
            .attention(String(localized: "Waiting for approval in System Settings"))

        case .unavailable:
            .neutral(String(localized: "Unavailable"))
        }
    }

    private var fullDiskAccessSection: some View {
        Section {
            PermissionRow(
                title: String(localized: "Full Disk Access"),
                status: fdaStatus,
                identifier: "permissions.fda"
            )

            Button(String(localized: "Open Full Disk Access Settings")) {
                model.actions.openFullDiskAccessSettings()
            }
            .accessibilityIdentifier("permissions.fda.open")

            Button(String(localized: "Check again")) {
                Task { await model.refresh() }
            }
            .accessibilityIdentifier("permissions.fda.check")

            Button(String(localized: "Show setup again")) {
                model.actions.showSetupAgain()
            }
            .accessibilityIdentifier("permissions.showSetup")
        } header: {
            Text(String(localized: "Capture"))
        } footer: {
            Text(String(localized: """
            Notification history lives in a system database macOS protects, and Full Disk Access is \
            the only permission that can read it. Backglance can’t request it — macOS has no prompt \
            for this one — so the button above opens the setting.
            """))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var notificationsSection: some View {
        Section {
            PermissionRow(
                title: String(localized: "Notifications"),
                status: bannerStatus,
                identifier: "permissions.notifications"
            )

            Button(String(localized: "Open Notification Settings")) {
                model.actions.openNotificationSettings()
            }
            .accessibilityIdentifier("permissions.notifications.open")
        } header: {
            Text(String(localized: "Notifications"))
        } footer: {
            Text(String(localized: """
            Only used for the optional missed-notifications banner, and only asked for when you turn \
            that banner on. Backglance works fully without it.
            """))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loginItemsSection: some View {
        Section {
            PermissionRow(
                title: String(localized: "Open at Login"),
                status: loginItemStatus,
                identifier: "permissions.loginItems"
            )

            Button(String(localized: "Open Login Items Settings")) {
                model.actions.openLoginItemsSettings()
            }
            .accessibilityIdentifier("permissions.loginItems.open")
        } header: {
            Text(String(localized: "Startup"))
        } footer: {
            Text(String(localized: """
            Backglance only archives notifications while it is running, so anything delivered before \
            you open it is gone by the time it starts.
            """))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// In a disclosure, closed by default. It is the right answer for the handful of people
    /// whose grant is stuck, and a Terminal command in an always-open settings pane reads as
    /// something the user is expected to do.
    private var troubleshootingSection: some View {
        Section {
            DisclosureGroup(String(localized: "Full Disk Access isn’t sticking")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: """
                    macOS sometimes keeps an old decision for an app that has been rebuilt or replaced. \
                    This makes it forget Backglance’s, so the switch can be set again from scratch. \
                    Backglance won’t run it for you.
                    """))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Text(verbatim: PermissionsSettingsModel.tccutilCommand)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityIdentifier("permissions.tccutil.command")

                    Button(String(localized: "Copy command")) {
                        model.actions.copyToPasteboard(PermissionsSettingsModel.tccutilCommand)
                    }
                    .accessibilityIdentifier("permissions.tccutil.copy")
                }
                .padding(.top, 4)
            }
            .accessibilityIdentifier("permissions.troubleshooting")
        } header: {
            Text(String(localized: "Troubleshooting"))
        }
    }
}

// MARK: - PermissionStatus

/// One row's answer, and how strongly to say it.
///
/// Only ``attention(_:)`` gets a colour. A pane where every row is green or red trains people
/// to read the colour instead of the words, and two of these three permissions are perfectly
/// fine to be without.
enum PermissionStatus {
    case good(String)
    case neutral(String)
    case attention(String)

    // MARK: Internal

    var text: String {
        switch self {
        case let .good(text),
             let .neutral(text),
             let .attention(text):
            text
        }
    }

    var symbol: String {
        switch self {
        case .good: "checkmark.circle.fill"
        case .neutral: "circle"
        case .attention: "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - PermissionRow

/// One permission's name and state.
struct PermissionRow: View {
    // MARK: Internal

    let title: String
    let status: PermissionStatus
    let identifier: String

    var body: some View {
        LabeledContent(title) {
            Label(status.text, systemImage: status.symbol)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Private

    private var tint: HierarchicalShapeStyle {
        if case .attention = status {
            return .primary
        }
        return .secondary
    }
}

#Preview {
    PermissionsSettingsView(model: PermissionsSettingsModel())
        .frame(width: 480, height: 520)
}
