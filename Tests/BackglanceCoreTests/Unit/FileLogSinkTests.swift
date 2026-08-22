@testable import BackglanceCore
import Foundation
import os
import XCTest

/// The file log is the one a user can actually send you, so what matters is that it exists,
/// that it stays small, and that it is no more readable by anyone else than the archive is.
final class FileLogSinkTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try Self.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Writing

    func testAMessageIsWrittenAsOneLine() throws {
        let sink = try makeSink()

        sink.write(level: .notice, category: "capture", message: "adapter resolved id=v26", at: Self.moment)

        let contents = try String(contentsOf: sink.currentFile, encoding: .utf8)
        XCTAssertEqual(contents, "2026-08-22T09:12:44.318Z notice capture adapter resolved id=v26\n")
    }

    /// A message with a newline in it would look like several entries to anything grepping
    /// the file, which is the only way anyone reads it.
    func testAMultiLineMessageStaysOneEntry() throws {
        let sink = try makeSink()

        sink.write(level: .error, category: "archive", message: "line one\nline two", at: Self.moment)

        let contents = try String(contentsOf: sink.currentFile, encoding: .utf8)
        XCTAssertEqual(contents.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(contents.contains("line one line two"), contents)
    }

    /// Times are UTC, because a support log whose times are in the reporter's zone and the
    /// reader's zone is one where "before" and "after" take arithmetic.
    func testTimestampsAreUTC() {
        let line = FileLogSink.line(level: .notice, category: "ui", message: "opened", at: Self.moment)

        XCTAssertTrue(line.hasPrefix("2026-08-22T09:12:44.318Z"), line)
    }

    /// Nothing is created until something is actually logged, so a quiet Backglance leaves no
    /// file behind at all.
    func testNothingIsWrittenUntilTheFirstMessage() throws {
        let sink = try makeSink()

        XCTAssertFalse(FileManager.default.fileExists(atPath: sink.currentFile.path))
    }

    func testWritesAppendRatherThanReplace() throws {
        let sink = try makeSink()

        sink.write(level: .notice, category: "capture", message: "first", at: Self.moment)
        sink.write(level: .notice, category: "capture", message: "second", at: Self.moment)

        let contents = try String(contentsOf: sink.currentFile, encoding: .utf8)
        XCTAssertEqual(contents.filter { $0 == "\n" }.count, 2)
        XCTAssertTrue(contents.contains("first"))
        XCTAssertTrue(contents.contains("second"))
    }

    // MARK: - Levels

    func testMessagesBelowTheThresholdAreDropped() throws {
        let sink = try makeSink(minimumLevel: .notice)

        sink.write(level: .debug, category: "capture", message: "chatty", at: Self.moment)
        sink.write(level: .info, category: "capture", message: "also chatty", at: Self.moment)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sink.currentFile.path))
    }

    func testTheThresholdComesFromTheEnvironment() {
        XCTAssertEqual(FileLogSink.configuredLevel(environment: ["BACKGLANCE_LOG_LEVEL": "debug"]), .debug)
        XCTAssertEqual(FileLogSink.configuredLevel(environment: ["BACKGLANCE_LOG_LEVEL": "ERROR"]), .error)
    }

    /// An unrecognised value keeps the default rather than logging everything — a typo should
    /// not quietly turn on debug logging for a user who will never notice.
    func testAnUnrecognisedLevelKeepsTheDefault() {
        XCTAssertEqual(FileLogSink.configuredLevel(environment: ["BACKGLANCE_LOG_LEVEL": "verbose"]), .notice)
        XCTAssertEqual(FileLogSink.configuredLevel(environment: [:]), .notice)
    }

    /// `OSLogType`'s raw values are not ordered by severity, which is why the sink has a level
    /// type of its own rather than comparing on it.
    func testEveryOSLogTypeMapsToALevel() {
        XCTAssertEqual(LogLevel(OSLogType.debug), .debug)
        XCTAssertEqual(LogLevel(OSLogType.info), .info)
        XCTAssertEqual(LogLevel(OSLogType.default), .notice)
        XCTAssertEqual(LogLevel(OSLogType.error), .error)
        XCTAssertEqual(LogLevel(OSLogType.fault), .fault)
        XCTAssertLessThan(LogLevel.info, LogLevel.notice, "the ordering OSLogType does not have")
    }

    // MARK: - Rotation

    /// 🔒 The bound is the point. A `BACKGLANCE_LOG_LEVEL=debug` left on overnight must not be
    /// able to fill a disk.
    func testTheLogRotatesWhenItGrowsPastItsLimit() throws {
        let sink = try makeSink(maximumFileSize: 256, keptFiles: 3)

        for index in 0 ..< 40 {
            sink.write(level: .notice, category: "capture", message: "message number \(index)", at: Self.moment)
        }

        let files = try logFiles()
        XCTAssertEqual(files.count, 3, "at most three files: \(files)")
        XCTAssertTrue(files.contains("backglance.log"))
        XCTAssertTrue(files.contains("backglance.1.log"))
        XCTAssertTrue(files.contains("backglance.2.log"))
    }

    /// Rotation shifts oldest-first, so the newest rotated file is always `.1` and nothing is
    /// overwritten before it has been moved.
    func testTheMostRecentRotatedFileIsTheFirstOne() throws {
        let sink = try makeSink(maximumFileSize: 128, keptFiles: 3)

        sink.write(level: .notice, category: "capture", message: String(repeating: "a", count: 200), at: Self.moment)
        sink.write(level: .notice, category: "capture", message: "newer", at: Self.moment)

        let logs = try XCTUnwrap(directory).appendingPathComponent("logs", isDirectory: true)
        let rotated = try String(contentsOf: logs.appendingPathComponent("backglance.1.log"), encoding: .utf8)
        let live = try String(contentsOf: sink.currentFile, encoding: .utf8)
        XCTAssertTrue(rotated.contains("aaa"), "the older content moved to .1")
        XCTAssertTrue(live.contains("newer"), "and the new line is in the live file")
    }

    // MARK: - Permissions

    /// 🔒 Same posture as the archive: `0600` in a `0700` directory. The file holds no
    /// content, but it does hold which apps notify this Mac and when, and that is nobody
    /// else's on a shared machine.
    func testTheFileAndItsDirectoryArePrivate() throws {
        let sink = try makeSink()
        sink.write(level: .notice, category: "capture", message: "something", at: Self.moment)

        let fileManager = FileManager.default
        let filePermissions = try fileManager.attributesOfItem(atPath: sink.currentFile.path)[.posixPermissions]
        let directoryPath = try XCTUnwrap(directory).appendingPathComponent("logs", isDirectory: true).path
        let directoryPermissions = try fileManager.attributesOfItem(atPath: directoryPath)[.posixPermissions]

        XCTAssertEqual(filePermissions as? Int, 0o600)
        XCTAssertEqual(directoryPermissions as? Int, 0o700)
    }

    // MARK: Private

    private static let moment = Date(timeIntervalSince1970: 1_787_389_964.318)

    private var directory: URL?

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileLogSinkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSink(
        minimumLevel: LogLevel = .debug,
        maximumFileSize: Int = 2 * 1_024 * 1_024,
        keptFiles: Int = 5
    ) throws -> FileLogSink {
        try FileLogSink(
            directory: XCTUnwrap(directory).appendingPathComponent("logs", isDirectory: true),
            minimumLevel: minimumLevel,
            maximumFileSize: maximumFileSize,
            keptFiles: keptFiles
        )
    }

    private func logFiles() throws -> [String] {
        let logs = try XCTUnwrap(directory).appendingPathComponent("logs", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(atPath: logs.path).sorted()
    }
}
