import BackglanceCapture
import BackglanceUI

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

    /// Pushes the engine's status into the store as the UI's own value type.
    ///
    /// The UI never imports `BackglanceCapture`
    /// (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction), so the
    /// translation happens here, in the one place that already knows both
    /// sides. It is a small enum-to-enum map rather than a shared type because
    /// the views need far less than the engine publishes: enough to pick an
    /// icon, an empty state and one sentence.
    func mirrorCaptureStatus(into store: TimelineStore) {
        guard let engine else {
            return
        }
        statusMirror?.cancel()
        let stream = engine.statusStream
        statusMirror = Task { @MainActor in
            for await status in stream {
                store.captureState = Self.timelineState(for: status)
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
}
