@testable import BackglanceCapture
import BackglanceCore
import Foundation
import XCTest

// MARK: - CaptureEngineImportTests

/// The one backwards-looking thing capture does. macOS keeps about a week of
/// notifications and prunes the rest, so this is the user's only chance to keep what is
/// already there — which is why re-running it, cancelling it and running it alongside
/// live capture all have to behave.
final class CaptureEngineImportTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        let archive = try Archive(inMemory: true)
        let directory = try Self.temporaryDirectory()
        let storeURL = directory.appendingPathComponent("db")
        let watcher = StoreWatcher(location: directory.appendingPathComponent("unused"), debounce: 0.01)

        self.archive = archive
        self.directory = directory
        self.storeURL = storeURL
        self.watcher = watcher
        engine = CaptureEngine(archive: archive, watcher: watcher) { storeURL }
    }

    override func tearDownWithError() throws {
        watcher?.stop()
        watcher = nil
        engine = nil
        archive = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Importing

    func testImportArchivesEverythingTheStoreStillHas() async throws {
        let engine = try XCTUnwrap(engine)
        let archive = try XCTUnwrap(archive)
        try Self.makeStore(at: XCTUnwrap(storeURL), notifications: 3)
        await engine.start()

        let summary = try await engine.importExisting()

        let stored = try await archive.pool.read { db in try ArchivedNotification.fetchAll(db) }
        XCTAssertEqual(summary.archived, 3)
        XCTAssertEqual(stored.count, 3)
        XCTAssertEqual(Set(stored.map(\.source)), [.imports], "imported rows must be tagged as such")
    }

    /// The cursor live capture uses sits at the tail. An import walking from the start
    /// must not drag it backwards, or the next tick would re-read the whole store.
    func testImportLeavesTheLiveCursorAlone() async throws {
        let engine = try XCTUnwrap(engine)
        try Self.makeStore(at: XCTUnwrap(storeURL), notifications: 4)
        await engine.start()
        await engine.tick(reason: .manual)
        let liveCursor = await engine.currentCursor

        _ = try await engine.importExisting()

        let afterImport = await engine.currentCursor
        XCTAssertEqual(afterImport, liveCursor)
        XCTAssertEqual(afterImport.lastRecID, 4)
    }

    /// "Import again", for people who granted Full Disk Access after onboarding. Every
    /// row it re-reads is a duplicate rather than a second copy.
    func testRunningTheImportTwiceArchivesNothingNew() async throws {
        let engine = try XCTUnwrap(engine)
        let archive = try XCTUnwrap(archive)
        try Self.makeStore(at: XCTUnwrap(storeURL), notifications: 3)
        await engine.start()

        _ = try await engine.importExisting()
        let second = try await engine.importExisting()

        let count = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        XCTAssertEqual(second.archived, 0)
        XCTAssertEqual(second.duplicates, 3)
        XCTAssertEqual(count, 3)
    }

    func testImportRecordsWhenItFinished() async throws {
        let engine = try XCTUnwrap(engine)
        let archive = try XCTUnwrap(archive)
        try Self.makeStore(at: XCTUnwrap(storeURL), notifications: 1)
        await engine.start()

        _ = try await engine.importExisting()

        try XCTAssertNotNil(archive.lastImportDate())
    }

    func testImportReportsProgressPerBatchWithTheProbesCount() async throws {
        let engine = try XCTUnwrap(engine)
        try Self.makeStore(at: XCTUnwrap(storeURL), notifications: 2)
        await engine.start()
        let reports = Reports()

        _ = try await engine.importExisting { progress in
            await reports.append(progress)
        }

        let seen = await reports.all
        XCTAssertEqual(seen.count, 1, "one batch, one report")
        XCTAssertEqual(seen.first?.scanned, 2)
        XCTAssertEqual(seen.first?.archived, 2)
        XCTAssertEqual(seen.first?.expectedTotal, 2, "the probe's count drives a determinate bar")
    }

    /// A store bigger than one batch. The adapter caps a batch at 500, so the loop has to
    /// keep going rather than stop at the first one.
    func testImportWalksBeyondASingleBatch() async throws {
        let engine = try XCTUnwrap(engine)
        let archive = try XCTUnwrap(archive)
        try Self.makeStore(at: XCTUnwrap(storeURL), notifications: 501)
        await engine.start()

        let summary = try await engine.importExisting()

        let count = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        XCTAssertEqual(summary.archived, 501)
        XCTAssertEqual(count, 501)
    }

    func testImportWithoutAnAdapterFails() async throws {
        let engine = try XCTUnwrap(engine)
        await engine.start()

        do {
            _ = try await engine.importExisting()
            XCTFail("expected a degraded error")
        } catch let error as CaptureError {
            XCTAssertEqual(error.degradedReason, .storeNotFound)
        }
    }

    // The two `userSentence` tests that used to sit here went with the method they were
    // the only callers of (BACKGLANCE-216). They are not worth reconstructing against
    // `ImportProgressView.countSentence` from this bundle: asserting the exact English of
    // a `String(localized:)` result cannot work here, because no test bundle in this
    // project has a `TEST_HOST` (BACKGLANCE-238), so `Bundle.main` is the xctest runner
    // rather than Backglance.app and the string catalog is never consulted.

    // MARK: Private

    private var archive: Archive?
    private var watcher: StoreWatcher?
    private var engine: CaptureEngine?
    private var directory: URL?
    private var storeURL: URL?

    private static func makeStore(at url: URL, notifications count: Int) throws {
        let rows = (1 ... count).map { MiniatureStore.notification(recID: Int64($0), body: "Body \($0)") }
        try MiniatureStore.makeFile(at: url, rows: rows)
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureEngineImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Reports

/// Collects progress callbacks, which arrive from the engine's actor.
private actor Reports {
    var all: [ImportProgress] = []

    func append(_ progress: ImportProgress) {
        all.append(progress)
    }
}
