@testable import BackglanceUI
import Foundation
import XCTest

/// Covers `GeneralSettingsModel`: launch at login flips through `LaunchAtLoginControl`
/// rather than writing state directly, the hotkey note reflects `HotKeyControl`, and the
/// Search section reads and writes through `SemanticSearchControl` — never `SearchService`
/// itself, which this package cannot see
/// (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction).
///
/// See docs/features/PERMISSIONS_PRIVACY.md#launch-at-login.
@MainActor
final class GeneralSettingsModelTests: XCTestCase {
    // MARK: Internal

    // MARK: - Launch at login

    /// The common path: registering succeeds outright, and the toggle stays on.
    func testTurningLaunchAtLoginOnRegisters() {
        var calls: [Bool] = []
        let model = makeModel(launchAtLogin: LaunchAtLoginControl(
            readStatus: { .notRegistered },
            setEnabled: { enabled in
                calls.append(enabled)
                return .success(.registered)
            }
        ))

        model.launchAtLoginEnabled = true

        XCTAssertEqual(calls, [true])
        XCTAssertEqual(model.loginItemStatus, .registered)
        XCTAssertNil(model.launchAtLoginFailure)
        XCTAssertTrue(model.launchAtLoginEnabled)
    }

    /// `.requiresApproval` is not a failure — the write went through, macOS is only
    /// waiting on the user's own approval — so the toggle stays visually on rather than
    /// snapping back to off under someone who just turned it on.
    func testRequiresApprovalLeavesTheToggleOn() {
        let model = makeModel(launchAtLogin: LaunchAtLoginControl(
            readStatus: { .notRegistered },
            setEnabled: { _ in .success(.requiresApproval) }
        ))

        model.launchAtLoginEnabled = true

        XCTAssertEqual(model.loginItemStatus, .requiresApproval)
        XCTAssertTrue(model.launchAtLoginEnabled, "requiresApproval reads as on, not off")
        XCTAssertNil(model.launchAtLoginFailure)
    }

    /// A thrown `SMAppService` error becomes a message the pane can show, and the toggle is
    /// put back to whatever `SMAppService` actually reports — never left showing a state
    /// the write never reached.
    func testAFailedRegistrationSnapsTheToggleBackAndReportsWhy() {
        let model = makeModel(launchAtLogin: LaunchAtLoginControl(
            readStatus: { .notRegistered },
            setEnabled: { _ in .failure("Backglance couldn’t change this: not a valid app bundle.") }
        ))

        model.launchAtLoginEnabled = true

        XCTAssertFalse(model.launchAtLoginEnabled)
        XCTAssertEqual(model.launchAtLoginFailure, "Backglance couldn’t change this: not a valid app bundle.")
    }

    /// Setting the toggle to the value it already holds must not call `setEnabled` again —
    /// the same `didSet`-guards-on-equality contract every other settings model in this
    /// package keeps.
    func testSettingLaunchAtLoginToItsOwnValueDoesNotWriteAgain() {
        var callCount = 0
        let model = makeModel(launchAtLogin: LaunchAtLoginControl(
            readStatus: { .registered },
            setEnabled: { _ in
                callCount += 1
                return .success(.registered)
            }
        ))

        model.launchAtLoginEnabled = true

        XCTAssertEqual(callCount, 0)
    }

    /// `refresh()` re-reads the live status without writing anything — the read/write split
    /// every other injected-closure model in this package keeps.
    func testRefreshReReadsWithoutWriting() {
        var writeCount = 0
        var currentStatus = LoginItemStatus.notRegistered
        let model = makeModel(launchAtLogin: LaunchAtLoginControl(
            readStatus: { currentStatus },
            setEnabled: { _ in
                writeCount += 1
                return .success(.registered)
            }
        ))

        currentStatus = .requiresApproval
        model.refresh()

        XCTAssertEqual(model.loginItemStatus, .requiresApproval)
        XCTAssertTrue(model.launchAtLoginEnabled)
        XCTAssertEqual(writeCount, 0)
    }

    // MARK: - The hot key note

    func testHotKeyStatusIsReadAtInitAndOnRefresh() {
        var isRegistered = false
        let model = makeModel(hotKey: HotKeyControl(isRegistered: { isRegistered }, retry: { false }))

        XCTAssertFalse(model.isHotKeyRegistered)

        isRegistered = true
        model.refresh()

        XCTAssertTrue(model.isHotKeyRegistered)
    }

    func testRetryingCallsRetryAndAdoptsWhatComesBack() {
        var retried = false
        let model = makeModel(hotKey: HotKeyControl(
            isRegistered: { false },
            retry: {
                retried = true
                return true
            }
        ))

        model.retryHotKeyRegistration()

        XCTAssertTrue(retried)
        XCTAssertTrue(model.isHotKeyRegistered)
    }

    // MARK: - Search

    func testSearchStateIsReadAtInit() {
        let model = makeModel(search: SemanticSearchControl(
            isAvailable: { true },
            isEnabled: { true },
            progress: { (done: 10, total: 100) }
        ))

        XCTAssertTrue(model.isSemanticAvailable)
        XCTAssertTrue(model.semanticEnabled)
        XCTAssertEqual(model.indexProgress?.done, 10)
        XCTAssertEqual(model.indexProgress?.total, 100)
    }

    /// Turning the toggle on calls through to `SearchService`'s side of the bridge — the
    /// write that actually starts the background indexer, not just a stored preference.
    func testTurningSemanticSearchOnCallsSetEnabled() {
        var calls: [Bool] = []
        let model = makeModel(search: SemanticSearchControl(
            isAvailable: { true },
            isEnabled: { false },
            setEnabled: { calls.append($0) }
        ))

        model.semanticEnabled = true

        XCTAssertEqual(calls, [true])
    }

    func testSettingSemanticEnabledToItsOwnValueDoesNotWriteAgain() {
        var callCount = 0
        let model = makeModel(search: SemanticSearchControl(
            isAvailable: { true },
            isEnabled: { true },
            setEnabled: { _ in callCount += 1 }
        ))

        model.semanticEnabled = true

        XCTAssertEqual(callCount, 0)
    }

    func testDeleteEmbeddingsCallsThroughAndRefreshesProgress() {
        var deleted = false
        var progress: (done: Int, total: Int)? = (5, 10)
        let model = makeModel(search: SemanticSearchControl(
            progress: { progress },
            deleteEmbeddings: {
                deleted = true
                progress = nil
            }
        ))

        model.deleteEmbeddings()

        XCTAssertTrue(deleted)
        XCTAssertNil(model.indexProgress)
    }

    /// A default model — a preview, or a test that only cares about one of the three
    /// sections — claims no permission, no search availability, and a registered hotkey,
    /// rather than crashing on a closure nobody wired.
    func testADefaultModelIsInertAndDoesNotCrash() {
        let model = makeModel()

        XCTAssertFalse(model.isSemanticAvailable)
        XCTAssertFalse(model.semanticEnabled)
        XCTAssertNil(model.indexProgress)
        XCTAssertEqual(model.loginItemStatus, .unavailable)
        XCTAssertTrue(model.isHotKeyRegistered)

        model.deleteEmbeddings()
        model.retryHotKeyRegistration()
    }

    // MARK: Private

    private func makeModel(
        search: SemanticSearchControl = SemanticSearchControl(),
        launchAtLogin: LaunchAtLoginControl = LaunchAtLoginControl(),
        hotKey: HotKeyControl = HotKeyControl()
    ) -> GeneralSettingsModel {
        GeneralSettingsModel(
            digest: DigestSettingsModel(defaults: throwawayDefaults()),
            search: search,
            launchAtLogin: launchAtLogin,
            hotKey: hotKey
        )
    }

    private func throwawayDefaults() -> UserDefaults {
        let name = "app.backglance.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }
}
