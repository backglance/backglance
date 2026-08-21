@testable import BackglanceCore
import Foundation
import XCTest

/// Covers the ⚠️ private-file watcher from
/// docs/features/MISSED_DIGEST.md#focusassertionwatcher.
///
/// Every case writes its own JSON into a temporary directory. Nothing here reads
/// `~/Library/DoNotDisturb/`, and nothing asserts against a real Mac's Focus state — the
/// whole point of the injected URL is that this suite is hermetic.
///
/// The emphasis is on the failure shapes rather than the happy path, because the failure
/// shapes are the contract: a format nobody has seen must turn the watcher off, and a
/// file caught mid-write must not.
final class FocusAssertionWatcherTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("focus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Reading the shape we know

    func testANonEmptyAssertionRecordReadsAsActive() throws {
        let url = try write(#"{"data":[{"storeAssertionRecords":[{"assertionDetails":{}}]}]}"#)
        XCTAssertEqual(makeWatcher(url).readStatus(), .active)
    }

    func testAnEmptyRecordsArrayReadsAsInactive() throws {
        let url = try write(#"{"data":[{"storeAssertionRecords":[]}]}"#)
        XCTAssertEqual(makeWatcher(url).readStatus(), .inactive)
    }

    func testAnEntryWithoutRecordsAtAllReadsAsInactive() throws {
        // Observed on a Mac with Focus configured but nothing on: the entry exists and
        // simply carries no records key.
        let url = try write(#"{"data":[{"storeAssertionRecordsCount":0}]}"#)
        XCTAssertEqual(makeWatcher(url).readStatus(), .inactive)
    }

    func testActiveWinsOverEarlierInactiveEntries() throws {
        let url = try write("""
        {"data":[{"storeAssertionRecords":[]},{"storeAssertionRecords":[{"a":1}]}]}
        """)
        XCTAssertEqual(makeWatcher(url).readStatus(), .active)
    }

    func testAnEmptyDataArrayReadsAsInactiveRatherThanUnavailable() throws {
        // A present-and-well-formed file that simply says nothing is on. That is an
        // answer, not a surprise.
        let url = try write(#"{"data":[]}"#)
        XCTAssertEqual(makeWatcher(url).readStatus(), .inactive)
    }

    func testUnknownSiblingKeysAreIgnored() throws {
        // Apple adding a key must not break detection; only the shape we read matters.
        let url = try write("""
        {"version":7,"data":[{"storeAssertionRecords":[{"a":1}],"somethingNew":true}],"extra":{}}
        """)
        XCTAssertEqual(makeWatcher(url).readStatus(), .active)
    }

    // MARK: - Shapes nobody has seen

    func testAMissingFileIsNotReadable() {
        let watcher = makeWatcher(directory.appendingPathComponent("absent.json"))
        XCTAssertEqual(watcher.readStatus(), .unavailable(.notReadable(code: ENOENT)))
    }

    func testBytesThatAreNotJSONAreATornReadNotAFormatChange() throws {
        let url = try write("{\"data\":[{\"storeAsser")
        let status = watcherStatus(url)
        XCTAssertEqual(status, .unavailable(.readFailed))
        XCTAssertFalse(
            try XCTUnwrap(unavailableReason(status)).isStructural,
            "a half-written file must not latch the watcher off"
        )
    }

    func testAJSONRootThatIsNotAnObjectIsStructural() throws {
        let url = try write("[]")
        let status = watcherStatus(url)
        XCTAssertEqual(status, .unavailable(.unexpectedRoot))
        XCTAssertTrue(try XCTUnwrap(unavailableReason(status)).isStructural)
    }

    func testAMissingDataArrayIsStructural() throws {
        let url = try write(#"{"assertions":[]}"#)
        let status = watcherStatus(url)
        XCTAssertEqual(status, .unavailable(.missingDataArray))
        XCTAssertTrue(try XCTUnwrap(unavailableReason(status)).isStructural)
    }

    func testADataValueOfTheWrongTypeIsStructural() throws {
        // `data` present but not an array of objects — the format moved under us.
        let url = try write(#"{"data":{"storeAssertionRecords":[{"a":1}]}}"#)
        XCTAssertEqual(watcherStatus(url), .unavailable(.missingDataArray))
    }

    func testAnImplausiblyLargeFileIsRefusedWithoutReadingIt() throws {
        let url = directory.appendingPathComponent("Assertions.json")
        let oversized = FocusAssertionWatcher.sizeLimit + 1
        // Sparse: the point is the declared size, and writing 4 MB per test run is waste.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(oversized))
        try handle.close()

        XCTAssertEqual(watcherStatus(url), .unavailable(.tooLarge(bytes: oversized)))
    }

    // MARK: - What the reasons are allowed to say

    func testNoReasonLeaksAPath() {
        let reasons: [FocusAssertionWatcher.Unavailable] = [
            .notReadable(code: ENOENT),
            .readFailed,
            .tooLarge(bytes: 9_000_000),
            .unexpectedRoot,
            .missingDataArray,
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for reason in reasons {
            // 🔒 Both strings reach the file log and a Settings row.
            XCTAssertFalse(reason.logDescription.contains(home))
            XCTAssertFalse(reason.logDescription.contains("/"))
            XCTAssertFalse(reason.userMessage.contains(home))
            XCTAssertFalse(reason.userMessage.isEmpty)
        }
    }

    func testOnlyFormatChangesTurnTheWatcherOff() {
        XCTAssertFalse(FocusAssertionWatcher.Unavailable.notReadable(code: ENOENT).isStructural)
        XCTAssertFalse(FocusAssertionWatcher.Unavailable.readFailed.isStructural)
        XCTAssertTrue(FocusAssertionWatcher.Unavailable.tooLarge(bytes: 1).isStructural)
        XCTAssertTrue(FocusAssertionWatcher.Unavailable.unexpectedRoot.isStructural)
        XCTAssertTrue(FocusAssertionWatcher.Unavailable.missingDataArray.isStructural)
    }

    // MARK: - Watching

    func testStartingReportsTheInitialStateWithoutWaitingForAChange() throws {
        let url = try write(#"{"data":[{"storeAssertionRecords":[{"a":1}]}]}"#)
        let reported = expectation(description: "initial status")
        let box = StatusBox()
        let watcher = FocusAssertionWatcher(url: url) { status in
            box.append(status)
            reported.fulfill()
        }
        watcher.start()
        wait(for: [reported], timeout: 2)
        watcher.stop()

        XCTAssertEqual(box.all.first, .active)
    }

    func testAMissingFileStillReportsOnceSoTheStatusLineCanSayWhy() {
        let reported = expectation(description: "initial status")
        let box = StatusBox()
        let watcher = FocusAssertionWatcher(url: directory.appendingPathComponent("absent.json")) { status in
            box.append(status)
            reported.fulfill()
        }
        watcher.start()
        wait(for: [reported], timeout: 2)
        watcher.stop()

        XCTAssertEqual(box.all.first, .unavailable(.notReadable(code: ENOENT)))
    }

    // MARK: Private

    /// Collects statuses from the watcher's queue.
    private final class StatusBox: @unchecked Sendable {
        // MARK: Internal

        var all: [FocusAssertionWatcher.Status] {
            lock.withLock { storage }
        }

        func append(_ status: FocusAssertionWatcher.Status) {
            lock.withLock { storage.append(status) }
        }

        // MARK: Private

        private let lock = NSLock()
        private var storage: [FocusAssertionWatcher.Status] = []
    }

    private var directory: URL!

    private func write(_ contents: String, named name: String = "Assertions.json") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeWatcher(_ url: URL) -> FocusAssertionWatcher {
        FocusAssertionWatcher(url: url) { _ in }
    }

    private func watcherStatus(_ url: URL) -> FocusAssertionWatcher.Status {
        makeWatcher(url).readStatus()
    }

    private func unavailableReason(
        _ status: FocusAssertionWatcher.Status
    ) -> FocusAssertionWatcher.Unavailable? {
        guard case let .unavailable(reason) = status else {
            return nil
        }
        return reason
    }
}
