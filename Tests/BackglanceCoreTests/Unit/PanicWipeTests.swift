@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

/// A wipe has to be believable. These tests are about the two things that make it so: that
/// the notification text is gone from the file's bytes before the file is unlinked, and
/// that what is left afterwards is a working, empty Backglance rather than a broken one.
final class PanicWipeTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try Self.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let directory {
            try? Self.unlock(directory)
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - The invariant

    /// 🔒 The point of zeroing before unlinking. After this step the file still exists, so
    /// this is the one moment the guarantee can actually be inspected: its bytes must not
    /// contain a single notification the archive held a moment ago.
    func testZeroingLeavesNoNotificationTextInTheFile() throws {
        let url = try archiveURL()
        let archive = try Archive(path: url.path)
        let secret = "Verification code 314159 for Aurora Bank"
        try seed(archive, bodies: [secret, "Lunch at one?", "Build #4021 failed"])
        try XCTAssertGreaterThan(Self.occurrences(of: secret, inFileAt: url), 0, "seeded text should be findable first")

        try PanicWipe.zeroPages(of: archive.pool)

        for text in [secret, "Lunch at one?", "Build #4021 failed"] {
            try XCTAssertEqual(Self.occurrences(of: text, inFileAt: url), 0, "found \"\(text)\" in the wiped file")
        }
    }

    /// The FTS index is a second copy of every title and body, in its own shadow tables.
    /// Emptying `notifications` has to take it with them or the wipe leaves the search
    /// index holding what the archive no longer does.
    func testTheSearchIndexIsEmptiedToo() async throws {
        let archive = try Archive(path: archiveURL().path)
        try seed(archive, bodies: ["Verification code 271828"])

        try await PanicWipe.execute(archive: archive)

        let matches = try await archive.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM notifications_fts WHERE notifications_fts MATCH '271828'")
        }
        XCTAssertEqual(matches, 0)
    }

    // MARK: - What is left afterwards

    func testTheArchiveIsEmptyAndStillUsable() async throws {
        let archive = try Archive(path: archiveURL().path)
        try seed(archive, bodies: ["Lunch at one?", "Build #4021 failed"])

        try await PanicWipe.execute(archive: archive)

        var remaining = try await count(in: archive)
        XCTAssertEqual(remaining, 0)
        // Usable, not merely empty: the migration chain ran on the new file, so a write
        // lands rather than failing on a missing table.
        try seed(archive, bodies: ["A notification after the wipe"])
        remaining = try await count(in: archive)
        XCTAssertEqual(remaining, 1)
    }

    /// The same `Archive` object, still at the same path. Everything the app handed this
    /// reference to at launch — the timeline store, search, the digest presenter — goes on
    /// working without being rebuilt.
    func testTheArchiveKeepsItsIdentityAndItsPath() async throws {
        let url = try archiveURL()
        let archive = try Archive(path: url.path)
        try seed(archive, bodies: ["Lunch at one?"])

        try await PanicWipe.execute(archive: archive)

        XCTAssertEqual(archive.location, .file(url))
        XCTAssertEqual(archive.pool.path, url.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "a fresh archive should be back at the path")
    }

    func testTheIconCacheAndSnapshotDirectoryAreRemovedAndRecreated() async throws {
        let url = try archiveURL()
        let archive = try Archive(path: url.path)
        let icons = try XCTUnwrap(directory).appendingPathComponent("icons", isDirectory: true)
        let icon = icons.appendingPathComponent("com.example.app.png")
        try ArchivePaths.prepare(archiveURL: url)
        try Data([0x89, 0x50]).write(to: icon)

        let report = try await PanicWipe.execute(archive: archive)

        XCTAssertFalse(FileManager.default.fileExists(atPath: icon.path), "the cached icon should be gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: icons.path), "icons/ should be back, empty")
        XCTAssertTrue(report.removed.contains("icons"))
        XCTAssertTrue(report.failed.isEmpty)
    }

    /// Files that were never there are not claimed as removed. A Mac that has never cached
    /// an icon should not be told its icon cache was destroyed.
    func testAbsentFilesAreNotReportedAsRemoved() async throws {
        let archive = try Archive(path: archiveURL().path)

        let report = try await PanicWipe.execute(archive: archive)

        XCTAssertFalse(report.removed.contains("icons"))
        XCTAssertTrue(report.removed.contains("archive.sqlite"))
    }

    // MARK: - Per-app settings

    /// 🔒 An exclusion that vanishes is worse than no exclusion at all: the next
    /// notification from that app gets archived, and nobody is watching for it.
    func testExclusionsAndOverridesSurviveTheWipe() async throws {
        let archive = try Archive(path: archiveURL().path)
        try seed(archive, bodies: ["Lunch at one?"])
        try archive.setExcluded(true, bundleID: "com.example.bank")
        try archive.setRetention(.policy(.hours24), bundleID: "com.example.chat")
        try archive.setRedactsOTP(false, bundleID: "com.apple.MobileSMS")

        try await PanicWipe.execute(archive: archive)

        try XCTAssertTrue(archive.exclusionList().excludes("com.example.bank"))
        try XCTAssertEqual(archive.allApps().first { $0.bundleId == "com.example.chat" }?.retention, .policy(.hours24))
        try XCTAssertFalse(archive.redactsOTP(bundleID: "com.apple.MobileSMS"))
    }

    /// The app *list* is not carried across. Which apps notify you is exactly the kind of
    /// thing a wipe is meant to remove, so only rows carrying a decision come back.
    func testAppsWithNothingButHistoryAreNotRecreated() async throws {
        let archive = try Archive(path: archiveURL().path)
        try seed(archive, bodies: ["Lunch at one?"])

        try await PanicWipe.execute(archive: archive)

        try XCTAssertTrue(archive.allApps().isEmpty)
    }

    func testForgettingPerAppSettingsLeavesOnlyTheShippedDefaults() async throws {
        let archive = try Archive(path: archiveURL().path)
        try archive.setExcluded(true, bundleID: "com.example.bank")

        try await PanicWipe.execute(archive: archive, options: .init(forgetPerAppSettings: true))

        try XCTAssertFalse(archive.exclusionList().excludes("com.example.bank"))
        // The shipped defaults are code, not rows, so a completely empty archive still
        // refuses to capture a password manager.
        try XCTAssertTrue(archive.exclusionList().excludes("com.apple.Passwords"))
    }

    // MARK: - When a file will not go

    /// A wipe that cannot remove something still leaves a working, empty Backglance — and
    /// still says what it could not do. The alternative, throwing before the archive is
    /// recreated, is an app with no archive at all.
    func testAFileThatCannotBeRemovedIsReportedAndTheArchiveIsStillRecreated() async throws {
        let url = try archiveURL()
        let archive = try Archive(path: url.path)
        let icons = try XCTUnwrap(directory).appendingPathComponent("icons", isDirectory: true)
        try seed(archive, bodies: ["Lunch at one?"])
        try ArchivePaths.prepare(archiveURL: url)
        try Self.lock(icons)

        do {
            _ = try await PanicWipe.execute(archive: archive)
            XCTFail("expected wipeIncomplete")
        } catch let ArchiveError.wipeIncomplete(remaining) {
            XCTAssertEqual(remaining, ["icons"])
        }

        try Self.unlock(icons)
        let remaining = try await count(in: archive)
        XCTAssertEqual(remaining, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    /// 🔒 The report names files, never paths: it reaches the log and the diagnostics
    /// export, and a path carries the user's account name.
    func testTheReportNamesFilesRatherThanPaths() async throws {
        let archive = try Archive(path: archiveURL().path)

        let report = try await PanicWipe.execute(archive: archive)

        XCTAssertFalse(report.removed.contains { $0.contains("/") }, "\(report.removed)")
        XCTAssertEqual(report.removed.first, "archive.sqlite")
    }

    // MARK: - The in-memory archive

    /// Nothing to unlink, so emptying the tables is the whole of the wipe — and the archive
    /// stays usable, which is what lets the rest of the suite run against one.
    func testWipingAnInMemoryArchiveEmptiesItWithoutTouchingTheDisk() async throws {
        let archive = try Archive(inMemory: true)
        try seed(archive, bodies: ["Lunch at one?"])

        let report = try await PanicWipe.execute(archive: archive)

        let remaining = try await count(in: archive)
        XCTAssertEqual(report, PanicWipe.Report())
        XCTAssertEqual(remaining, 0)
    }

    // MARK: Private

    private var directory: URL?

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanicWipeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `chflags uchg`, which stops even the owner unlinking the item — the only reliable way
    /// to make a removal fail from inside a test running as the owner.
    private static func lock(_ url: URL) throws {
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
    }

    private static func unlock(_ url: URL) throws {
        let fileManager = FileManager.default
        for path in [url.path, url.appendingPathComponent("icons").path] where fileManager.fileExists(atPath: path) {
            try? fileManager.setAttributes([.immutable: false], ofItemAtPath: path)
        }
    }

    /// How many times `text` appears in the raw bytes of the archive *and its WAL*.
    ///
    /// The bytes, not a query: a `SELECT` would only prove the rows are unreachable, and
    /// the whole point of `secure_delete` is that they are also *not there* — free pages
    /// included. The WAL counts because in WAL mode that is where a freshly inserted
    /// notification actually lives; checking only `archive.sqlite` would pass on a wipe
    /// that left every recent notification sitting beside it.
    private static func occurrences(of text: String, inFileAt url: URL) throws -> Int {
        let needle = Data(text.utf8)
        var count = 0
        for path in [url.path, url.path + "-wal"] {
            guard let data = FileManager.default.contents(atPath: path) else {
                continue
            }
            var searchRange = data.startIndex ..< data.endIndex
            while let found = data.range(of: needle, in: searchRange) {
                count += 1
                searchRange = found.upperBound ..< data.endIndex
            }
        }
        return count
    }

    private func count(in archive: Archive) async throws -> Int {
        try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
    }

    private func archiveURL() throws -> URL {
        try XCTUnwrap(directory).appendingPathComponent("archive.sqlite")
    }

    private func seed(_ archive: Archive, bodies: [String]) throws {
        let now = Date()
        let app = try archive.upsertApp(bundleID: "com.example.app", now: now)
        let appID = try XCTUnwrap(app.id)
        for (index, body) in bodies.enumerated() {
            let notification = ArchivedNotification(
                uuid: UUID().uuidString,
                appId: appID,
                title: "Aurora Bank",
                body: body,
                deliveredAt: UnixDate(now.addingTimeInterval(Double(index))),
                capturedAt: UnixDate(now),
                storeRecId: Int64(index + 1)
            )
            _ = try archive.insertOrUpdate(notification)
        }
    }
}
