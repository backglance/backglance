@testable import BackglanceUI
import Foundation
import XCTest

/// The Permissions pane reports three permissions and requests none of them. What is worth
/// asserting is exactly that: that reading is all it does, and that every reader is re-run
/// when the pane refreshes, since all three can change in System Settings while this window
/// is open.
@MainActor
final class PermissionsSettingsModelTests: XCTestCase {
    // MARK: Internal

    // MARK: - Reading

    func testItReadsTheThreePermissionsOnRefresh() async {
        let model = PermissionsSettingsModel(
            readFullDiskAccess: { .granted },
            readBannerAuthorization: { .authorized },
            readLoginItemStatus: { .registered }
        )

        await model.refresh()

        XCTAssertEqual(model.fdaState, .granted)
        XCTAssertEqual(model.bannerAuthorization, .authorized)
        XCTAssertEqual(model.loginItemStatus, .registered)
    }

    /// All three can change in System Settings while this window is open, so nothing is
    /// cached past a refresh.
    func testEveryRefreshAsksAgain() async {
        let counter = Counter()
        let read: @Sendable () -> FullDiskAccessDisplayState = {
            counter.increment()
            return .denied
        }
        let model = PermissionsSettingsModel(readFullDiskAccess: read)
        let afterInit = counter.value

        await model.refresh()
        await model.refresh()

        XCTAssertEqual(counter.value, afterInit + 2)
    }

    /// The synchronous readers run at init so the pane draws a real state before its first
    /// refresh lands, rather than flashing a default.
    func testTheSynchronousReadersRunAtInit() {
        let model = PermissionsSettingsModel(
            readFullDiskAccess: { .granted },
            readLoginItemStatus: { .requiresApproval }
        )

        XCTAssertEqual(model.fdaState, .granted)
        XCTAssertEqual(model.loginItemStatus, .requiresApproval)
    }

    /// Notification authorization is `async` and cannot be read at init, so it starts at the
    /// state that asks for nothing. A default of `.authorized` would have the pane claim a
    /// permission it has not checked.
    func testNotificationAuthorizationStartsUnasked() {
        let read: @Sendable () async -> BannerAuthorization = { .authorized }
        let model = PermissionsSettingsModel(readBannerAuthorization: read)

        XCTAssertEqual(model.bannerAuthorization, .notDetermined)
    }

    // MARK: - The tccutil hint

    /// 🔒 Shown, never run. An app that resets its own TCC grants is indistinguishable from
    /// one probing what else it can reset, and this pane's whole premise is that the
    /// permission is the user's to give and take.
    func testTheResetCommandIsScopedToBackglanceAndOnlyCopied() {
        var copied: [String] = []
        let copy: @Sendable (String) -> Void = { copied.append($0) }
        let model = PermissionsSettingsModel(actions: PermissionsActions(copyToPasteboard: copy))

        model.actions.copyToPasteboard(PermissionsSettingsModel.tccutilCommand)

        XCTAssertEqual(copied, [PermissionsSettingsModel.tccutilCommand])
        XCTAssertTrue(
            PermissionsSettingsModel.tccutilCommand.hasSuffix("app.backglance.Backglance"),
            "the command must name Backglance, not reset every app's grant"
        )
    }

    func testEachActionReachesTheAppShell() {
        var events: [String] = []
        let model = PermissionsSettingsModel(
            actions: PermissionsActions(
                openFullDiskAccessSettings: { events.append("fda") },
                openNotificationSettings: { events.append("notifications") },
                openLoginItemsSettings: { events.append("loginItems") },
                showSetupAgain: { events.append("setup") }
            )
        )

        model.actions.openFullDiskAccessSettings()
        model.actions.openNotificationSettings()
        model.actions.openLoginItemsSettings()
        model.actions.showSetupAgain()

        XCTAssertEqual(events, ["fda", "notifications", "loginItems", "setup"])
    }

    /// A model built with no readers or actions — a preview — reports the state that claims
    /// nothing, and its buttons do nothing rather than trapping.
    func testADefaultModelClaimsNoPermissions() async {
        let model = PermissionsSettingsModel()

        await model.refresh()
        model.actions.showSetupAgain()

        XCTAssertEqual(model.fdaState, .denied)
        XCTAssertEqual(model.bannerAuthorization, .notDetermined)
        XCTAssertEqual(model.loginItemStatus, .unavailable)
    }

    // MARK: Private

    /// Counts across the `@Sendable` boundary the readers are declared with.
    private final class Counter: @unchecked Sendable {
        // MARK: Internal

        var value: Int {
            lock.withLock { count }
        }

        func increment() {
            lock.withLock { count += 1 }
        }

        // MARK: Private

        private let lock = NSLock()
        private var count = 0
    }
}
