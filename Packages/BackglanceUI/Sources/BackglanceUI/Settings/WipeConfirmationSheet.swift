import BackglanceCore
import SwiftUI

// MARK: - WipeConfirmationSheet

/// The sheet that stands between a click and losing everything.
///
/// Deliberately slow to get through. A destructive action reached from a settings pane has
/// to be hard to trigger by accident, and the two things that make it so are both here: a
/// word to type, and — where the hardware offers it — a finger. Neither is theatre. The
/// typed word is the only gate on a Mac without Touch ID, which is why the sheet says so
/// rather than letting someone assume a protection they do not have.
///
/// The list of what a wipe does *not* reach is shown before the field, not after it. It is
/// the part most likely to change someone's mind — a wipe cannot make Time Machine, Apple's
/// own store, or the sender forget — and burying it under a confirmation would be a way of
/// technically having said it.
///
/// See docs/features/PRIVACY_CONTROLS.md#confirmation.
public struct WipeConfirmationSheet: View {
    // MARK: Lifecycle

    public init(model: WipeConfirmationModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    // MARK: Public

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            notAffectedList
            Divider()
            confirmationField
            Toggle(
                String(
                    localized: "Also forget per-app settings",
                    comment: "Toggle: the wipe also clears per-app exclusions, retention and redaction settings"
                ),
                isOn: $model.forgetPerAppSettings
            )
            .accessibilityIdentifier("privacy.wipe.forgetSettings")
            gateNote
            if let failure = model.failure {
                Label(failure.userMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("privacy.wipe.failure")
            }
            buttons
        }
        .padding(20)
        .frame(width: 440)
        .onChange(of: model.didWipe) { _, didWipe in
            if didWipe, model.failure == nil {
                onClose()
            }
        }
    }

    // MARK: Private

    /// What a wipe cannot reach. Shown verbatim from
    /// docs/features/PRIVACY_CONTROLS.md#what-the-wipe-does-not-do, because a promise the
    /// app cannot keep is worse than one it never made.
    private static let notAffected: [(icon: String, text: String)] = [
        (
            "bell.badge",
            String(localized: "Notification Center keeps whatever macOS keeps. That store isn’t Backglance’s.")
        ),
        ("externaldrive.badge.timemachine", String(localized: "Backups made before now still contain the archive.")),
        ("clock.arrow.circlepath", String(localized: "macOS may hold local snapshots for up to 24 hours.")),
        ("square.and.arrow.up", String(localized: "Exports you already saved stay where you put them.")),
        ("gearshape", String(localized: "Your settings are kept. They aren’t notification content.")),
    ]

    @Bindable private var model: WipeConfirmationModel

    private let onClose: () -> Void

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Wipe the archive?"))
                .font(.title3.weight(.semibold))
            Text(String(localized: """
            Every notification Backglance has stored is deleted, along with its search index, \
            digests, cached icons and away sessions. This can’t be undone.
            """))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var notAffectedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "What this doesn’t reach", comment: "Heading: data the wipe does not delete"))
                .font(.callout.weight(.semibold))
            ForEach(Self.notAffected, id: \.text) { item in
                Label(item.text, systemImage: item.icon)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("privacy.wipe.notAffected")
    }

    private var confirmationField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(
                localized: "Type “wipe” to confirm",
                comment: "Instruction: keep “wipe” untranslated — the app checks typed text against that word"
            ))
            .font(.callout)
            TextField(
                String(localized: "Confirmation", comment: "Text field label: where the confirmation word is typed"),
                text: $model.typed,
                prompt: Text(verbatim: WipeConfirmationModel.confirmationWord)
            )
            .textFieldStyle(.roundedBorder)
            .disabled(model.isBusy)
            .accessibilityIdentifier("privacy.wipe.confirmField")
            .onSubmit {
                guard model.canWipe else {
                    return
                }
                Task { await model.confirm() }
            }
        }
    }

    /// Which gates this Mac actually applies. Said out loud in both directions: someone on a
    /// Mac without Touch ID should know the typed word is all that stands there.
    private var gateNote: some View {
        Text(model.asksForBiometrics
            ? String(localized: "Backglance will ask for Touch ID before deleting anything.")
            : String(localized: "This Mac has no Touch ID, so the typed word is the only confirmation."))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var buttons: some View {
        HStack {
            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "Wiping…", comment: "Progress label: the archive is being erased"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "Cancel"), role: .cancel) { onClose() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isBusy)
                .accessibilityIdentifier("privacy.wipe.cancel")
            Button(
                String(localized: "Wipe Archive", comment: "Button: permanently erases the archive"),
                role: .destructive
            ) {
                Task { await model.confirm() }
            }
            .disabled(!model.canWipe)
            .accessibilityIdentifier("privacy.wipe.confirm")
        }
    }
}

#Preview {
    WipeConfirmationSheet(model: WipeConfirmationModel(archive: nil)) {}
}
