@testable import BackglanceCapture
import BackglanceCore
import Foundation
import XCTest

/// The cursor is the only thing standing between "capture resumed where it left off" and
/// "capture silently skipped a day". These cover both the value semantics and the
/// round-trip through `capture_state`, against an in-memory archive.
final class StoreCursorTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - Value semantics

    func testStartHasReadNothing() {
        XCTAssertEqual(StoreCursor.start.lastRecID, 0)
        XCTAssertNil(StoreCursor.start.lastDeliveredDate)
    }

    func testAdvancingMovesTheRecIDAndTheDate() {
        let advanced = StoreCursor.start.advanced(toRecID: 148_211, deliveredAt: Self.delivered)

        XCTAssertEqual(advanced.lastRecID, 148_211)
        XCTAssertEqual(advanced.lastDeliveredDate, Self.delivered)
    }

    /// Not every record carries a usable date. Losing the last known one to a record that
    /// has none would make Settings' "last notification seen at" flicker back to empty.
    func testAdvancingWithoutADateKeepsTheLastKnownOne() {
        let seen = StoreCursor.start.advanced(toRecID: 1, deliveredAt: Self.delivered)

        let advanced = seen.advanced(toRecID: 2, deliveredAt: nil)

        XCTAssertEqual(advanced.lastRecID, 2)
        XCTAssertEqual(advanced.lastDeliveredDate, Self.delivered)
    }

    // MARK: - The store-reset heuristic

    /// `rec_id` only climbs while a store lives, so a tail below the cursor means this is
    /// a different store. Resuming from the old cursor would skip everything in the new
    /// one, potentially forever.
    func testATailBelowTheCursorReadsAsAResetStore() {
        let cursor = StoreCursor(lastRecID: 148_211)

        XCTAssertTrue(cursor.isStale(givenTailRecID: 12))
    }

    func testATailAtOrAboveTheCursorIsTheOrdinaryCase() {
        let cursor = StoreCursor(lastRecID: 100)

        XCTAssertFalse(cursor.isStale(givenTailRecID: 100), "nothing new is not a reset")
        XCTAssertFalse(cursor.isStale(givenTailRecID: 101))
    }

    /// An empty store — a fresh account, or Notification Center just cleared — is not a
    /// reset for a cursor that has read nothing either.
    func testAFreshCursorIsNeverStale() {
        XCTAssertFalse(StoreCursor.start.isStale(givenTailRecID: 0))
    }

    // MARK: - Persistence

    func testACursorRoundTripsThroughCaptureState() throws {
        let archive = try XCTUnwrap(archive)
        let cursor = StoreCursor(lastRecID: 148_211, lastDeliveredDate: Self.delivered)

        try archive.saveCursor(cursor)

        XCTAssertEqual(try archive.loadCursor(), cursor)
    }

    /// First launch. The engine has to tell "never read anything" apart from "read up to
    /// rec_id 0", because only the first one may trigger an import.
    func testNoCursorReadsAsNil() throws {
        let archive = try XCTUnwrap(archive)

        XCTAssertNil(try archive.loadCursor())
    }

    func testSavingTwiceKeepsOnlyTheLatest() throws {
        let archive = try XCTUnwrap(archive)

        try archive.saveCursor(StoreCursor(lastRecID: 1))
        try archive.saveCursor(StoreCursor(lastRecID: 2))

        XCTAssertEqual(try archive.loadCursor()?.lastRecID, 2)
    }

    /// Clearing removes the row rather than writing a zero, so the engine sees the same
    /// "never read anything" it saw on first launch.
    func testClearingRestoresTheNeverReadState() throws {
        let archive = try XCTUnwrap(archive)
        try archive.saveCursor(StoreCursor(lastRecID: 148_211))

        try archive.clearCursor()

        XCTAssertNil(try archive.loadCursor())
        XCTAssertNil(try archive.captureState(.cursor))
    }

    /// A cursor written by some other build is resumable state: it costs a re-read on
    /// the next bootstrap, which is a much better outcome than a launch that fails.
    func testACorruptCursorReadsAsNilRatherThanThrowing() throws {
        let archive = try XCTUnwrap(archive)
        try archive.setCaptureState("{\"lastRecID\": \"not a number\"}", for: .cursor)

        XCTAssertNil(try archive.loadCursor())
    }

    /// A cursor with no date must survive the round trip — most stores have records
    /// without one.
    func testACursorWithoutADateRoundTrips() throws {
        let archive = try XCTUnwrap(archive)
        let cursor = StoreCursor(lastRecID: 7)

        try archive.saveCursor(cursor)

        XCTAssertEqual(try archive.loadCursor(), cursor)
        XCTAssertNil(try archive.loadCursor()?.lastDeliveredDate)
    }

    /// The fingerprint shares this boundary with the cursor: `BackglanceCore` stores an
    /// opaque blob, and the typed accessor lives on the capture side.
    func testAFingerprintRoundTripsThroughCaptureState() throws {
        let archive = try XCTUnwrap(archive)
        let fingerprint = StoreFingerprint(
            schemaHash: String(repeating: "7d1ca4f0", count: 8),
            dbinfoVersion: "17",
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0)
        )

        try archive.saveFingerprint(fingerprint)

        XCTAssertEqual(try archive.loadFingerprint(), fingerprint)
    }

    // MARK: Private

    private static let delivered = Date(timeIntervalSince1970: 1_755_436_800)

    private var archive: Archive?
}
