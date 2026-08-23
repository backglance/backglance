import AppKit
import BackglanceCore
import SwiftUI

// MARK: - PrivacySettingsView

/// Settings ▸ Privacy: every control that decides what Backglance keeps.
///
/// One pane rather than five scattered ones, because the questions are the same question
/// asked at different points on the same path — what is never read (excluded apps), what is
/// changed before it is written (redaction), how long what was written survives (retention),
/// what is not being read right now (pause), and how to end all of it (wipe). Someone who
/// opens this pane is asking "what does this app have on me", and the answer should be in
/// one place.
///
/// The composed sections bring their own models and views; this file owns only the order
/// they appear in, the pause row, the redaction activity table and the wipe sheet.
///
/// See docs/features/PRIVACY_CONTROLS.md#ui-components.
public struct PrivacySettingsView: View {
    // MARK: Lifecycle

    public init(model: PrivacySettingsModel) {
        self.model = model
    }

    // MARK: Public

    public var body: some View {
        Form {
            RetentionSettingsView(model: model.retention)
            ExcludedAppsSettingsView(model: model.exclusions)
            CodeRedactionSettingsView(model: model.redaction)
            redactionActivitySection
            pauseSection
            archiveSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingWipeSheet) {
            WipeConfirmationSheet(model: model.wipe) { isShowingWipeSheet = false }
        }
        .task { await model.load() }
    }

    // MARK: Private

    @Bindable private var model: PrivacySettingsModel

    @State private var isShowingWipeSheet = false

    private var pauseDescription: String {
        switch model.pauseState {
        case .notPaused:
            String(localized: "Running", comment: "Status label: notification capture is running")

        case .indefinite:
            String(localized: "Paused", comment: "Status label: capture is paused indefinitely")

        case let .until(date):
            String(
                localized: "Paused until \(PauseCopy.deadlineText(for: date))",
                comment: "Status label; placeholder is when the pause ends"
            )
        }
    }

    /// 🔒 Counts and app names. There is nothing else to show — `redactions` never stored
    /// the text it replaced — and saying so in the footer is the point of the table as much
    /// as the numbers are.
    private var redactionActivitySection: some View {
        Section {
            if model.hasActivity {
                ForEach(model.activity) { row in
                    LabeledContent(row.name) {
                        Text(row.count, format: .number)
                            .monospacedDigit()
                    }
                    .accessibilityLabel(Text(
                        String(
                            localized: "\(row.name), \(row.count) codes redacted in the last 30 days",
                            comment: "VoiceOver label; placeholders are the app's name and a count"
                        )
                    ))
                }
            } else {
                Text(String(localized: "Nothing has looked like a one-time code in the last 30 days."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: "Redaction activity", comment: "Section header: codes redacted per app"))
        } footer: {
            Text(String(localized: """
            How many codes were replaced, by app, over the last 30 days. Backglance cannot show \
            the codes themselves — it never stored them.
            """))
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("privacy.redactionActivity")
    }

    private var pauseSection: some View {
        Section {
            LabeledContent(String(localized: "Capture", comment: "Notification capture (noun)")) {
                HStack(spacing: 8) {
                    Text(pauseDescription)
                        .foregroundStyle(model.pauseState.isPaused ? .primary : .secondary)
                    if model.pauseState.isPaused {
                        Button(String(localized: "Resume", comment: "Button: resume notification capture")) {
                            Task { await model.resume() }
                        }
                        .accessibilityIdentifier("privacy.pause.resume")
                    }
                }
            }

            Toggle(
                String(localized: "Import notifications received while paused"),
                isOn: $model.importWhilePaused
            )
            .accessibilityIdentifier("privacy.pause.importWhilePaused")
        } header: {
            Text(String(localized: "Pause", comment: "Section header: pausing capture (noun)"))
        } footer: {
            Text(String(localized: """
            When off, notifications that arrive during a pause are never archived, even though \
            macOS still has them. Turning it on makes a pause a delay instead of a gap.
            """))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Reveal sits next to Wipe deliberately. The sheet says a wipe cannot reach Time
    /// Machine, and the honest follow-up — excluding the folder from backups — needs the
    /// folder.
    private var archiveSection: some View {
        Section {
            Button(String(localized: "Reveal Archive in Finder", comment: "Button; Finder's 'Reveal' wording")) {
                guard let directory = model.archiveDirectory else {
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            }
            .disabled(model.archiveDirectory == nil)
            .accessibilityIdentifier("privacy.archive.reveal")

            Button(
                String(localized: "Wipe Archive…", comment: "Destructive button: opens the wipe confirmation"),
                role: .destructive
            ) {
                model.wipe.reset()
                isShowingWipeSheet = true
            }
            .accessibilityIdentifier("privacy.archive.wipe")
        } header: {
            Text(String(localized: "Archive", comment: "Section header: the notification archive (noun)"))
        } footer: {
            Text(String(localized: """
            Wiping deletes every notification Backglance has stored and starts over. \
            It can’t be undone, and it can’t reach macOS’s own notification store or your backups.
            """))
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
