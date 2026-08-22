@testable import BackglanceCore
import Foundation
import XCTest

/// The stored form of a pause. It is a format, not an implementation detail: a menu writes
/// it, an engine reads it a launch later, and `backglance://pause` will write it too.
final class PauseSettingsTests: XCTestCase {
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

    // MARK: - The stored encoding

    func testZeroMeansNotPausedAndMinusOneMeansIndefinitely() {
        XCTAssertEqual(PauseState(storedValue: 0), .notPaused)
        XCTAssertEqual(PauseState(storedValue: -1), .indefinite)
        XCTAssertEqual(PauseState(storedValue: 1_000), .until(Date(timeIntervalSince1970: 1_000)))
    }

    func testEveryStateSurvivesARoundTripThroughItsStoredValue() {
        let states: [PauseState] = [.notPaused, .indefinite, .until(Date(timeIntervalSince1970: 1_755_000_000))]
        for state in states {
            XCTAssertEqual(PauseState(storedValue: state.storedValue), state)
        }
    }

    /// 🔒 A value nobody wrote deliberately has to fail towards *more* pausing: capturing
    /// something the user asked not to capture is the failure that matters here.
    func testAnUnexpectedNegativeValueReadsAsPaused() {
        XCTAssertEqual(PauseState(storedValue: -99.5), .indefinite)
    }

    // MARK: - Expiry

    func testAPauseWhoseEndTimeHasPassedIsOver() {
        let now = Date(timeIntervalSince1970: 2_000)

        XCTAssertEqual(PauseState.until(Date(timeIntervalSince1970: 1_999)).resolved(at: now), .notPaused)
        XCTAssertEqual(
            PauseState.until(Date(timeIntervalSince1970: 2_001)).resolved(at: now),
            .until(Date(timeIntervalSince1970: 2_001))
        )
    }

    /// An indefinite pause has no end time, so no amount of elapsed time ends it.
    func testAnIndefinitePauseNeverResolvesAway() {
        XCTAssertEqual(PauseState.indefinite.resolved(at: .distantFuture), .indefinite)
    }

    // MARK: - Reading and writing

    func testAFreshMacIsNotPausedAndDoesNotBackfill() throws {
        let settings = try PauseSettings(defaults: XCTUnwrap(defaults))

        XCTAssertEqual(settings.state, .notPaused)
        XCTAssertFalse(settings.importWhilePaused, "a pause is a gap in the archive by default, not a delay")
    }

    func testSavedStateIsWhatTheNextReadSees() throws {
        let defaults = try XCTUnwrap(defaults)
        let until = Date(timeIntervalSince1970: 1_755_000_000)

        PauseSettings.save(state: .until(until), to: defaults)
        PauseSettings.save(importWhilePaused: true, to: defaults)

        let settings = PauseSettings(defaults: defaults)
        XCTAssertEqual(settings.state, .until(until))
        XCTAssertTrue(settings.importWhilePaused)
    }

    func testDeadlineIsOnlyTheOneATimedPauseCarries() {
        XCTAssertNil(PauseState.notPaused.deadline)
        XCTAssertNil(PauseState.indefinite.deadline)
        XCTAssertEqual(PauseState.until(Date(timeIntervalSince1970: 5)).deadline, Date(timeIntervalSince1970: 5))
    }

    // MARK: Private

    private var defaults: UserDefaults?
    private var suiteName: String?
}
