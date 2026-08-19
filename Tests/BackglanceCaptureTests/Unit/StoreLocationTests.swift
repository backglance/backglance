@testable import BackglanceCapture
import Foundation
import XCTest

/// ⚠️ These exercise the resolution of Apple's undocumented store path. Every directory
/// here is built inside the test's own temporary directory — nothing reads the real
/// `~/Library`, and no test depends on whether this Mac has a notification store or
/// Full Disk Access.
final class StoreLocationTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("StoreLocationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - The default path

    /// The path itself is the one piece of knowledge this type carries. If it drifts,
    /// every Mac drops into degraded mode at once, so it is pinned here as well as in
    /// the source.
    func testResolvesTheDocumentedPathUnderTheHomeDirectory() throws {
        let home = try makeHomeWithStoreDirectory()

        let url = try StoreLocation.resolve(environment: [:], homeDirectory: home)

        XCTAssertEqual(url.path, home.appendingPathComponent(
            "Library/Group Containers/group.com.apple.usernoted/db2/db"
        ).path)
    }

    /// A fresh user account has no store until `usernoted` writes its first notification.
    /// That is an ordinary state the engine retries out of, not a failure.
    func testMissingStoreDirectoryThrowsStoreNotFound() throws {
        let home = root.appendingPathComponent("empty-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        XCTAssertThrowsError(try StoreLocation.resolve(environment: [:], homeDirectory: home)) { error in
            guard case let CaptureError.storeNotFound(url) = error else {
                return XCTFail("expected storeNotFound, got \(error)")
            }
            XCTAssertEqual(url.lastPathComponent, "db")
        }
    }

    /// `fileExists(atPath:isDirectory:)` is true for a plain file too, so without the
    /// `isDirectory` check a file sitting where `db2/` belongs would resolve happily and
    /// fail much later, inside the snapshot copy.
    func testAFileWhereTheStoreDirectoryBelongsThrowsStoreNotFound() throws {
        let home = root.appendingPathComponent("odd-home", isDirectory: true)
        let containers = home.appendingPathComponent(
            "Library/Group Containers/group.com.apple.usernoted", isDirectory: true
        )
        try FileManager.default.createDirectory(at: containers, withIntermediateDirectories: true)
        try Data().write(to: containers.appendingPathComponent("db2"))

        XCTAssertThrowsError(try StoreLocation.resolve(environment: [:], homeDirectory: home))
    }

    /// The store file itself is deliberately *not* checked: without Full Disk Access
    /// `fileExists` can report false for a file that is plainly there, and reporting
    /// `storeNotFound` for what is really a TCC denial would send the user to the wrong
    /// fix. Resolution succeeds; the snapshot copy is what tells the two apart.
    func testResolutionSucceedsWhenTheDirectoryExistsButTheDatabaseFileDoesNot() throws {
        let home = try makeHomeWithStoreDirectory()

        let url = try StoreLocation.resolve(environment: [:], homeDirectory: home)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - The DEBUG-only override

    func testStorePathOverrideIsUsedWhenItPointsAtAnExistingFile() throws {
        let home = try makeHomeWithStoreDirectory()
        let fixture = try makeFixtureFile()

        let url = try StoreLocation.resolve(
            environment: ["BACKGLANCE_STORE_PATH": fixture.path],
            homeDirectory: home,
            honoursOverride: true
        )

        XCTAssertEqual(url.path, fixture.path)
    }

    /// A typo in the env var should say so here rather than surface later as an
    /// unreadable snapshot. A fixture is Backglance's own file, so unlike the real store
    /// its absence is unambiguous.
    func testStorePathOverridePointingAtAMissingFileThrowsStoreNotFound() throws {
        let home = try makeHomeWithStoreDirectory()
        let missing = root.appendingPathComponent("no-such-fixture.db")

        XCTAssertThrowsError(try StoreLocation.resolve(
            environment: ["BACKGLANCE_STORE_PATH": missing.path],
            homeDirectory: home,
            honoursOverride: true
        )) { error in
            guard case let CaptureError.storeNotFound(url) = error else {
                return XCTFail("expected storeNotFound, got \(error)")
            }
            XCTAssertEqual(url.path, missing.path)
        }
    }

    /// A misconfigured environment degrades to the default location rather than trapping,
    /// matching how `ArchivePaths` treats `BACKGLANCE_ARCHIVE_PATH`.
    func testEmptyOrRelativeOverridesFallBackToTheDefaultPath() throws {
        let home = try makeHomeWithStoreDirectory()
        let expected = home.appendingPathComponent(StoreLocation.relativePath).path

        for value in ["", "Tests/Fixtures/SystemStore/macOS26/store.db", "   "] {
            let url = try StoreLocation.resolve(
                environment: ["BACKGLANCE_STORE_PATH": value],
                homeDirectory: home,
                honoursOverride: true
            )
            XCTAssertEqual(url.path, expected, "override \"\(value)\" should be ignored")
        }
    }

    /// The security-relevant half: a shipped Backglance cannot be talked into reading a
    /// store someone else chose, no matter what is in its environment.
    func testAReleaseBuildIgnoresTheOverrideEntirely() throws {
        let home = try makeHomeWithStoreDirectory()
        let fixture = try makeFixtureFile()

        let url = try StoreLocation.resolve(
            environment: ["BACKGLANCE_STORE_PATH": fixture.path],
            homeDirectory: home,
            honoursOverride: false
        )

        XCTAssertEqual(url.path, home.appendingPathComponent(StoreLocation.relativePath).path)
        XCTAssertNotEqual(url.path, fixture.path)
    }

    /// Tests run in DEBUG, so the shipped default must be the honouring one here — and
    /// this is what would fail if the `#if DEBUG` were ever inverted.
    func testTheOverrideIsHonouredInThisBuildConfiguration() {
        XCTAssertTrue(StoreLocation.honoursStorePathOverride)
    }

    // MARK: Private

    private var root = URL(fileURLWithPath: NSTemporaryDirectory())

    /// A home directory containing `db2/` but not the database file itself — the shape a
    /// Mac has when `usernoted` has run at least once.
    private func makeHomeWithStoreDirectory() throws -> URL {
        let home = root.appendingPathComponent("home", isDirectory: true)
        let db2 = home.appendingPathComponent(
            "Library/Group Containers/group.com.apple.usernoted/db2", isDirectory: true
        )
        try FileManager.default.createDirectory(at: db2, withIntermediateDirectories: true)
        return home
    }

    /// Stands in for a synthetic fixture store. Its contents are irrelevant: resolution
    /// only checks that the path exists.
    private func makeFixtureFile() throws -> URL {
        let fixture = root.appendingPathComponent("fixture-store.db")
        try Data().write(to: fixture)
        return fixture
    }
}
