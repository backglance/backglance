@testable import BackglanceCapture
import Foundation
import XCTest

/// A snapshot directory briefly holds a copy of every notification the system still
/// remembers, so these are privacy tests: they pin the `0700` mode and the guarantee
/// that no copy outlives its tick by more than an hour. Everything runs inside the
/// test's own temporary directory.
final class SnapshotDirectoryTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SnapshotDirectoryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        try super.tearDownWithError()
    }

    // MARK: - Creating

    func testFreshCreatesAnEmptyDirectoryInsideTmp() throws {
        let directory = try SnapshotDirectory.fresh(in: tmp)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(directory.deletingLastPathComponent().path, tmp.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    /// The copy inside is readable by anyone who can read the directory, so the mode is
    /// the whole protection. `0700` matches the support directory `ArchivePaths` creates.
    func testFreshDirectoryIsOwnerOnly() throws {
        let directory = try SnapshotDirectory.fresh(in: tmp)

        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(mode.int16Value, 0o700)
    }

    /// Two ticks must never share a directory, or one tick's `discard()` would delete
    /// the other's copy out from under an open connection.
    func testEachCallReturnsADistinctDirectory() throws {
        let first = try SnapshotDirectory.fresh(in: tmp)
        let second = try SnapshotDirectory.fresh(in: tmp)

        XCTAssertNotEqual(first.path, second.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    /// A first launch, or a run after `PanicWipe`, has no `tmp/` at all.
    func testFreshCreatesIntermediateDirectories() throws {
        let nested = tmp.appendingPathComponent("Backglance/tmp", isDirectory: true)

        let directory = try SnapshotDirectory.fresh(in: nested)

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    /// A creation failure is a capture failure, not a crash: the engine turns it into a
    /// degraded state and retries on the next wake.
    func testACreationFailureThrowsSnapshotFailed() throws {
        // A regular file where `tmp/` belongs: `createDirectory` cannot proceed.
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let blocked = tmp.appendingPathComponent("blocked")
        try Data().write(to: blocked)

        XCTAssertThrowsError(try SnapshotDirectory.fresh(in: blocked)) { error in
            guard case CaptureError.snapshotFailed = error else {
                return XCTFail("expected snapshotFailed, got \(error)")
            }
        }
    }

    // MARK: - Sweeping

    /// The reason the sweep exists: a tick killed mid-copy leaves a directory holding
    /// the user's notifications, and nothing else would ever remove it.
    func testFreshRemovesLeftoversOlderThanAnHour() throws {
        let stale = try makeLeftover(named: "stale", age: SnapshotDirectory.staleAfter + 60)

        _ = try SnapshotDirectory.fresh(in: tmp, now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    /// The other half: the sweep must never race a snapshot that is still in use. An
    /// hour is far longer than the slowest import batch, so anything younger stays.
    func testFreshKeepsLeftoversYoungerThanAnHour() throws {
        let recent = try makeLeftover(named: "recent", age: SnapshotDirectory.staleAfter - 60)

        _ = try SnapshotDirectory.fresh(in: tmp, now: now)

        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    /// The directory the caller just got back must survive its own sweep.
    func testFreshDoesNotSweepTheDirectoryItReturns() throws {
        let directory = try SnapshotDirectory.fresh(in: tmp, now: now)

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    /// A stale directory holding a copy of the store is exactly what must go — including
    /// its contents, not just an empty shell.
    func testSweepRemovesAStaleDirectoryWithItsContents() throws {
        let stale = try makeLeftover(named: "stale", age: SnapshotDirectory.staleAfter + 60)
        try Data("not a real store".utf8).write(to: stale.appendingPathComponent("db"))
        try setModificationDate(of: stale, age: SnapshotDirectory.staleAfter + 60)

        SnapshotDirectory.sweep(tmp, now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.appendingPathComponent("db").path))
    }

    /// Loose files are not snapshot directories and are none of the sweep's business.
    func testSweepIgnoresFiles() throws {
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("stray.txt")
        try Data().write(to: file)
        try setModificationDate(of: file, age: SnapshotDirectory.staleAfter + 60)

        SnapshotDirectory.sweep(tmp, now: now)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// A sweep that cannot read `tmp/` is not a reason to fail the tick that was about
    /// to archive the user's notifications.
    func testSweepOfAMissingDirectoryDoesNothing() {
        SnapshotDirectory.sweep(tmp.appendingPathComponent("never-existed"), now: now)
    }

    // MARK: Private

    private var tmp = URL(fileURLWithPath: NSTemporaryDirectory())

    /// A fixed clock, so the age arithmetic does not depend on how long the test took.
    private let now = Date(timeIntervalSince1970: 1_755_436_800)

    /// A directory in `tmp/` that looks like it was left behind `age` seconds ago.
    private func makeLeftover(named name: String, age: TimeInterval) throws -> URL {
        let directory = tmp.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try setModificationDate(of: directory, age: age)
        return directory
    }

    private func setModificationDate(of url: URL, age: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-age), .creationDate: now.addingTimeInterval(-age)],
            ofItemAtPath: url.path
        )
    }
}
