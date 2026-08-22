@testable import BackglanceCore
import Foundation
import XCTest

/// 🔒 The export exists so a user can send a maintainer a diagnostic bundle without having to
/// trust anybody about what is in it. These tests are the mechanism behind that: an archive
/// seeded with recognisable content, and an assertion that not one byte of it appears in any
/// file the export would ship.
final class DiagnosticsExportTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
        directory = try Self.temporaryDirectory()
        let name = "app.backglance.tests.\(UUID().uuidString)"
        suiteName = name
        defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    }

    override func tearDownWithError() throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        defaults = nil
        suiteName = nil
        directory = nil
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - The exclusion

    /// The test the whole feature rests on. Every string a notification can hold is seeded
    /// into the archive; none of them may appear anywhere in the bundle.
    func testTheExportContainsNoArchiveText() throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive)

        let files = try build()

        let everything = files.values.compactMap { String(bytes: $0, encoding: .utf8) }.joined(separator: "\n")
        for secret in Self.secrets {
            XCTAssertFalse(everything.contains(secret), "\"\(secret)\" reached the diagnostics export")
        }
    }

    /// 🔒 Which apps notify you is itself personal — a dating app, a psychiatrist's booking
    /// system, a union's messenger. The counts ship anonymised unless the user says otherwise.
    func testAppIdentifiersAreAnonymisedByDefault() throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive)

        let counts = try string(from: build(), named: "app_counts.json")

        XCTAssertFalse(counts.contains("com.example.bank"), counts)
        XCTAssertTrue(counts.contains("app-01"), counts)
    }

    func testAppIdentifiersAppearOnlyWhenOptedIn() throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive)

        let files = try build(options: .init(includeAppIdentifiers: true))

        try XCTAssertTrue(string(from: files, named: "app_counts.json").contains("com.example.bank"))
        // Recorded in the bundle, so a reader never has to guess whether `app-01` is an
        // anonymised label or an app literally called that.
        try XCTAssertTrue(string(from: files, named: "manifest.json").contains("\"contains_app_names\" : \"true\""))
    }

    /// The noisiest app is `app-01`, which is the shape a "why is Backglance slow" report
    /// needs without naming anything.
    func testCountsAreOrderedLoudestFirst() throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, bundleID: "com.example.quiet", count: 1)
        try seed(archive, bundleID: "com.example.loud", count: 5, startingRecID: 100)

        let counts = try string(from: build(), named: "app_counts.json")
        let firstCount = try XCTUnwrap(counts.components(separatedBy: "\"count\" : \"").dropFirst().first)

        XCTAssertTrue(firstCount.hasPrefix("5"), counts)
    }

    // MARK: - The settings snapshot

    /// 🔒 An allow-list, never a dump of the suite. A future setting holding something
    /// personal would otherwise be exported the day it was added, by code nobody revisited.
    func testOnlyAllowListedSettingsAreExported() throws {
        let defaults = try XCTUnwrap(defaults)
        defaults.set("30d", forKey: "privacy.globalRetention")
        defaults.set("my psychiatrist", forKey: "search.lastQuery")

        let snapshot = try string(from: build(), named: "settings_snapshot.json")

        XCTAssertTrue(snapshot.contains("privacy.globalRetention"), snapshot)
        XCTAssertFalse(snapshot.contains("my psychiatrist"), "a key nobody allow-listed was exported")
        XCTAssertFalse(snapshot.contains("search.lastQuery"), snapshot)
    }

    /// The list itself is the thing to review, so it is asserted rather than left implicit.
    func testTheAllowListHoldsNoKeyThatCouldCarryText() {
        for key in DiagnosticsExport.exportableSettingKeys {
            XCTAssertFalse(key.contains("query"), "\(key) could hold a search string")
            XCTAssertFalse(key.contains("rule"), "\(key) could hold a user's keyword")
            XCTAssertFalse(key.contains("saved"), "\(key) could hold a saved search")
        }
    }

    // MARK: - The contents

    func testTheBundleHasEveryDocumentedFile() throws {
        let files = try build()

        XCTAssertEqual(
            Set(files.keys),
            [
                "manifest.json",
                "adapter.json",
                "capture_status_history.json",
                "app_counts.json",
                "archive_stats.json",
                "settings_snapshot.json",
                "log_tail.txt",
            ]
        )
    }

    /// Counts and pragmas, which is what makes the exclusion a property of the code rather
    /// than a promise about it.
    func testArchiveStatsAreCountsAndPragmas() throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive)

        let stats = try string(from: build(), named: "archive_stats.json")

        XCTAssertTrue(stats.contains("\"rows_notifications\" : \"3\""), stats)
        XCTAssertTrue(stats.contains("\"integrity_ok\" : \"true\""), stats)
        XCTAssertTrue(stats.contains("byte_count"), stats)
    }

    /// The log tail comes from a file that is already content-free by construction, and the
    /// export takes only its end.
    func testTheLogTailIsBoundedAndTakenFromTheEnd() throws {
        let logs = try XCTUnwrap(directory).appendingPathComponent("logs", isDirectory: true)
        let sink = FileLogSink(directory: logs, minimumLevel: .debug)
        for index in 0 ..< 20 {
            sink.write(level: .notice, category: "capture", message: "line \(index)", at: Date())
        }

        let tail = try string(from: build(options: .init(logTailLines: 5)), named: "log_tail.txt")

        XCTAssertTrue(tail.contains("line 19"), tail)
        XCTAssertFalse(tail.contains("line 3 "), "older lines should have been dropped")
    }

    func testAMissingLogIsAnEmptyTailRatherThanAFailure() throws {
        let tail = try string(from: build(), named: "log_tail.txt")

        XCTAssertTrue(tail.isEmpty)
    }

    // MARK: - Writing it out

    func testWritingProducesAZipTheUserCanOpen() throws {
        let files = try build()

        let zip = try DiagnosticsExport.write(files)

        XCTAssertEqual(zip.pathExtension, "zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
        let size = try FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0)
        try? FileManager.default.removeItem(at: zip.deletingLastPathComponent())
    }

    // MARK: Private

    private static let title = "Aurora Bank"
    private static let body = "Your verification code is 314159"
    private static let sender = "+90 555 000 11 22"
    private static let secrets = [title, body, sender, "314159"]

    private var archive: Archive?
    private var directory: URL?
    private var defaults: UserDefaults?
    private var suiteName: String?

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func build(options: DiagnosticsExport.Options = .init()) throws -> [String: Data] {
        try DiagnosticsExport.build(
            archive: XCTUnwrap(archive),
            options: options,
            environment: DiagnosticsExport.Environment(
                appVersion: "0.4.0",
                appBuild: "42",
                osVersion: "Version 26.0",
                architecture: "arm64",
                defaults: XCTUnwrap(defaults)
            ),
            statusHistory: ["running", "degraded: no full disk access"],
            logDirectory: XCTUnwrap(directory).appendingPathComponent("logs", isDirectory: true)
        )
    }

    private func string(from files: [String: Data], named name: String) throws -> String {
        try XCTUnwrap(String(bytes: XCTUnwrap(files[name]), encoding: .utf8))
    }

    private func seed(
        _ archive: Archive,
        bundleID: String = "com.example.bank",
        count: Int = 3,
        startingRecID: Int64 = 1
    ) throws {
        let now = Date()
        let app = try archive.upsertApp(bundleID: bundleID, now: now)
        for index in 0 ..< count {
            let notification = try ArchivedNotification(
                uuid: UUID().uuidString,
                appId: XCTUnwrap(app.id),
                title: Self.title,
                body: Self.body,
                sender: Self.sender,
                deliveredAt: UnixDate(now),
                capturedAt: UnixDate(now),
                storeRecId: startingRecID + Int64(index)
            )
            _ = try archive.insertOrUpdate(notification)
        }
    }
}
