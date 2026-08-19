@testable import BackglanceCapture
import Foundation
import XCTest

/// ⚠️ These stand in for Apple's undocumented store with ordinary files of the same
/// shape (`db`, `db-wal`, `db-shm`). Nothing here reads `~/Library`, and nothing writes
/// into the real support directory: every snapshot goes into the test's own temporary
/// directory via the `into:` seam.
final class StoreSnapshotTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StoreSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        store = root.appendingPathComponent("store", isDirectory: true)
        destination = root.appendingPathComponent("snapshot", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Restore anything a permissions test locked, or the directory cannot be removed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.path)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Copying

    func testTakeCopiesTheDatabaseAndItsWal() throws {
        try writeStore(db: "database", wal: "write-ahead log")

        let snapshot = try StoreSnapshot.take(of: storeURL, into: destination)

        XCTAssertEqual(snapshot.databaseURL.path, destination.appendingPathComponent("db").path)
        XCTAssertEqual(try String(contentsOf: snapshot.databaseURL, encoding: .utf8), "database")
        XCTAssertEqual(
            try String(contentsOf: URL(fileURLWithPath: snapshot.databaseURL.path + "-wal"), encoding: .utf8),
            "write-ahead log"
        )
    }

    /// The `-wal` holds the uncheckpointed rows — the most recent notifications, exactly
    /// the ones capture came for. Copying `db` alone would silently miss them.
    func testTheWalIsCopiedAlongsideTheDatabase() throws {
        try writeStore(db: "database", wal: "write-ahead log")

        let snapshot = try StoreSnapshot.take(of: storeURL, into: destination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.databaseURL.path + "-wal"))
    }

    /// `-shm` is a live wal-index belonging to `usernoted`. A stale copy could point at
    /// WAL frames this snapshot does not contain; SQLite rebuilds it from the `-wal`.
    func testTheShmIsDeliberatelyNotCopied() throws {
        try writeStore(db: "database", wal: "write-ahead log")
        try Data("shared memory index".utf8).write(to: URL(fileURLWithPath: storeURL.path + "-shm"))

        let snapshot = try StoreSnapshot.take(of: storeURL, into: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.databaseURL.path + "-shm"))
    }

    /// A checkpointed store has no `-wal` at all. That is ordinary, not a failure.
    func testAStoreWithNoWalSnapshotsFine() throws {
        try writeStore(db: "database", wal: nil)

        let snapshot = try StoreSnapshot.take(of: storeURL, into: destination)

        XCTAssertEqual(try String(contentsOf: snapshot.databaseURL, encoding: .utf8), "database")
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.databaseURL.path + "-wal"))
    }

    // MARK: - Error mapping

    /// The symptom that sends a user to System Settings. Getting this mapping wrong would
    /// show "couldn't read the database" where "grant Full Disk Access" belongs.
    func testAnUnreadableStoreMapsToFullDiskAccessDenied() throws {
        try writeStore(db: "database", wal: nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: storeURL.path)
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: storeURL.path),
                      "running as root: a 0o000 file is still readable, so there is no denial to map")

        XCTAssertThrowsError(try StoreSnapshot.take(of: storeURL, into: destination)) { error in
            guard case CaptureError.fullDiskAccessDenied = error else {
                return XCTFail("expected fullDiskAccessDenied, got \(error)")
            }
        }
    }

    /// The store resolved a moment ago and is gone now — `usernoted` replaced it, or the
    /// user wiped it. Degrade and retry, do not report an unreadable database.
    func testAMissingStoreMapsToStoreNotFound() {
        XCTAssertThrowsError(try StoreSnapshot.take(of: storeURL, into: destination)) { error in
            guard case let CaptureError.storeNotFound(url) = error else {
                return XCTFail("expected storeNotFound, got \(error)")
            }
            XCTAssertEqual(url.path, storeURL.path)
        }
    }

    func testAnOtherwiseFailedCopyMapsToSnapshotFailed() throws {
        try writeStore(db: "database", wal: nil)
        // Something already occupies the target name, so the copy cannot land.
        try Data("in the way".utf8).write(to: destination.appendingPathComponent("db"))

        XCTAssertThrowsError(try StoreSnapshot.take(of: storeURL, into: destination)) { error in
            guard case CaptureError.snapshotFailed = error else {
                return XCTFail("expected snapshotFailed, got \(error)")
            }
        }
    }

    /// A failed tick must not leave a fragment of the user's notifications on disk. The
    /// `db` copy can succeed and the `-wal` copy still fail, which is the case that would
    /// otherwise strand a partial store.
    func testAFailedWalCopyRemovesThePartialSnapshot() throws {
        try writeStore(db: "database", wal: "write-ahead log")
        let wal = URL(fileURLWithPath: storeURL.path + "-wal")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: wal.path)
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: wal.path),
                      "running as root: a 0o000 file is still readable, so the copy would succeed")

        XCTAssertThrowsError(try StoreSnapshot.take(of: storeURL, into: destination))

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "the partial copy and its directory must be gone")
    }

    // MARK: - The permission predicate

    /// The mapping this pins is the app's most consequential one: it decides whether a
    /// user is told to grant Full Disk Access or is shown a generic read error.
    ///
    /// `copyItem` with an unreadable *source* reports `NSFileWriteNoPermissionError`
    /// (513), attributing the failure to the destination, so the 257 the docs originally
    /// assumed never fires on this path.
    func testAPermissionDenialIsRecognisedWhicheverCodeFoundationChooses() {
        for code in [NSFileReadNoPermissionError, NSFileWriteNoPermissionError] {
            XCTAssertTrue(StoreSnapshot.isPermissionDenied(cocoaError(code, errno: EACCES)), "Cocoa \(code)")
        }
    }

    /// A Cocoa code we have not anticipated still maps correctly as long as the errno
    /// underneath says EACCES or EPERM.
    func testAPermissionDenialIsRecognisedFromTheErrnoAlone() {
        for code in [EACCES, EPERM] {
            XCTAssertTrue(StoreSnapshot.isPermissionDenied(cocoaError(unanticipated, errno: code)), "errno \(code)")
        }
    }

    /// The other half: an unrelated failure must not be reported as a permissions
    /// problem, or the app would send users to System Settings for a full disk.
    func testUnrelatedFailuresAreNotTreatedAsPermissionDenials() {
        let exists = cocoaError(NSFileWriteFileExistsError, errno: EEXIST)

        XCTAssertFalse(StoreSnapshot.isPermissionDenied(exists))
        XCTAssertFalse(StoreSnapshot.isNoSuchFile(exists))
    }

    func testAMissingFileIsRecognisedByCodeOrErrno() {
        XCTAssertTrue(StoreSnapshot.isNoSuchFile(cocoaError(NSFileReadNoSuchFileError, errno: nil)))
        XCTAssertTrue(StoreSnapshot.isNoSuchFile(cocoaError(unanticipated, errno: ENOENT)))
    }

    // MARK: - Discarding

    func testDiscardRemovesTheSnapshotDirectory() throws {
        try writeStore(db: "database", wal: "write-ahead log")
        let snapshot = try StoreSnapshot.take(of: storeURL, into: destination)

        snapshot.discard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.databaseURL.path))
    }

    /// The engine discards on both the success and the failure path, so a double discard
    /// has to be a no-op rather than a crash.
    func testDiscardIsSafeToCallTwice() throws {
        try writeStore(db: "database", wal: nil)
        let snapshot = try StoreSnapshot.take(of: storeURL, into: destination)

        snapshot.discard()
        snapshot.discard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.directory.path))
    }

    // MARK: Private

    private var root = URL(fileURLWithPath: NSTemporaryDirectory())
    private var store = URL(fileURLWithPath: NSTemporaryDirectory())
    private var destination = URL(fileURLWithPath: NSTemporaryDirectory())

    /// A Cocoa code the predicates do not name, so a test using it is asserting that the
    /// errno underneath carried the decision.
    private let unanticipated = NSFileReadUnknownError

    /// Stands in for `.../db2/db`. Its contents are irrelevant to the copy.
    private var storeURL: URL {
        store.appendingPathComponent("db")
    }

    /// A Cocoa error shaped the way Foundation builds them: a code, wrapping the errno
    /// that actually caused it.
    private func cocoaError(_ code: Int, errno: Int32?) -> NSError {
        var userInfo: [String: Any] = [:]
        if let errno {
            userInfo[NSUnderlyingErrorKey] = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return NSError(domain: NSCocoaErrorDomain, code: code, userInfo: userInfo)
    }

    private func writeStore(db: String, wal: String?) throws {
        try Data(db.utf8).write(to: storeURL)
        if let wal {
            try Data(wal.utf8).write(to: URL(fileURLWithPath: storeURL.path + "-wal"))
        }
    }
}
