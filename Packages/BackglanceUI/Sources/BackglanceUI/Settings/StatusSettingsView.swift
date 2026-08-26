import BackglanceCore
import SwiftUI

// MARK: - StatusSettingsView

/// Settings ▸ Status: is this working, and if not, what would you need to know.
///
/// Capture fails silently by nature. Nothing arrives to tell a user that a macOS update
/// changed the store's schema — the timeline just stops growing, and weeks can pass before
/// anyone notices something is missing. This pane is where the answer lives, in the plainest
/// words available, next to the button that packages it for someone who can help.
///
/// It is also the only place outside setup that can run the system-store import
/// (BACKGLANCE-262). That is deliberate rather than tidy: someone who skipped the import
/// during onboarding, or granted Full Disk Access days later, has notifications sitting in
/// Apple's store that no other part of the app will ever reach back for — and the question
/// they arrive with, "is anything missing", is the question this pane already answers.
///
/// See docs/operations/MONITORING_LOGGING.md#health-indicators-in-the-ui and
/// docs/features/CAPTURE.md#the-system-store-import.
public struct StatusSettingsView: View {
    // MARK: Lifecycle

    public init(model: StatusSettingsModel) {
        self.model = model
    }

    // MARK: Public

    public var body: some View {
        Form {
            captureSection
            importSection
            archiveSection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .task { await model.load() }
    }

    // MARK: Private

    @Bindable private var model: StatusSettingsModel

    private var captureDescription: String {
        switch model.health.status {
        case .running:
            String(localized: "Running", comment: "Status value: capture is running")

        case let .paused(.some(until)):
            String(
                localized: "Paused until \(PauseCopy.deadlineText(for: until))",
                comment: "Status value: the placeholder is the time capture will resume"
            )

        case .paused(nil):
            String(localized: "Paused", comment: "Status value: capture is paused with no end time")

        case .noFullDiskAccess:
            String(localized: "Degraded — needs Full Disk Access")

        case let .degraded(message):
            String(
                localized: "Degraded — \(message)",
                comment: "Status value: the placeholder is a short reason capture stopped"
            )

        case .stopped:
            String(localized: "Not running", comment: "Status value: capture never started")
        }
    }

    /// "2 minutes ago (14 records)". The count matters as much as the time: a tick that ran a
    /// minute ago and read nothing is a healthy quiet Mac, and one that has not run in a day
    /// is not.
    private var lastCaptureDescription: String {
        guard let lastTickAt = model.health.lastTickAt else {
            return String(
                localized: "Never this launch",
                comment: "Status value: no capture pass has run since the app started"
            )
        }
        let when = lastTickAt.formatted(.relative(presentation: .named))
        return String(
            localized: "\(when) (\(model.health.lastTickRecords) records)",
            comment: "Status value: when capture last ran, then how many records that pass read"
        )
    }

    private var fdaDescription: String {
        switch model.fdaState {
        case .granted: String(localized: "Granted", comment: "Status value: Full Disk Access is granted")
        case .denied: String(localized: "Not granted", comment: "Status value: Full Disk Access is not granted")
        case .storeMissing: String(localized: "Granted — macOS has no notification database yet")
        }
    }

    private var archiveDescription: String {
        let size = Measurement(value: Double(model.summary.byteCount), unit: UnitInformationStorage.bytes)
            .formatted(.byteCount(style: .file))
        return String(
            localized: "\(size) · \(model.summary.notificationCount) notifications",
            comment: "Status value: the archive’s file size, then its notification count"
        )
    }

    /// "Not checked yet" is a different answer from "checked and fine", and a pane that showed
    /// a tick for the first would be lying about work it has not done.
    private var integrityDescription: String {
        guard let ok = model.summary.integrityOK else {
            return String(
                localized: "Not checked this launch",
                comment: "Status value: no integrity check has run since the app started"
            )
        }
        let when = model.summary.checkedAt?.formatted(.relative(presentation: .named)) ?? ""
        return ok
            ? String(localized: "OK \(when)", comment: "Status value: check passed; placeholder is a relative time")
            : String(
                localized: "Failed \(when) — see the log",
                comment: "Status value: check failed; placeholder is a relative time"
            )
    }

    /// "3 days ago", or "Never". The second answer is the one that matters: a user who
    /// skipped the import during setup has notifications sitting in Apple's store that
    /// nothing else in the app will ever reach back for, and this row is where they find out.
    private var lastImportDescription: String {
        guard let lastImportAt = model.lastImportAt else {
            return String(
                localized: "Never",
                comment: "Status value: no import from the system store has ever finished"
            )
        }
        return lastImportAt.formatted(.relative(presentation: .named))
    }

    /// Why the button is unavailable, when it is and the reason is not simply that an import
    /// is already under way. A disabled control with no explanation reads as a broken one.
    private var importUnavailableReason: String? {
        guard !model.canImportFromStore, !model.importState.isRunning else {
            return nil
        }
        switch model.health.status {
        case .running:
            return nil

        case .paused:
            return String(
                localized: """
                Capture is paused. Resume it first — an import reads every notification the \
                system still has, which is the one thing pausing is for.
                """,
                comment: "Why the import button is unavailable: the user paused capture"
            )

        default:
            return String(
                localized: "Capture isn’t reading the system store, so there is nothing to import from.",
                comment: "Why the import button is unavailable: capture is degraded or not running"
            )
        }
    }

    private var captureSection: some View {
        Section {
            LabeledContent(
                String(localized: "Capture", comment: "Label and section header: the notification-capture subsystem"),
                value: captureDescription
            )
            .accessibilityIdentifier("status.capture")

            LabeledContent(
                String(localized: "Adapter", comment: "Label: which store adapter capture is using"),
                value: model.health.adapterID ?? String(
                    localized: "None — capture isn’t reading",
                    comment: "Status value: shown when no store adapter is active"
                )
            )
            .accessibilityIdentifier("status.adapter")

            // A digest of Apple's schema plus version numbers, never content
            // (docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md). It is the first thing worth
            // knowing when a macOS update breaks capture, and the first thing to quote.
            LabeledContent(
                String(localized: "Store fingerprint", comment: "Label: schema fingerprint of the system store"),
                value: model.health.fingerprint ?? String(
                    localized: "Not read yet",
                    comment: "Status value: the store hasn’t been read yet"
                )
            )
            .monospaced()
            .accessibilityIdentifier("status.fingerprint")

            LabeledContent(
                String(localized: "Last capture", comment: "Label: when capture last read the store"),
                value: lastCaptureDescription
            )
            .accessibilityIdentifier("status.lastCapture")

            LabeledContent(
                String(
                    localized: "Full Disk Access",
                    comment: "Label: use Apple’s localized name for the Full Disk Access permission"
                ),
                value: fdaDescription
            )
            .accessibilityIdentifier("status.fda")
        } header: {
            Text(String(localized: "Capture", comment: "Label and section header: the notification-capture subsystem"))
        }
    }

    private var importSection: some View {
        Section {
            LabeledContent(
                String(localized: "Last import", comment: "Label: when the system-store import last finished"),
                value: lastImportDescription
            )
            .accessibilityIdentifier("status.import.last")

            Button(String(
                localized: "Import from the System Store Now",
                comment: "Button: archives whatever macOS’s own notification store still holds"
            )) {
                Task { await model.importFromStore() }
            }
            .disabled(!model.canImportFromStore)
            .accessibilityIdentifier("status.import.run")

            if model.importState != .idle {
                ImportProgressView(progress: model.importState, identifierPrefix: "status")
            }

            if let reason = importUnavailableReason {
                Label(reason, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("status.import.unavailable")
            }
        } header: {
            Text(String(localized: "Import", comment: "Section header: the on-demand system-store import"))
        } footer: {
            Text(String(
                localized: """
                macOS keeps only a few days of notifications and prunes the rest. Backglance \
                archives new ones as they arrive; this reaches back for whatever the system still \
                has — the same import setup offers, for anyone who skipped it or granted access \
                later. Nothing is imported unless you ask, and asking twice is safe: anything \
                already archived is skipped.
                """,
                comment: "Footer under the import button: what the import can and cannot recover"
            ))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var archiveSection: some View {
        Section {
            LabeledContent(
                String(localized: "Archive", comment: "Label and section header: Backglance’s notification archive"),
                value: archiveDescription
            )
            .accessibilityIdentifier("status.archive")

            LabeledContent(
                String(localized: "Integrity", comment: "Label: result of the archive integrity check"),
                value: integrityDescription
            )
            .accessibilityIdentifier("status.integrity")

            Button(String(localized: "Run Integrity Check")) {
                Task { await model.runIntegrityCheck() }
            }
            .disabled(!model.canRunChecks)
            .accessibilityIdentifier("status.integrity.run")

            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: "Archive", comment: "Label and section header: Backglance’s notification archive"))
        } footer: {
            Text(String(localized: """
            The integrity check reads the whole file, so it isn’t run automatically — on a large \
            archive it takes a moment.
            """))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var diagnosticsSection: some View {
        Section {
            Toggle(
                String(localized: "Include app names", comment: "Toggle: include app names in the diagnostics export"),
                isOn: $model.includeAppIdentifiers
            )
            .accessibilityIdentifier("status.diagnostics.includeApps")

            Button(String(localized: "Export Diagnostics…")) {
                Task { await model.exportDiagnostics() }
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("status.diagnostics.export")

            if let export = model.lastExport {
                LabeledContent(
                    String(localized: "Saved", comment: "Label: file name of the last diagnostics export"),
                    value: export.lastPathComponent
                )
                .accessibilityIdentifier("status.diagnostics.saved")
            }
        } header: {
            Text(String(localized: "Diagnostics", comment: "Section header: the diagnostics export"))
        } footer: {
            Text(String(localized: """
            A zip of versions, capture state and counts — no notification text, ever. Open it before \
            you send it; it is plain JSON. App names are left out unless you turn them on above, \
            because which apps notify you is itself personal.
            """))
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    StatusSettingsView(model: StatusSettingsModel(archive: nil))
        .frame(width: 480, height: 480)
}
