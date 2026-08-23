@testable import BackglanceUI
import Foundation
import XCTest

/// Covers `UpdatesSettingsModel`: the toggle writes through `UpdaterControl` rather than
/// holding a preference of its own, a manual check is relayed, and an unconfigured build is
/// reported as one instead of offering controls that could not work.
///
/// The pane never sees Sparkle — `BackglanceUI` cannot import it
/// (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction) — which is what lets
/// these run without a framework that would open a connection if it were started.
@MainActor
final class UpdatesSettingsModelTests: XCTestCase {
    // MARK: Internal

    /// The toggle is not a stored preference this model owns: flipping it calls through.
    func testFlippingTheToggleWritesThrough() {
        let recorder = Recorder(automatic: true)
        let model = UpdatesSettingsModel(updater: recorder.control, version: "1.0.0")

        XCTAssertTrue(model.automaticChecksEnabled)
        model.automaticChecksEnabled = false

        XCTAssertEqual(recorder.setCalls, [false])
        XCTAssertFalse(recorder.automatic)
    }

    /// Assigning the value it already has is not a write. Without this, `refresh()` would
    /// echo every read straight back through the control.
    func testAssigningTheSameValueWritesNothing() {
        let recorder = Recorder(automatic: true)
        let model = UpdatesSettingsModel(updater: recorder.control, version: "1.0.0")

        model.automaticChecksEnabled = true

        XCTAssertEqual(recorder.setCalls, [])
    }

    /// A change made elsewhere — the status-item menu starting a check — lands on the next
    /// appearance, and refreshing does not write the value back.
    func testRefreshReadsWithoutWritingBack() {
        let recorder = Recorder(automatic: true)
        let model = UpdatesSettingsModel(updater: recorder.control, version: "1.0.0")
        recorder.automatic = false
        recorder.canCheck = true

        model.refresh()

        XCTAssertFalse(model.automaticChecksEnabled)
        XCTAssertTrue(model.canCheckForUpdates)
        XCTAssertEqual(recorder.setCalls, [])
    }

    /// "Check for Updates…" is relayed as-is. Whether it is *allowed* is
    /// `UpdaterPolicy`'s call, one layer down, not this model's.
    func testCheckingForUpdatesIsRelayed() {
        let recorder = Recorder(automatic: false)
        let model = UpdatesSettingsModel(updater: recorder.control, version: "1.0.0")

        model.checkForUpdates()

        XCTAssertEqual(recorder.checkCalls, 1)
    }

    /// The default control is the state a preview or a build with no updater is in, and
    /// the pane has to report it rather than offer a toggle that does nothing.
    func testTheDefaultControlReportsAnUnconfiguredBuild() {
        let model = UpdatesSettingsModel(updater: UpdaterControl(), version: "1.0.0")

        XCTAssertFalse(model.isConfigured)
        XCTAssertFalse(model.canCheckForUpdates)
    }

    // MARK: Private

    /// A stand-in for the app shell's `SparkleUpdaterController`, recording what the pane
    /// asked of it.
    private final class Recorder {
        // MARK: Lifecycle

        init(automatic: Bool) {
            self.automatic = automatic
        }

        // MARK: Internal

        var automatic: Bool
        var canCheck = false
        var setCalls: [Bool] = []
        var checkCalls = 0

        var control: UpdaterControl {
            UpdaterControl(
                isConfigured: { true },
                readAutomaticChecks: { MainActor.assumeIsolated { self.automatic } },
                setAutomaticChecks: { enabled in
                    MainActor.assumeIsolated {
                        self.setCalls.append(enabled)
                        self.automatic = enabled
                    }
                },
                canCheckForUpdates: { MainActor.assumeIsolated { self.canCheck } },
                checkForUpdates: { MainActor.assumeIsolated { self.checkCalls += 1 } }
            )
        }
    }
}
