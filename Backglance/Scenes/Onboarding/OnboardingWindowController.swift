import AppKit
import BackglanceCapture
import BackglanceUI
import SwiftUI

// MARK: - OnboardingWindowController

/// The setup window, and everything that connects it to the parts it cannot import.
///
/// `OnboardingModel` deals in mirrored value types and closures so that `BackglanceUI` stays
/// clear of the capture layer; this is where those closures are filled in with the real
/// probe, the real engine and the real System Settings URL. It is also where the polling
/// brackets live: the monitor's thirty-second timer starts when this window appears and stops
/// when it closes, which is the whole of "only while onboarding is visible".
///
/// Not `NSWindowController(window:)`-and-forget: the window is retained here and reused, so
/// "Show setup again" from the Permissions pane reopens the same one rather than stacking a
/// second copy behind the first.
///
/// See docs/features/PERMISSIONS_PRIVACY.md#onboarding-flow.
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - monitor: the probe and its cadence. This controller drives its polling and
    ///     forwards every answer into the model.
    ///   - engine: what runs the first-launch import. `nil` when the archive would not open,
    ///     which leaves the last screen saying the import did not run rather than hanging.
    ///   - defaults: where "setup is done" is recorded.
    convenience init(
        monitor: FullDiskAccessMonitor,
        engine: CaptureEngine?,
        defaults: UserDefaults = .standard
    ) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: OnboardingView.windowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Welcome to Backglance")
        window.isReleasedWhenClosed = false
        window.center()

        let model = OnboardingModel(
            fdaState: Self.displayState(monitor.state),
            openSystemSettings: { SystemSettingsLinks.openFullDiskAccess() },
            checkAccessAgain: { [weak monitor] in monitor?.checkNow() },
            defaults: defaults
        )

        self.init(window: window)
        self.monitor = monitor
        self.engine = engine
        self.model = model

        // Filled in after `self` exists, because each needs it. The import and the close both
        // belong to the controller: one owns the engine, the other owns the window.
        model.onStartImport = { [weak self] in self?.runImport() }
        model.onFinish = { [weak self] in self?.close() }
        monitor.onChange = { [weak model] state in
            model?.fullDiskAccessChanged(to: Self.displayState(state))
        }

        let hosting = NSHostingController(rootView: OnboardingView(model: model))
        // Setup is a fixed size; every screen is written to fit it, and a resizable window
        // would let someone shrink the Grant instructions out of view.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(OnboardingView.windowSize)
        window.delegate = self
    }

    // MARK: Internal

    /// Shows setup, and starts the fallback poll.
    ///
    /// An agent app is never frontmost on its own, so a setup window that did not activate
    /// would open behind whatever the user was doing — which for a first launch means behind
    /// the Applications folder they just dragged the app out of.
    func show() {
        model?.fullDiskAccessChanged(to: Self.displayState(monitor?.checkNow() ?? .denied))
        monitor?.startPolling()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closing the window ends setup, however it was closed.
    ///
    /// The red button is a legitimate way out — the same one "Skip for now" takes — so it
    /// records the same thing. A window that could be dismissed without recording anything
    /// would reopen on the next launch, which reads as the app not listening.
    func windowWillClose(_: Notification) {
        monitor?.stopPolling()
        model?.skipIfUnfinished()
    }

    // MARK: Private

    private var monitor: FullDiskAccessMonitor?
    private var engine: CaptureEngine?
    private var model: OnboardingModel?

    private static func displayState(_ state: FullDiskAccessState) -> FullDiskAccessDisplayState {
        switch state {
        case .granted: .granted
        case .denied: .denied
        case .storeMissing: .storeMissing
        }
    }

    /// Runs the first-launch import, reporting into the last screen.
    ///
    /// Failure is not fatal to setup. Live capture is unaffected and whatever was written
    /// stays, so the screen says the older notifications could not be imported and setup
    /// finishes normally.
    private func runImport() {
        guard let engine, let model else {
            return
        }
        Task { @MainActor in
            model.importProgressChanged(to: .running(archived: 0, expectedTotal: nil))
            do {
                let summary = try await engine.importExisting { progress in
                    await MainActor.run {
                        model.importProgressChanged(
                            to: .running(archived: progress.archived, expectedTotal: progress.expectedTotal)
                        )
                    }
                }
                model.importProgressChanged(to: .finished(archived: summary.archived))
            } catch {
                model.importProgressChanged(to: .failed)
            }
        }
    }
}
