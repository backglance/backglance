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
            String(localized: "Running")

        case let .paused(until):
            until.map { String(localized: "Paused until \(PauseCopy.deadlineText(for: $0))") }
                ?? String(localized: "Paused")

        case .noFullDiskAccess:
            String(localized: "Degraded — needs Full Disk Access")

        case let .degraded(message):
            String(localized: "Degraded — \(message)")

        case .stopped:
            String(localized: "Not running")
        }
    }

    /// "2 minutes ago (14 records)". The count matters as much as the time: a tick that ran a
    /// minute ago and read nothing is a healthy quiet Mac, and one that has not run in a day
    /// is not.
    private var lastCaptureDescription: String {
        guard let lastTickAt = model.health.lastTickAt else {
            return String(localized: "Never this launch")
        }
        let when = lastTickAt.formatted(.relative(presentation: .named))
        return String(localized: "\(when) (^[\(model.health.lastTickRecords) record](inflect: true))")
    }

    private var fdaDescription: String {
        switch model.fdaState {
        case .granted: String(localized: "Granted")
        case .denied: String(localized: "Not granted")
        case .storeMissing: String(localized: "Granted — macOS has no notification database yet")
        }
    }

    private var archiveDescription: String {
        let size = Measurement(value: Double(model.summary.byteCount), unit: UnitInformationStorage.bytes)
            .formatted(.byteCount(style: .file))
        return String(localized: "\(size) · ^[\(model.summary.notificationCount) notification](inflect: true)")
    }

    /// "Not checked yet" is a different answer from "checked and fine", and a pane that showed
    /// a tick for the first would be lying about work it has not done.
    private var integrityDescription: String {
        guard let ok = model.summary.integrityOK else {
            return String(localized: "Not checked this launch")
        }
        let when = model.summary.checkedAt?.formatted(.relative(presentation: .named)) ?? ""
        return ok
            ? String(localized: "OK \(when)")
            : String(localized: "Failed \(when) — see the log")
    }

    private var captureSection: some View {
        Section {
            LabeledContent(String(localized: "Capture"), value: captureDescription)
                .accessibilityIdentifier("status.capture")

            LabeledContent(
                String(localized: "Adapter"),
                value: model.health.adapterID ?? String(localized: "None — capture isn’t reading")
            )
            .accessibilityIdentifier("status.adapter")

            // A digest of Apple's schema plus version numbers, never content
            // (docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md). It is the first thing worth
            // knowing when a macOS update breaks capture, and the first thing to quote.
            LabeledContent(
                String(localized: "Store fingerprint"),
                value: model.health.fingerprint ?? String(localized: "Not read yet")
            )
            .monospaced()
            .accessibilityIdentifier("status.fingerprint")

            LabeledContent(String(localized: "Last capture"), value: lastCaptureDescription)
                .accessibilityIdentifier("status.lastCapture")

            LabeledContent(String(localized: "Full Disk Access"), value: fdaDescription)
                .accessibilityIdentifier("status.fda")
        } header: {
            Text(String(localized: "Capture"))
        }
    }

    private var archiveSection: some View {
        Section {
            LabeledContent(String(localized: "Archive"), value: archiveDescription)
                .accessibilityIdentifier("status.archive")

            LabeledContent(String(localized: "Integrity"), value: integrityDescription)
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
            Text(String(localized: "Archive"))
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
            Toggle(String(localized: "Include app names"), isOn: $model.includeAppIdentifiers)
                .accessibilityIdentifier("status.diagnostics.includeApps")

            Button(String(localized: "Export Diagnostics…")) {
                Task { await model.exportDiagnostics() }
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("status.diagnostics.export")

            if let export = model.lastExport {
                LabeledContent(String(localized: "Saved"), value: export.lastPathComponent)
                    .accessibilityIdentifier("status.diagnostics.saved")
            }
        } header: {
            Text(String(localized: "Diagnostics"))
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
