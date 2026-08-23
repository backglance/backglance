import BackglanceCore
import SwiftUI

// MARK: - RuleEditorSheet

/// The sheet Add… and Edit… on the Rules pane both open — kind, pattern, match field, app
/// scope, colour, whole-word toggle, priority, and the two things that make a rule
/// trustworthy before it is ever saved: the inline compile error and the live preview.
///
/// A draft lives entirely in this view's own `@State`, not in `RulesSettingsModel` — the
/// model only ever sees a fully-built `Rule` (through ``RulesSettingsModel/refreshPreview(for:)``
/// on every field change, and once more through ``RulesSettingsModel/save(_:)`` on Save).
/// That split keeps the model's public surface exactly "compile this rule" and "save this
/// rule" rather than a dozen bindings for every field an editor happens to have.
///
/// The whole-word toggle is not a stored column — `RulesEngine+Compile.swift` reads it off
/// the pattern text itself, wrapped in literal quotes (`"invoice"` compiles to a
/// word-boundary matcher, `invoice` to plain substring containment). This sheet is the one
/// place that quoting convention has to be built and unbuilt: ``init(model:rule:)`` strips
/// the quotes back off an existing rule's pattern to seed the toggle and the plain text
/// field, and ``buildDraft()`` re-adds them on the way out.
///
/// See docs/features/RULES.md#ui-components.
public struct RuleEditorSheet: View {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - model: where Save and the live preview go.
    ///   - rule: the row being edited, or `nil` to start a fresh draft. `rule.id` is
    ///     threaded straight through so ``RulesSettingsModel/save(_:)`` knows whether to
    ///     insert or update.
    ///   - onClose: called after a successful save, or when Cancel is pressed. Not called
    ///     on a failed save — the sheet stays open so the failure (`model.failure`) and
    ///     the still-typed draft are both still visible.
    public init(model: RulesSettingsModel, rule: Rule?, onClose: @escaping () -> Void) {
        self.model = model
        existingID = rule?.id
        self.onClose = onClose

        let rawPattern = rule?.pattern ?? ""
        let isQuoted = rawPattern.count >= 2 && rawPattern.hasPrefix("\"") && rawPattern.hasSuffix("\"")
        _patternText = State(initialValue: isQuoted ? String(rawPattern.dropFirst().dropLast()) : rawPattern)
        _wholeWord = State(initialValue: isQuoted)
        _kind = State(initialValue: rule?.kind ?? .highlight)
        _matchField = State(initialValue: rule?.matchField ?? .any)
        _appScopeText = State(initialValue: rule?.appBundleId ?? "")
        _colorToken = State(initialValue: rule?.color.flatMap(HighlightColor.init(rawValue:)) ?? .amber)
        _priority = State(initialValue: rule?.priority ?? 0)
        _isEnabled = State(initialValue: rule?.isEnabled ?? true)
        _createdAt = State(initialValue: rule?.createdAt ?? UnixDate(Date()))
    }

    // MARK: Public

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existingID == nil
                ? String(localized: "Add Rule", comment: "Sheet title: creating a new notification rule")
                : String(localized: "Edit Rule", comment: "Sheet title: editing an existing notification rule"))
                .font(.title3.weight(.semibold))

            Form {
                kindPicker
                patternField
                if let compileError = model.compileError {
                    Text(compileError.message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("rules.editor.error")
                }
                matchFieldPicker
                if matchField != .app, kind != .regex {
                    Toggle(
                        String(localized: "Whole word only", comment: "Toggle: the pattern matches whole words only"),
                        isOn: $wholeWord
                    )
                    .accessibilityIdentifier("rules.editor.wholeWord")
                }
                appScopeField
                if kind == .highlight || kind == .regex {
                    colorPicker
                }
                Stepper(value: $priority, in: -100 ... 100) {
                    LabeledContent(
                        String(localized: "Priority", comment: "Rule priority; higher-priority rules win"),
                        value: priority,
                        format: .number
                    )
                }
                .accessibilityIdentifier("rules.editor.priority")
                Toggle(String(localized: "Enabled", comment: "Toggle: whether the rule is active"), isOn: $isEnabled)
                    .accessibilityIdentifier("rules.editor.enabled")
            }
            .formStyle(.grouped)

            previewSection

            buttons
        }
        .padding(20)
        .frame(width: 480, height: 600)
        .task { model.refreshPreview(for: buildDraft()) }
        .onChange(of: buildDraft()) { _, draft in model.refreshPreview(for: draft) }
    }

    // MARK: Private

    @Bindable private var model: RulesSettingsModel

    @State private var kind: Rule.Kind
    @State private var patternText: String
    @State private var matchField: Rule.MatchField
    @State private var appScopeText: String
    @State private var colorToken: HighlightColor
    @State private var wholeWord: Bool
    @State private var priority: Int
    @State private var isEnabled: Bool
    /// Fixed at the moment the sheet opened rather than recomputed from `Date()` on every
    /// call to ``buildDraft()`` — a value that changed every render would make
    /// `.onChange(of: buildDraft())` fire on every render too, restarting the debounce
    /// forever instead of only when a field actually changes.
    @State private var createdAt: UnixDate

    private let existingID: Int64?
    private let onClose: () -> Void

    private var trimmedPattern: String {
        patternText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var kindPicker: some View {
        Picker(String(localized: "Kind", comment: "Picker label: what type of rule this is"), selection: $kind) {
            Text(String(localized: "Highlight", comment: "Rule kind: highlights matches in colour"))
                .tag(Rule.Kind.highlight)
            Text(String(localized: "VIP", comment: "Rule kind: marks matches as important"))
                .tag(Rule.Kind.vip)
            Text(String(localized: "Mute", comment: "Rule kind: hides matches in Backglance only"))
                .tag(Rule.Kind.mute)
            Text(String(localized: "Regex", comment: "Rule kind: regular-expression pattern"))
                .tag(Rule.Kind.regex)
        }
        .accessibilityIdentifier("rules.editor.kind")
    }

    private var patternField: some View {
        TextField(
            String(localized: "Pattern", comment: "Text field label: the text or regex the rule matches"),
            text: $patternText,
            prompt: Text(verbatim: matchField == .app ? "com.example.app" : "invoice")
        )
        .accessibilityIdentifier("rules.editor.pattern")
    }

    private var matchFieldPicker: some View {
        Picker(
            String(localized: "Match", comment: "Picker label: which notification field the pattern applies to"),
            selection: $matchField
        ) {
            Text(String(localized: "Anywhere", comment: "Match-field option: match in any field"))
                .tag(Rule.MatchField.any)
            Text(String(localized: "Title", comment: "Match-field option: the notification’s title"))
                .tag(Rule.MatchField.title)
            Text(String(localized: "Body", comment: "Match-field option: the notification’s body text"))
                .tag(Rule.MatchField.body)
            Text(String(localized: "Sender", comment: "Match-field option: the notification’s sender"))
                .tag(Rule.MatchField.sender)
            Text(String(localized: "App bundle id", comment: "Match-field option: the app’s bundle identifier"))
                .tag(Rule.MatchField.app)
        }
        .accessibilityIdentifier("rules.editor.matchField")
    }

    /// Free text, matching `ExcludedAppsSettingsModel`'s own bundle-id field: the thing
    /// being named is a bundle identifier, not an installed application, so a picker over
    /// `NSWorkspace` would not list every app that can notify.
    private var appScopeField: some View {
        TextField(
            String(localized: "Only this app (optional)"),
            text: $appScopeText,
            prompt: Text(verbatim: "com.example.app")
        )
        .accessibilityIdentifier("rules.editor.appScope")
    }

    private var colorPicker: some View {
        Picker(String(localized: "Colour", comment: "Picker label: highlight colour"), selection: $colorToken) {
            ForEach(HighlightColor.allCases, id: \.self) { color in
                Label {
                    Text(Self.colorName(color))
                } icon: {
                    Circle().fill(color.swiftUIColor).frame(width: 10, height: 10)
                }
                .tag(color)
            }
        }
        .accessibilityIdentifier("rules.editor.color")
    }

    /// "The last 50 archived notifications" — docs/features/RULES.md#ui-components — is
    /// what makes a rule trustworthy before it is saved: no title or body reaches a log or
    /// an error string anywhere in this view, only the screen.
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Would have matched", comment: "Heading: preview of what the rule matches"))
                .font(.callout.weight(.semibold))

            if let previewError = model.previewError {
                Text(previewError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.preview.isEmpty {
                Text(String(localized: "Nothing in the last 50 notifications matches yet."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                List(model.preview) { row in
                    Text(row.title ?? row.body ?? String(
                        localized: "(no title)",
                        comment: "Placeholder: preview row for a notification without a title"
                    ))
                    .lineLimit(1)
                    .accessibilityIdentifier("rules.editor.preview.row.\(row.id ?? -1)")
                }
                .frame(height: 120)
                .accessibilityIdentifier("rules.editor.preview")
            }
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel"), role: .cancel) { onClose() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("rules.editor.cancel")
            Button(String(localized: "Save")) {
                Task {
                    if await model.save(buildDraft()) {
                        onClose()
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(trimmedPattern.isEmpty)
            .accessibilityIdentifier("rules.editor.save")
        }
    }

    private static func colorName(_ color: HighlightColor) -> String {
        switch color {
        case .amber: String(localized: "Amber", comment: "Colour name shown as a picker option")
        case .red: String(localized: "Red", comment: "Colour name shown as a picker option")
        case .green: String(localized: "Green", comment: "Colour name shown as a picker option")
        case .blue: String(localized: "Blue", comment: "Colour name shown as a picker option")
        case .purple: String(localized: "Purple", comment: "Colour name shown as a picker option")
        }
    }

    /// Turns the sheet's own `@State` into the `Rule` both ``RulesSettingsModel/refreshPreview(for:)``
    /// and ``RulesSettingsModel/save(_:)`` operate on. Whole-word wrapping happens here,
    /// once, so the model never has to know the editor represents it as a checkbox rather
    /// than literal quotes in the pattern text.
    private func buildDraft() -> Rule {
        var pattern = trimmedPattern
        if wholeWord, matchField != .app, kind != .regex, !pattern.isEmpty {
            pattern = "\"\(pattern)\""
        }
        let scope = appScopeText.trimmingCharacters(in: .whitespacesAndNewlines)
        return Rule(
            id: existingID,
            kind: kind,
            pattern: pattern,
            matchField: matchField,
            appBundleId: scope.isEmpty ? nil : scope,
            color: (kind == .highlight || kind == .regex) ? colorToken.rawValue : nil,
            priority: priority,
            isEnabled: isEnabled,
            createdAt: createdAt
        )
    }
}

// MARK: - Preview

#Preview {
    RuleEditorSheet(model: RulesSettingsModel(archive: nil, engine: nil), rule: nil) {}
}
