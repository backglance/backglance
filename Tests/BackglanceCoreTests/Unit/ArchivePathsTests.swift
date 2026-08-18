@testable import BackglanceCore
import Foundation
import XCTest

final class ArchivePathsTests: XCTestCase {
    // MARK: Internal

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        super.tearDown()
    }

    // MARK: - resolveArchiveURL

    func testDefaultArchiveURLEndsWithExpectedSuffix() {
        let url = ArchivePaths.resolveArchiveURL(environment: [:])
        XCTAssertTrue(url.path.hasSuffix("Library/Application Support/Backglance/archive.sqlite"))
    }

    func testAbsoluteOverrideIsHonoured() {
        let override = "/tmp/backglance-archive-tests/archive.sqlite"
        let url = ArchivePaths.resolveArchiveURL(environment: ["BACKGLANCE_ARCHIVE_PATH": override])
        XCTAssertEqual(url.path, override)
    }

    func testRelativeOverrideIsIgnored() {
        let url = ArchivePaths.resolveArchiveURL(environment: ["BACKGLANCE_ARCHIVE_PATH": "relative/archive.sqlite"])
        XCTAssertTrue(url.path.hasSuffix("Library/Application Support/Backglance/archive.sqlite"))
    }

    func testEmptyOverrideIsIgnored() {
        let url = ArchivePaths.resolveArchiveURL(environment: ["BACKGLANCE_ARCHIVE_PATH": ""])
        XCTAssertTrue(url.path.hasSuffix("Library/Application Support/Backglance/archive.sqlite"))
    }

    // MARK: - Derived directories follow the override

    /// An override relocates the whole support directory, not just the database file:
    /// `icons/` and `tmp/` are derived from the archive's parent, so they move with it.
    func testOverrideRelocatesTheWholeSupportDirectory() {
        let overrideURL = makeTempDirectory()
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("archive.sqlite")
        let resolved = ArchivePaths.resolveArchiveURL(
            environment: ["BACKGLANCE_ARCHIVE_PATH": overrideURL.path]
        )

        XCTAssertEqual(resolved.path, overrideURL.path)
        XCTAssertEqual(resolved.deletingLastPathComponent().path,
                       overrideURL.deletingLastPathComponent().path)
        XCTAssertFalse(resolved.path.contains("Application Support/Backglance"))
    }

    /// The public accessors are derived from ``ArchivePaths/archiveURL``: `supportDirectory`
    /// is its parent, and the two caches are children of that. Asserted on the real
    /// properties so the derivation cannot silently drift from ``resolveArchiveURL(environment:)``.
    func testPublicDirectoriesAreDerivedFromTheArchiveURL() {
        let support = ArchivePaths.supportDirectory

        XCTAssertEqual(support.path, ArchivePaths.archiveURL.deletingLastPathComponent().path)
        XCTAssertEqual(ArchivePaths.iconsDirectory.deletingLastPathComponent().path, support.path)
        XCTAssertEqual(ArchivePaths.tmpDirectory.deletingLastPathComponent().path, support.path)
        XCTAssertEqual(ArchivePaths.iconsDirectory.lastPathComponent, "icons")
        XCTAssertEqual(ArchivePaths.tmpDirectory.lastPathComponent, "tmp")
    }

    // MARK: - prepare(archiveURL:)

    func testPrepareCreatesDirectoriesWithExpectedPermissions() throws {
        let directory = makeTempDirectory()
        let archiveURL = directory.appendingPathComponent("archive.sqlite")

        try ArchivePaths.prepare(archiveURL: archiveURL)

        let fileManager = FileManager.default
        let candidates = [
            directory,
            directory.appendingPathComponent("icons"),
            directory.appendingPathComponent("tmp"),
        ]
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
            let attributes = try fileManager.attributesOfItem(atPath: candidate.path)
            let permissions = attributes[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o700)
        }
    }

    func testPrepareTightensExistingArchiveFilePermissions() throws {
        let directory = makeTempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archiveURL = directory.appendingPathComponent("archive.sqlite")
        FileManager.default.createFile(
            atPath: archiveURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o644]
        )

        try ArchivePaths.prepare(archiveURL: archiveURL)

        let attributes = try FileManager.default.attributesOfItem(atPath: archiveURL.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testPrepareDoesNotFailWhenWalAndShmFilesAreAbsent() throws {
        let directory = makeTempDirectory()
        let archiveURL = directory.appendingPathComponent("archive.sqlite")

        XCTAssertNoThrow(try ArchivePaths.prepare(archiveURL: archiveURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path + "-shm"))
    }

    // MARK: Private

    private var tempDirectory: URL?

    private func makeTempDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchivePathsTests-\(UUID().uuidString)", isDirectory: true)
        tempDirectory = directory
        return directory
    }
}
