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
/// See docs/operations/MONITORING_LOGGING.md#health-indicators-in-the-ui.
public struct StatusSettingsView: View {
    // MARK: Lifecycle

    public init(model: StatusSettingsModel) {
        self.model = model
    }

    // MARK: Public

    public var body: some View {
        Form {
            captureSection
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
