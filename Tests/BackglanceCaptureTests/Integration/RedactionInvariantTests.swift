@testable import BackglanceCapture
import BackglanceCore
import BackglanceTestSupport
import Foundation
import GRDB
import XCTest

// MARK: - RedactionInvariantTests

/// 🔒 Privacy Invariant #2, checked the only way that is worth anything: by following a
/// real code through the real chain and then looking for its digits on disk.
///
/// The rule tests (`OTPRedactorRuleTests`) prove the matcher replaces a code in a string.
/// That is not the promise. The promise is that the digits are never *written* — not to
/// the archive, not to the FTS index, not to the write-ahead log, not to an audit row,
/// not to a log line. Every one of those is a separate place a copy could survive, and
/// three of them live inside one file, which is what makes the assertion here a byte scan
/// of that file rather than a query against it. A query only finds what the schema knows
/// about; a scan finds a copy the schema forgot.
///
/// The codes come from the checked-in fixtures, which mark their OTP-shaped records with
/// `userInfo["bg.fixture"] == "[synthetic-otp]"` and were generated from a seed — so this
/// file contains no code of its own, and the inputs are the same ones the parser tests
/// run against (docs/testing/TESTING.md#redaction-rule-tests).
///
/// > ℹ️ Exports are not covered here because there is no exporter yet. The diagnostics
/// > export ships with its own "excludes content" test in Phase 3.8, and `ExportService`
/// > with its own in Phase 6; both write from `notifications`, which this file proves is
/// > already redacted by the time anything can read it.
final class RedactionInvariantTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try Self.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        watcher?.stop()
        watcher = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - The whole chain, per fixture

    /// 🔒 The one that matters. Every OTP-shaped record in every fixture, captured the way
    /// the app captures, and then the archive file — database, index and WAL — searched
    /// for the digits byte by byte.
    func testNoCodeFromAnyFixtureSurvivesAnywhereInTheArchiveFile() async throws {
        try await forEachFixture { fixture in
            let codes = fixture.syntheticCodes
            // A vacuous pass is the failure mode this guards against: if the fixture
            // stopped carrying OTP records, every assertion below would hold trivially.
            XCTAssertFalse(codes.isEmpty, "\(fixture.name): no synthetic OTP records to check")
            try Self.assertPresent(codes, inFileAt: fixture.storeURL, context: "\(fixture.name) store")

            let archive = try await self.capture(fixture)

            for code in codes {
                for url in Self.archiveFiles(at: archive.url) {
                    let data = try Data(contentsOf: url)
                    XCTAssertFalse(
                        Self.data(data, contains: code),
                        "\(fixture.name): a code survived in \(url.lastPathComponent)"
                    )
                }
            }
        }
    }

    /// The same claim as a query rather than a scan: no column of any row holds a code.
    ///
    /// Redundant with the byte scan by design. The scan says "not on disk" and would fail
    /// just as loudly for a copy in an unrelated table; this one says *which* row is
    /// wrong, which is what a person debugging a red build needs first.
    func testNoArchivedRowCarriesACode() async throws {
        try await forEachFixture { fixture in
            let archive = try await self.capture(fixture)

            let rows = try await archive.handle.pool.read { db in try ArchivedNotification.fetchAll(db) }
            for row in rows {
                let text = [row.title, row.subtitle, row.body, row.sender]
                    .compactMap(\.self)
                    .joined(separator: " ")
                for code in fixture.syntheticCodes {
                    XCTAssertFalse(text.contains(code), "\(fixture.name): row \(row.uuid) carries a code")
                }
            }
        }
    }

    /// The FTS index is the copy people forget. It is an external-content table, so the
    /// postings are built by a trigger from whatever `notifications` holds — which is the
    /// point: searching for a code must find nothing, while searching for an ordinary word
    /// from the same notification must still find it, or the index is simply broken and
    /// the first half of this test proves nothing.
    func testACodeIsNotSearchableButTheNotificationCarryingItStillIs() async throws {
        try await forEachFixture { fixture in
            let archive = try await self.capture(fixture)

            for code in fixture.syntheticCodes {
                let hits = try await archive.handle.pool.read { db in
                    try Int.fetchOne(
                        db,
                        sql: "SELECT count(*) FROM notifications_fts WHERE notifications_fts MATCH ?",
                        arguments: [code]
                    ) ?? 0
                }
                XCTAssertEqual(hits, 0, "\(fixture.name): the FTS index can find a code")
            }

            let redactedHits = try await archive.handle.pool.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM notifications_fts WHERE notifications_fts MATCH ?",
                    arguments: ["redacted"]
                ) ?? 0
            }
            XCTAssertGreaterThan(redactedHits, 0, "\(fixture.name): the index found nothing at all")
        }
    }

    /// Every code that was removed left an audit row, and the audit row says only which
    /// pattern fired. `RedactionEvent` has no property that could hold text, so this
    /// checks the stored bytes of the table instead of its Swift shape — a column added
    /// later would be caught here rather than at the next review.
    func testTheAuditRowsRecordTheRedactionsAndNothingElse() async throws {
        try await forEachFixture { fixture in
            let archive = try await self.capture(fixture)

            let events = try await archive.handle.pool.read { db in try RedactionEvent.fetchAll(db) }
            XCTAssertFalse(events.isEmpty, "\(fixture.name): nothing was redacted")
            XCTAssertTrue(events.allSatisfy { $0.kind == .otp })
            XCTAssertTrue(events.allSatisfy { !$0.patternId.isEmpty })

            let stored: [GRDB.Row] = try await archive.handle.pool.read { db in
                try GRDB.Row.fetchAll(db, sql: "SELECT * FROM redactions")
            }
            for row in stored {
                let dumped = row.description
                for code in fixture.syntheticCodes {
                    XCTAssertFalse(dumped.contains(code), "\(fixture.name): an audit row carries a code")
                }
            }
        }
    }

    /// What a log line about one of these notifications would say, rendered every way a
    /// string interpolation can render it, carries no code.
    ///
    /// `LoggingTests` proves `NotificationLogRef` never renders content for a row somebody
    /// built by hand. This proves it for the rows that actually came out of the redactor,
    /// which is the case that would matter if the two ever drifted apart.
    func testNothingLoggableAboutARedactedNotificationCarriesACode() async throws {
        try await forEachFixture { fixture in
            let archive = try await self.capture(fixture)

            let rows = try await archive.handle.pool.read { db in try ArchivedNotification.fetchAll(db) }
            let rendered = rows
                .map { NotificationLogRef($0, bundleID: "com.apple.MobileSMS") }
                .flatMap { ["\($0)", String(describing: $0), String(reflecting: $0)] }
                .joined(separator: " ")
            for code in fixture.syntheticCodes {
                XCTAssertFalse(rendered.contains(code), "\(fixture.name): a log reference carries a code")
            }
        }
    }

    /// The gate is still a gate. With "Redact codes in all apps" off and Messages switched
    /// off by hand, the same fixture archives its codes verbatim — which is what makes the
    /// passes above evidence that redaction ran, rather than evidence that the fixture had
    /// nothing to redact.
    func testWithRedactionSwitchedOffTheSameCodesDoReachTheArchive() async throws {
        try await forEachFixture { fixture in
            let archive = try await self.capture(fixture) { handle in
                for bundleID in RedactionPolicy.defaultBundleIDs {
                    try handle.setRedactsOTP(false, bundleID: bundleID)
                }
            }

            let bodies = try await archive.handle.pool.read { db in
                try ArchivedNotification.fetchAll(db).compactMap(\.body).joined(separator: " ")
            }
            for code in fixture.syntheticCodes {
                XCTAssertTrue(bodies.contains(code), "\(fixture.name): the control case redacted anyway")
            }
        }
    }

    // MARK: Private

    // MARK: - Fixture

    /// One fixture's store and the codes its OTP-shaped records carry.
    private struct Fixture {
        let name: String
        let storeURL: URL

        /// Every digit run of code length in the OTP-shaped records, de-duplicated.
        ///
        /// Taken from the fixture's own `expected.json` rather than re-derived from the
        /// store, so this test reads the same ground truth the parser tests do.
        let syntheticCodes: [String]
    }

    // MARK: - CapturedArchive

    /// A file-backed archive and where it is, because "where it is" is what gets scanned.
    private struct CapturedArchive {
        let handle: Archive
        let url: URL
    }

    /// The fixture record marker the generator writes. Not a code — a label.
    private static let otpMarker = "[synthetic-otp]"

    private var directory: URL?
    private var watcher: StoreWatcher?

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RedactionInvariantTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The archive and the two files SQLite keeps beside it. The WAL is not an
    /// afterthought: it is where a row lives between the insert and the checkpoint, so a
    /// scan that skipped it would pass on a database that had not been checkpointed yet.
    private static func archiveFiles(at url: URL) -> [URL] {
        [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func data(_ data: Data, contains needle: String) -> Bool {
        data.firstRange(of: Data(needle.utf8)) != nil
    }

    /// Proves the input really did contain what the output must not.
    private static func assertPresent(_ codes: [String], inFileAt url: URL, context: String) throws {
        let bytes = try Data(contentsOf: url)
        for code in codes {
            XCTAssertTrue(data(bytes, contains: code), "\(context): expected the code in the input")
        }
    }

    /// Every 4–8 digit run in `text`, which is the shape `OTPPatterns` calls a code.
    ///
    /// Split by hand rather than by a regular expression, for the same reason
    /// `OTPPatterns` does: this file is about digits surviving, and a scanner that anyone
    /// can read line by line is worth more here than a pattern that has to be trusted.
    private static func codeShapedRuns(in text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for character in text + " " {
            if character.isNumber {
                current.append(character)
            } else {
                if (4 ... 8).contains(current.count) {
                    runs.append(current)
                }
                current = ""
            }
        }
        return runs
    }

    private func forEachFixture(_ body: (Fixture) async throws -> Void) async throws {
        let root = Fixtures.systemStore
        try XCTSkipUnless(Fixtures.exists(root), "SystemStore fixtures are missing")
        let directories = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("macOS") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertFalse(directories.isEmpty, "no fixtures found under \(root.path)")
        for directory in directories {
            try await body(load(directory))
        }
    }

    private func load(_ directory: URL) throws -> Fixture {
        struct Record: Decodable {
            var title: String?
            var subtitle: String?
            var body: String?
            var userInfo: [String: String]
        }
        struct File: Decodable {
            var notifications: [Record]
        }

        let file = try JSONDecoder().decode(
            File.self,
            from: Data(contentsOf: directory.appendingPathComponent("expected.json"))
        )
        let codes = file.notifications
            .filter { $0.userInfo["bg.fixture"] == Self.otpMarker }
            .flatMap { record in
                Self.codeShapedRuns(in: [record.title, record.subtitle, record.body]
                    .compactMap(\.self)
                    .joined(separator: " "))
            }

        return Fixture(
            name: directory.lastPathComponent,
            storeURL: directory.appendingPathComponent("store.db"),
            syntheticCodes: Array(Set(codes)).sorted()
        )
    }

    /// Runs one fixture store through an engine wired the way `AppDelegate` wires it, into
    /// a file-backed archive in this test's temporary directory.
    ///
    /// File-backed rather than `Archive(inMemory: true)`, which every other capture test
    /// uses: an in-memory database has no bytes to scan, and the bytes are the assertion.
    ///
    /// - Parameter configure: runs against the archive before capture starts, for the
    ///   control case that switches redaction off.
    private func capture(
        _ fixture: Fixture,
        configure: (Archive) throws -> Void = { _ in }
    ) async throws -> CapturedArchive {
        let directory = try XCTUnwrap(directory)
        let archiveURL = directory.appendingPathComponent("\(fixture.name)-\(UUID().uuidString).sqlite")
        let archive = try Archive(path: archiveURL.path)
        try configure(archive)

        let watcher = StoreWatcher(location: directory.appendingPathComponent("unused"), debounce: 0.01)
        self.watcher = watcher
        let storeURL = fixture.storeURL
        let defaults = try throwawayDefaults()
        let engine = CaptureEngine(
            archive: archive,
            watcher: watcher,
            redactor: PerAppOTPRedaction(defaults: defaults)
        ) { storeURL }

        try archive.captureFromTheStartOfTheStore()
        await engine.start()
        await engine.tick(reason: .manual)
        await engine.stop()

        let archived = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        XCTAssertGreaterThan(archived, 0, "\(fixture.name): capture archived nothing")

        return CapturedArchive(handle: archive, url: archiveURL)
    }

    private func throwawayDefaults() throws -> UserDefaults {
        let name = "app.backglance.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }
}
