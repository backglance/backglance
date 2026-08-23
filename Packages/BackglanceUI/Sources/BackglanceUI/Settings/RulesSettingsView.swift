import AppKit
import BackglanceCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - RulesSettingsView

/// Settings ▸ Rules: the `Table` of every configured rule, Add/Edit/Delete, and the •••
/// menu's export/import.
///
/// A whole tab (`SettingsView.swift`), not a `Section` folded into another pane the way
/// Retention and Excluded Apps are folded into Privacy — rules are their own subject with
/// their own editor sheet and their own live preview, not one more toggle among several.
///
/// BACKGLANCE-211: the sentence directly under the title is fixed copy, on purpose. Every
/// other line in this pane is about *which* rule does *what*; this one exists so nobody
/// reads the rest of the pane and concludes a mute rule is quietly suppressing a banner
/// macOS would otherwise show — it never does, and the sentence says so before anything
/// else on the screen can imply otherwise. The same claim, from the other direction, is in
/// `docs/reference/FAQ.md:164`.
///
/// See docs/features/RULES.md#ui-components.
public struct RulesSettingsView: View {
    // MARK: Lifecycle

    public init(model: RulesSettingsModel) {
        self.model = model
    }

    // MARK: Public

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            RulesTable(model: model, editing: $editingRule)
                .accessibilityIdentifier("rules.table")

            HStack {
                Button(String(localized: "Add Rule…", comment: "Button: opens the editor to create a new rule")) {
                    editingRule = .new
                }
                .accessibilityIdentifier("rules.add")

                Spacer()

                if let importResult = model.importResult {
                    Text(importResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("rules.importResult")
                }

                menu
            }

            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("rules.failure")
            }
        }
        .padding(20)
        .task { await model.load() }
        .sheet(item: $editingRule) { target in
            RuleEditorSheet(model: model, rule: target.rule) { editingRule = nil }
        }
    }

    // MARK: Private

    @State private var editingRule: EditTarget?

    private let model: RulesSettingsModel

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Rules", comment: "Pane title: notification highlight, VIP and mute rules"))
                .font(.title2.weight(.semibold))
            Text(String(localized: """
            Rules change how Backglance shows notifications. They do not change what macOS delivers.
            """))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("rules.headerCopy")
        }
    }

    /// Export Rules…, Import Rules…, Open Notification Settings… — the three items
    /// docs/features/RULES.md#ui-components lists for this menu. The first two are
    /// disabled together, from `model.canImportExport`, since both need the same
    /// `RulesEngine` this model may not have been given (a preview, or a launch whose
    /// archive would not open).
    private var menu: some View {
        Menu {
            Button(String(localized: "Export Rules…", comment: "Menu item: saves all rules to a JSON file")) {
                exportRules()
            }
            .disabled(!model.canImportExport)
            Button(String(localized: "Import Rules…", comment: "Menu item: loads rules from a JSON file")) {
                importRules()
            }
            .disabled(!model.canImportExport)
            Divider()
            Button(String(
                localized: "Open Notification Settings…",
                comment: "Menu item: opens the Notifications pane of macOS System Settings"
            )) {
                openNotificationSettings()
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 28)
        .accessibilityIdentifier("rules.menu")
    }

    /// `NSSavePanel` and `NSOpenPanel` called directly, the same posture
    /// `PrivacySettingsView`'s "Reveal Archive in Finder" takes for `NSWorkspace`: a modal
    /// file panel that only ever runs from a menu click has nothing worth mocking behind a
    /// seam the way `NotificationActionHandler`'s export path does, and this pane has no
    /// test that drives the panel itself — only `RulesSettingsModel.exportRules(to:)` and
    /// `importRules(from:)`, which take a `URL` and never see the panel at all.
    private func exportRules() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "backglance-rules.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        Task { await model.exportRules(to: url) }
    }

    private func importRules() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        Task { await model.importRules(from: url) }
    }

    /// The generic, no-app-in-mind rung of `SystemSettingsLink`'s own three-URL ladder —
    /// this menu item has no particular app to name, unlike the per-row button beside an
    /// app-scoped mute rule, which uses `SystemSettingsLink` itself.
    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - EditTarget

/// What `.sheet(item:)` needs: `nil` means no sheet, `.new` opens a blank editor, `.existing`
/// opens one seeded from an archived row. A plain `Rule?` could not tell "no sheet" apart
/// from "editing a brand-new, not-yet-saved rule" — both would be `nil` — so this wraps it.
struct EditTarget: Identifiable {
    static let new = EditTarget(rule: nil)

    let rule: Rule?

    /// The rule's own id for an edit, or `-1` for a new draft — `Rule.draftID`, the same
    /// sentinel `RulesEngine.compile(_:)` already uses for an id that cannot collide with
    /// a real archive row.
    var id: Int64 {
        rule?.id ?? Rule.draftID
    }
}

// MARK: - RulesTable

/// One row per rule: enable toggle, orange warning badge, a short summary of what it does,
/// its priority, and Edit/Delete — plus, for a `mute` rule scoped to one app, the
/// "Notification Settings for ‹App›…" button docs/features/RULES.md#ui-components calls
/// for.
///
/// `SwiftUI.Table`, not a `List` of `HStack`s: RULES.md names a `Table` explicitly, and a
/// real table gives the priority column something a `List` cannot — a place to actually
/// line up numbers instead of reading them off the end of a wrapped row.
struct RulesTable: View {
    // MARK: Internal

    let model: RulesSettingsModel

    @Binding var editing: EditTarget?

    var body: some View {
        Table(model.rules) {
            TableColumn(String(localized: "On", comment: "Column header: whether the rule is enabled")) { rule in
                Toggle(String(localized: "Enabled", comment: "Toggle: whether the rule is active"), isOn: Binding(
                    get: { rule.isEnabled },
                    set: { newValue in Task { await model.setEnabled(newValue, for: rule) } }
                ))
                .labelsHidden()
                .accessibilityIdentifier("rules.list.enabled.\(rule.id ?? -1)")
            }
            .width(36)

            TableColumn(String(localized: "!", comment: "Column header: warning badge for broken rules")) { rule in
                if let id = rule.id, let problem = model.problemsByRuleID[id] {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(problem.message)
                        .accessibilityIdentifier("rules.list.warning.\(id)")
                }
            }
            .width(24)

            TableColumn(String(localized: "Rule", comment: "Column header: summary of what each rule does")) { rule in
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.summary(rule))
                        .accessibilityIdentifier("rules.list.summary.\(rule.id ?? -1)")
                    if rule.kind == .mute, let appBundleID = rule.appBundleId {
                        Button(String(
                            localized: "Notification Settings for \(appBundleID)…",
                            comment: "Button: placeholder is an app’s bundle id; opens its notification settings"
                        )) {
                            try? SystemSettingsLink(workspace: NSWorkspaceAppLauncher()).open(bundleID: appBundleID)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .accessibilityIdentifier("rules.list.notificationSettings.\(rule.id ?? -1)")
                    }
                }
            }

            TableColumn(String(localized: "Priority", comment: "Rule priority; higher-priority rules win")) { rule in
                Text(rule.priority, format: .number)
                    .monospacedDigit()
            }
            .width(60)

            TableColumn("") { rule in
                HStack(spacing: 8) {
                    Button(String(localized: "Edit…")) { editing = EditTarget(rule: rule) }
                        .accessibilityIdentifier("rules.list.edit.\(rule.id ?? -1)")
                    Button(String(localized: "Delete"), role: .destructive) {
                        Task { await model.delete(rule) }
                    }
                    .accessibilityIdentifier("rules.list.delete.\(rule.id ?? -1)")
                }
            }
            .width(140)
        }
    }

    // MARK: Private

    /// A one-line, content-free description: the rule's kind, what it matches on, and
    /// which app it is scoped to, if any. Never the pattern's own match count or a preview
    /// of what it caught — this is the settings list, not a report on notification
    /// content.
    private static func summary(_ rule: Rule) -> String {
        let kind = switch rule.kind {
        case .highlight: String(localized: "Highlight", comment: "Rule kind: highlights matches in colour")
        case .vip: String(localized: "VIP", comment: "Rule kind: marks matches as important")
        case .mute: String(localized: "Mute", comment: "Rule kind: hides matches in Backglance only")
        case .regex: String(localized: "Regex", comment: "Rule kind: regular-expression pattern")
        }
        let field = switch rule.matchField {
        case .any: String(localized: "anywhere", comment: "Match field name, lowercase, shown inside a rule summary")
        case .title: String(localized: "title", comment: "Match field name, lowercase, shown inside a rule summary")
        case .body: String(localized: "body", comment: "Match field name, lowercase, shown inside a rule summary")
        case .sender: String(localized: "sender", comment: "Match field name, lowercase, shown inside a rule summary")
        case .app: String(localized: "app", comment: "Match field name, lowercase, shown inside a rule summary")
        }
        guard let scope = rule.appBundleId else {
            return String(
                localized: "\(kind) · \(field) · “\(rule.pattern)”",
                comment: "Rule summary: kind name, match-field name, then the rule’s pattern"
            )
        }
        return String(
            localized: "\(kind) · \(field) · “\(rule.pattern)” · \(scope)",
            comment: "Rule summary: kind, match field, the rule’s pattern, then the app bundle id it is limited to"
        )
    }
}

// MARK: - Preview

#Preview {
    RulesSettingsView(model: RulesSettingsModel(archive: nil, engine: nil))
        .frame(width: 520, height: 480)
}
