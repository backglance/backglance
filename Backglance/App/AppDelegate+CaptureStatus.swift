import AppKit
import BackglanceCapture
import BackglanceCore
import BackglanceUI
import UniformTypeIdentifiers

// MARK: - AppDelegate + capture status

extension AppDelegate {
    /// One banner model for both surfaces.
    ///
    /// The popover and the window show the same banner about the same condition, so
    /// dismissing it once has to be enough — and every button on it needs something the UI
    /// layer cannot reach: System Settings, the probe, setup, the engine.
    func makeBannerModel() -> CaptureBannerModel {
        CaptureBannerModel(
            openSystemSettings: { SystemSettingsLinks.openFullDiskAccess() },
            checkAgain: { [weak self] in self?.monitor?.checkNow() },
            learnWhy: { [weak self] in self?.showOnboarding() },
            resumeCapture: { [weak self] in
                guard let engine = self?.engine else {
                    return
                }
                Task { await engine.resume() }
            }
        )
    }

    /// Pushes the engine's status into every live timeline store as the UI's own value
    /// type.
    ///
    /// The UI never imports `BackglanceCapture`
    /// (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction), so the
    /// translation happens here, in the one place that already knows both
    /// sides. It is a small enum-to-enum map rather than a shared type because
    /// the views need far less than the engine publishes: enough to pick an
    /// icon, an empty state and one sentence.
    ///
    /// Takes no store, and reads `store`/`windowStore` off `self` on each value instead,
    /// because the two surfaces no longer share one store and the window's is built only
    /// when it is first opened (BACKGLANCE-243). A parameter would have to be either the
    /// popover's — leaving the window's banner frozen at whatever it was born with — or a
    /// second call, and this method cancels the previous mirror task, so a second call
    /// would silently unhook the first store rather than add to it. `lastCaptureState` is
    /// what the late-built store is seeded from; see `showTimelineWindow()`.
    func mirrorCaptureStatus() {
        guard let engine else {
            return
        }
        statusMirror?.cancel()
        let stream = engine.statusStream
        statusMirror = Task { @MainActor [weak self] in
            for await status in stream {
                guard let self else {
                    return
                }
                let state = Self.timelineState(for: status)
                lastCaptureState = state
                store?.captureState = state
                windowStore?.captureState = state
            }
        }
    }

    static func timelineState(for status: CaptureStatus) -> TimelineCaptureState {
        switch status {
        case .running:
            .running

        case let .paused(until):
            .paused(until: until)

        case .degraded(.noFullDiskAccess):
            .noFullDiskAccess

        case let .degraded(reason):
            .degraded(message: reason.userMessage)

        case .stopped:
            .stopped
        }
    }

    /// The Status pane's model.
    ///
    /// Everything it shows about capture comes through one mirror of the engine's status and
    /// metrics, and everything it shows about the archive comes from the archive — which is
    /// exactly the split ``BackglanceCore/DiagnosticsExport`` uses, so what the user reads
    /// here is what the maintainer receives.
    func makeStatusModel(archive: Archive) -> StatusSettingsModel {
        StatusSettingsModel(
            archive: archive,
            readCaptureHealth: { [weak self] in
                guard let engine = await MainActor.run(body: { self?.engine }) else {
                    return CaptureHealth()
                }
                let metrics = await engine.metrics
                let adapterID = await engine.adapterID
                let fingerprint = try? archive.captureState(.fingerprint)
                return await CaptureHealth(
                    status: Self.timelineState(for: engine.status),
                    adapterID: adapterID,
                    fingerprint: fingerprint.map { String($0.prefix(16)) },
                    lastTickAt: metrics.lastTickAt,
                    lastTickRecords: metrics.totals.read
                )
            },
            readFullDiskAccess: { [weak self] in
                MainActor.assumeIsolated { Self.displayState(self?.monitor?.state ?? .denied) }
            },
            saveDiagnostics: { [weak self] options in
                await MainActor.run { self?.saveDiagnostics(archive: archive, options: options) }
            },
            runImport: { [weak self] report in
                await self?.runImport(reporting: report) ?? .failed
            }
        )
    }

    /// The system-store import, on demand from Settings ▸ Status.
    ///
    /// The same call `OnboardingWindowController` makes on the last setup screen, translated
    /// the same way: the engine's `ImportProgress` and `ImportSummary` become the `ImportState`
    /// the UI draws, because `BackglanceUI` cannot see `BackglanceCapture`.
    ///
    /// Failure is reported, not thrown. Nothing here is fatal — live capture is unaffected,
    /// whatever was archived stays, and the pane says the import did not finish rather than
    /// leaving a spinner running (BACKGLANCE-262).
    @MainActor
    private func runImport(
        reporting report: @escaping @MainActor @Sendable (ImportState) -> Void
    ) async -> ImportState {
        guard let engine else {
            return .failed
        }
        do {
            let summary = try await engine.importExisting { progress in
                await MainActor.run {
                    report(.running(archived: progress.archived, expectedTotal: progress.expectedTotal))
                }
            }
            return .finished(archived: summary.archived)
        } catch {
            // Content-free by construction, like every other line the app logs: a
            // `CaptureError`'s own description, or the failure's type and nothing else.
            let detail = (error as? CaptureError)?.logDescription ?? String(describing: type(of: error))
            Log.capture.error("settings import failed: \(detail)")
            return .failed
        }
    }

    /// Builds the bundle, then asks where to put it.
    ///
    /// In that order deliberately: the files exist in memory before any panel appears, so the
    /// user is choosing a destination for something already assembled rather than authorising
    /// a build they cannot inspect. Nothing is written until they pick.
    @MainActor
    private func saveDiagnostics(archive: Archive, options: DiagnosticsExport.Options) -> URL? {
        do {
            let files = try DiagnosticsExport.build(archive: archive, options: options)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Backglance-Diagnostics.zip"
            panel.allowedContentTypes = [UTType.zip]
            panel.message = String(localized: "A zip of versions, capture state and counts. No notification text.")
            guard panel.runModal() == .OK, let destination = panel.url else {
                return nil
            }
            let zip = try DiagnosticsExport.write(files)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: zip, to: destination)
            return destination
        } catch {
            // Through the redacting logger, like every other line in the app: the detail is an
            // `ArchiveError`'s content-free description, and there is no second path that
            // could be handed something richer.
            let detail = (error as? ArchiveError)?.logDescription ?? ArchiveError.detail(from: error)
            Log.archive.error("diagnostics export failed: \(detail)")
            return nil
        }
    }
}
