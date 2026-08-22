@testable import BackglanceUI
import Foundation
import XCTest

/// The banner that says capture is off. Its behaviour is mostly a list of things it must not
/// do, so what is asserted here is the one piece of state it has and the three buttons that
/// have to reach the app shell.
@MainActor
final class CaptureBannerModelTests: XCTestCase {
    // MARK: - Dismissal

    func testItStartsVisible() {
        let model = CaptureBannerModel()

        XCTAssertFalse(model.isDismissed)
    }

    /// One model for both surfaces, so closing it in the popover closes it in the window —
    /// they are the same banner about the same condition, and having to close it twice would
    /// read as it not having been closed.
    func testDismissingIsSharedByEverySurfaceHoldingTheModel() {
        let model = CaptureBannerModel()

        model.dismiss()

        XCTAssertTrue(model.isDismissed, "and every view reading this model sees it")
    }

    /// 🔒 Per session, not forever. Capture being off is silent — no missing rows announce
    /// themselves — so a dismissal that persisted would leave someone with an app that has
    /// quietly archived nothing for months. A fresh model is a fresh launch.
    func testANewLaunchShowsItAgain() {
        let dismissed = CaptureBannerModel()
        dismissed.dismiss()

        let relaunched = CaptureBannerModel()

        XCTAssertFalse(relaunched.isDismissed)
    }

    // MARK: - The buttons

    func testEachButtonReachesTheAppShell() {
        var opened = 0
        var checked = 0
        var learned = 0
        var resumed = 0
        let model = CaptureBannerModel(
            openSystemSettings: { opened += 1 },
            checkAgain: { checked += 1 },
            learnWhy: { learned += 1 },
            resumeCapture: { resumed += 1 }
        )

        model.openSystemSettings()
        model.checkAgain()
        model.learnWhy()
        model.resumeCapture()

        XCTAssertEqual([opened, checked, learned, resumed], [1, 1, 1, 1])
    }

    /// A model built without closures — a preview, or a host with no capture engine — does
    /// nothing rather than trapping on a missing action.
    func testAModelWithNoActionsIsInert() {
        let model = CaptureBannerModel()

        model.openSystemSettings()
        model.checkAgain()
        model.learnWhy()
        model.resumeCapture()

        XCTAssertFalse(model.isDismissed)
    }
}
