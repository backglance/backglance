@testable import BackglanceCapture
import Foundation
import XCTest

/// The probe answers one question — can this process open the store — and the whole design
/// rests on asking it with `open(2)` rather than with the API that looks right.
final class FullDiskAccessProbeTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try Self.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - The three answers

    func testAReadableFileIsGranted() throws {
        let url = try file(named: "db", contents: "x")

        XCTAssertEqual(FullDiskAccessProbe.probe(at: url), .granted)
    }

    /// A file that is not there, in a directory we can list. Not a permission problem, and
    /// the UI must not send anyone to System Settings over it.
    func testAMissingFileInAReadableDirectoryIsStoreMissing() throws {
        let url = try XCTUnwrap(directory).appendingPathComponent("db")

        XCTAssertEqual(FullDiskAccessProbe.probe(at: url), .storeMissing)
    }

    /// The condition TCC produces: the path exists and `open` is refused.
    func testAnUnreadableFileIsDenied() throws {
        let url = try file(named: "db", contents: "x")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)

        try XCTSkipIf(getuid() == 0, "root can open anything, so there is no denial to observe")
        XCTAssertEqual(FullDiskAccessProbe.probe(at: url), .denied)
    }

    /// 🔒 "Not found" is ambiguous under TCC — a denied process is told the file is absent
    /// rather than that it may not look — so the container directory is the tiebreaker. A
    /// directory we cannot open means denied, not missing.
    func testAMissingFileInAnUnreadableDirectoryIsDenied() throws {
        let directory = try XCTUnwrap(directory)
        let url = directory.appendingPathComponent("db")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)

        try XCTSkipIf(getuid() == 0, "root can open anything, so there is no denial to observe")
        XCTAssertEqual(FullDiskAccessProbe.probe(at: url), .denied)
    }

    /// The probe is never more permissive than POSIX.
    ///
    /// The divergence that motivates this file cannot be reproduced in a unit test: TCC
    /// refuses at `open(2)` while leaving POSIX permissions saying yes, so on a Mac without
    /// the grant `isReadableFile` returns `true` for a store this probe correctly calls
    /// `.denied`. What *is* checkable is the other direction — wherever POSIX alone refuses,
    /// the probe refuses too — which is what stops a regression from quietly reintroducing
    /// the `isReadableFile` shortcut.
    func testTheProbeIsNeverMorePermissiveThanPosix() throws {
        let readable = try file(named: "readable", contents: "x")
        let unreadable = try file(named: "unreadable", contents: "x")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        try XCTSkipIf(getuid() == 0, "root can open anything, so there is no denial to observe")

        XCTAssertTrue(FileManager.default.isReadableFile(atPath: readable.path))
        XCTAssertEqual(FullDiskAccessProbe.probe(at: readable), .granted)
        XCTAssertFalse(FileManager.default.isReadableFile(atPath: unreadable.path))
        XCTAssertEqual(FullDiskAccessProbe.probe(at: unreadable), .denied)
    }

    /// A path whose parent is a file, not a directory. Nothing is being denied — the path is
    /// simply wrong — and reporting `.denied` would send someone to System Settings over it.
    func testAPathUnderAFileIsMissingRatherThanDenied() throws {
        let url = try file(named: "db", contents: "x")

        XCTAssertEqual(FullDiskAccessProbe.probe(at: url.appendingPathComponent("nope")), .storeMissing)
    }

    // MARK: - Resolving the store

    func testAnUnresolvableStoreLocationReadsAsMissingRatherThanDenied() {
        let probe = FullDiskAccessProbe { throw CaptureError.storeNotFound(URL(fileURLWithPath: "/nowhere")) }

        XCTAssertEqual(probe.probe(), .storeMissing)
    }

    func testTheInjectedLocationIsWhatGetsProbed() throws {
        let url = try file(named: "db", contents: "x")
        let probe = FullDiskAccessProbe { url }

        XCTAssertEqual(probe.probe(), .granted)
    }

    // MARK: Private

    private var directory: URL?

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FullDiskAccessProbeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(named name: String, contents: String) throws -> URL {
        let url = try XCTUnwrap(directory).appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
