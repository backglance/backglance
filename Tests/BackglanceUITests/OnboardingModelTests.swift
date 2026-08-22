@testable import BackglanceUI
import Foundation
import XCTest

// MARK: - OnboardingModelTests

/// Setup's sequence, and the one rule that makes it worth having a state machine: nothing
/// past the Grant screen may happen on a Mac that never granted anything.
@MainActor
final class OnboardingModelTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        let name = "app.backglance.tests.\(UUID().uuidString)"
        suiteName = name
        defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    // MARK: - Walking the screens

    func testItWalksForwardsAndBackwards() throws {
        let model = try makeModel(fdaState: .granted)

        model.next()
        model.next()
        XCTAssertEqual(model.step, .whatWeRead)

        model.back()
        XCTAssertEqual(model.step, .whyFDA)
    }

    func testThereIsNoBackFromTheFirstScreen() throws {
        let model = try makeModel()

        XCTAssertFalse(model.canGoBack)
        model.back()
        XCTAssertEqual(model.step, .welcome)
    }

    /// The last screen has already started the import, so stepping back from it would offer
    /// to grant access that is granted.
    func testThereIsNoBackFromTheLastScreen() throws {
        let model = try makeModel(fdaState: .granted)
        model.jump(to: .done)

        XCTAssertFalse(model.canGoBack)
        model.back()
        XCTAssertEqual(model.step, .done)
    }

    func testSkipIsOfferedEverywhereExceptTheLastScreen() throws {
        let model = try makeModel(fdaState: .granted)

        for step in [OnboardingStep.welcome, .whyFDA, .whatWeRead, .grant] {
            model.jump(to: step)
            XCTAssertTrue(model.canSkip, "\(step)")
        }
        model.jump(to: .done)
        XCTAssertFalse(model.canSkip)
    }

    // MARK: - The gate

    /// 🔒 The one rule. Continuing past Grant without access would show a screen saying setup
    /// is done, on a Mac where capture cannot run.
    func testContinueIsBlockedOnGrantUntilAccessIsGranted() throws {
        let model = try makeModel(fdaState: .denied)
        model.jump(to: .grant)

        XCTAssertFalse(model.canContinue)
        model.next()
        XCTAssertEqual(model.step, .grant, "it did not move")

        model.fullDiskAccessChanged(to: .granted)
        XCTAssertTrue(model.canContinue)
    }

    /// The grant happens in another app's window, so the screen the user comes back to has to
    /// have moved on by itself — that is the confirmation that what they did worked.
    func testGrantingWhileOnTheGrantScreenAdvances() throws {
        let model = try makeModel(fdaState: .denied)
        model.jump(to: .grant)

        model.fullDiskAccessChanged(to: .granted)

        XCTAssertEqual(model.step, .done)
    }

    /// Only from the Grant screen. A grant noticed while the user is reading screen 2 must
    /// not skip them past the two screens that explain what they just agreed to.
    func testGrantingOnAnotherScreenDoesNotAdvance() throws {
        let model = try makeModel(fdaState: .denied)
        model.jump(to: .whyFDA)

        model.fullDiskAccessChanged(to: .granted)

        XCTAssertEqual(model.step, .whyFDA)
    }

    // MARK: - The import

    /// 🔒 The import reads every notification Apple's store still holds. It runs when the user
    /// reaches the end of a flow they consented to, and never because some other path reached
    /// the same screen.
    func testTheImportStartsOnceOnReachingTheLastScreen() throws {
        let model = try makeModel(fdaState: .granted)
        var starts = 0
        model.onStartImport = { starts += 1 }

        model.jump(to: .grant)
        model.next()
        XCTAssertEqual(model.step, .done)
        XCTAssertEqual(starts, 1)

        model.back()
        model.next()
        XCTAssertEqual(starts, 1, "reaching the screen again does not re-import")
    }

    func testTheImportNeverStartsWithoutAccess() throws {
        let model = try makeModel(fdaState: .denied)
        var starts = 0
        model.onStartImport = { starts += 1 }

        model.jump(to: .grant)
        model.next()

        XCTAssertEqual(model.step, .grant)
        XCTAssertEqual(starts, 0)
    }

    // MARK: - Finishing

    func testFinishingRecordsTheVersionAndThatNothingWasSkipped() throws {
        let defaults = try XCTUnwrap(defaults)
        let model = try makeModel(fdaState: .granted)
        model.jump(to: .done)

        model.next()

        XCTAssertTrue(OnboardingModel.isComplete(defaults: defaults))
        XCTAssertFalse(defaults.bool(forKey: OnboardingModel.skippedFDAKey))
        XCTAssertTrue(model.isFinished)
    }

    /// Skipping is a supported outcome, not a failure. It is recorded so the banner knows,
    /// and setup does not reopen on the next launch.
    func testSkippingRecordsBothTheVersionAndTheSkip() throws {
        let defaults = try XCTUnwrap(defaults)
        let model = try makeModel(fdaState: .denied)

        model.skip()

        XCTAssertTrue(OnboardingModel.isComplete(defaults: defaults))
        XCTAssertTrue(defaults.bool(forKey: OnboardingModel.skippedFDAKey))
    }

    /// "Skipped" means skipped *the grant*. Someone who clicked Skip on the last screen with
    /// access already granted has skipped nothing, and the banner must not treat them as
    /// though they had.
    func testSkippingWithAccessGrantedIsNotASkip() throws {
        let defaults = try XCTUnwrap(defaults)
        let model = try makeModel(fdaState: .granted)

        model.skip()

        XCTAssertFalse(model.didSkip)
        XCTAssertFalse(defaults.bool(forKey: OnboardingModel.skippedFDAKey))
    }

    /// The red button is a legitimate way out, and records the same thing — a window
    /// dismissed without recording anything would reopen next launch.
    func testClosingTheWindowCountsAsSkipping() throws {
        let defaults = try XCTUnwrap(defaults)
        let model = try makeModel(fdaState: .denied)

        model.skipIfUnfinished()

        XCTAssertTrue(OnboardingModel.isComplete(defaults: defaults))
        XCTAssertTrue(model.isFinished)
    }

    func testClosingAfterFinishingDoesNotFinishTwice() throws {
        let model = try makeModel(fdaState: .granted)
        var finishes = 0
        model.onFinish = { finishes += 1 }
        model.jump(to: .done)
        model.next()

        model.skipIfUnfinished()

        XCTAssertEqual(finishes, 1)
    }

    // MARK: - Coming back

    func testAFreshMacStartsAtTheWelcome() throws {
        let model = try makeModel(fdaState: .denied)

        XCTAssertEqual(model.step, .welcome)
    }

    /// Someone reopening setup because the banner is still there does not need the welcome
    /// again — they need the screen that explains why the permission is needed.
    func testReopeningWithoutAccessStartsAtTheExplanation() throws {
        let defaults = try XCTUnwrap(defaults)
        try makeModel(fdaState: .denied).skip()

        let reopened = try makeModel(fdaState: .denied)

        XCTAssertTrue(OnboardingModel.isComplete(defaults: defaults))
        XCTAssertEqual(reopened.step, .whyFDA)
    }

    /// Access granted but the import never ran: the last screen is the only one with anything
    /// left to do.
    func testReopeningWithAccessStartsAtTheEnd() throws {
        try makeModel(fdaState: .denied).skip()

        let reopened = try makeModel(fdaState: .granted)

        XCTAssertEqual(reopened.step, .done)
    }

    // MARK: - The relaunch hint

    /// Delayed rather than shown up front: saying it immediately would teach everyone to
    /// relaunch when most people never need to.
    func testTheRelaunchHintIsNotShownBeforeSystemSettingsIsOpened() throws {
        let model = try makeModel(fdaState: .denied)
        model.jump(to: .grant)

        model.fullDiskAccessChanged(to: .denied)

        XCTAssertFalse(model.showsRelaunchHint)
    }

    func testTheHintClearsOnceAccessArrives() throws {
        let model = try makeModel(fdaState: .denied)
        model.jump(to: .grant)
        model.openFullDiskAccessSettings()

        model.fullDiskAccessChanged(to: .granted)

        XCTAssertFalse(model.showsRelaunchHint)
        XCTAssertTrue(model.didOpenSystemSettings)
    }

    // MARK: - Check again

    func testCheckAgainAsksTheAppShellToReprobe() throws {
        var checks = 0
        let check = { checks += 1 }
        let model = try makeModel(fdaState: .denied, checkAccessAgain: check)

        model.checkAgain()

        XCTAssertEqual(checks, 1)
    }

    // MARK: Private

    private var defaults: UserDefaults?
    private var suiteName: String?

    private func makeModel(
        fdaState: FullDiskAccessDisplayState = .denied,
        checkAccessAgain: @escaping () -> Void = {}
    ) throws -> OnboardingModel {
        try OnboardingModel(
            fdaState: fdaState,
            checkAccessAgain: checkAccessAgain,
            defaults: XCTUnwrap(defaults)
        )
    }
}

// MARK: - Test navigation

private extension OnboardingModel {
    /// Walks to `step` through the real transitions, so a test never puts the model in a
    /// state the flow could not reach.
    func jump(to target: OnboardingStep) {
        while step.rawValue < target.rawValue {
            let before = step
            next()
            if step == before {
                return
            }
        }
    }
}
