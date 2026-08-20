@testable import BackglanceCapture
import BackglanceCore
import Foundation
import XCTest

/// Where live capture begins, which is a privacy question before it is a correctness one.
///
/// A fresh archive starts at the store's *tail*: everything already there predates the
/// install, and archiving it is `importExisting()`'s job — an explicit step the user
/// consents to, recorded as `source = 'import'`. Getting this wrong would silently
/// swallow a backlog nobody asked for (docs/features/CAPTURE.md#first-launch-import).
///
/// ⚠️ Nothing here reads `~/Library`: every store is a `MiniatureStore` in a temp
/// directory.
final class CaptureEngineFirstLaunchTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        let archive = try Archive(inMemory: true)
        let directory = try Self.temporaryDirectory()
        let watcher = StoreWatcher(location: directory.appendingPathComponent("db"), debounce: 0.01)

        self.archive = archive
        self.directory = directory
        self.watcher = watcher
        storeURL = directory.appendingPathComponent("db")
        engine = CaptureEngine(archive: archive, watcher: watcher) { directory.appendingPathComponent("db") }
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

    /// Resumable state. A cursor from a previous run is where the next tick starts.
    func testBootstrapResumesFromThePersistedCursor() async throws {
        let engine = try XCTUnwrap(engine)
        let archive = try XCTUnwrap(archive)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: MiniatureStore.rows(3))
        try archive.saveCursor(StoreCursor(lastRecID: 2, lastDeliveredDate: MiniatureStore.delivered))

        await engine.start()

        let cursor = await engine.currentCursor
        XCTAssertEqual(cursor.lastRecID, 2)
    }

    /// 🔒 The promise that keeps first launch honest: what is already in the store
    /// predates the install, so live capture starts *after* it rather than swallowing a
    /// backlog the user never agreed to archive. Backfilling it is `importExisting()`'s
    /// job, and it records those rows as `source = 'import'`
    /// (docs/features/CAPTURE.md#first-launch-import).
    func testAFirstLaunchStartsAtTheStoreTailRatherThanArchivingTheBacklog() async throws {
        let engine = try XCTUnwrap(engine)
        let archive = try XCTUnwrap(archive)
        // Archivable rows on purpose: `MiniatureStore.rows(_:)` carries payloads that do
        // not parse, so a count of zero would prove nothing here.
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: (1 ... 3).map {
            MiniatureStore.notification(recID: Int64($0))
        })

        await engine.start()
        await engine.tick(reason: .manual)

        let cursor = await engine.currentCursor
        let count = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        XCTAssertEqual(cursor.lastRecID, 3, "positioned past everything the store already held")
        XCTAssertEqual(count, 0, "the pre-existing backlog is the import's to archive, not live capture's")
    }

    /// The other half of the promise: starting at the tail must not mean starting deaf.
    /// What arrives *after* the install is exactly what live capture is for.
    func testAFirstLaunchStillCapturesWhatArrivesAfterIt() async throws {
        let engine = try XCTUnwrap(engine)
        let archive = try XCTUnwrap(archive)
        let storeURL = try XCTUnwrap(storeURL)
        try MiniatureStore.makeFile(at: storeURL, rows: (1 ... 3).map {
            MiniatureStore.notification(recID: Int64($0))
        })

        await engine.start()
        try MiniatureStore.append([MiniatureStore.notification(recID: 4, title: "New")], to: storeURL)
        await engine.tick(reason: .fileChanged)

        let stored = try await archive.pool.read { db in try ArchivedNotification.fetchAll(db) }
        XCTAssertEqual(stored.count, 1, "the one that arrived after we started, and only it")
        XCTAssertEqual(stored.first?.storeRecId, 4)
    }

    /// Persisted during bootstrap, so a crash before the first batch cannot rewind the
    /// engine into re-reading the backlog it deliberately skipped.
    func testTheFirstLaunchPositionIsPersistedImmediately() async throws {
        let engine = try XCTUnwrap(engine)
        let archive = try XCTUnwrap(archive)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: MiniatureStore.rows(4))

        await engine.start()

        try XCTAssertEqual(archive.loadCursor()?.lastRecID, 4)
    }

    /// An empty store has no tail to start at, so the two positions coincide — and the
    /// first notification to arrive is still captured.
    func testAFirstLaunchAgainstAnEmptyStoreStartsAtZero() async throws {
        let engine = try XCTUnwrap(engine)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [])

        await engine.start()

        let cursor = await engine.currentCursor
        XCTAssertEqual(cursor, .start)
    }

    /// The distinction ``Archive/clearCursor()`` documents: a *saved* `.start` means
    /// "read from the beginning" and must be obeyed, where the row's absence means
    /// "never read anything" and triggers the tail positioning above. The import path
    /// depends on the two not being conflated.
    func testASavedStartCursorIsHonouredRatherThanTreatedAsAFirstLaunch() async throws {
        let engine = try XCTUnwrap(engine)
        let archive = try XCTUnwrap(archive)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: (1 ... 3).map {
            MiniatureStore.notification(recID: Int64($0))
        })
        try archive.saveCursor(.start)

        await engine.start()
        await engine.tick(reason: .manual)

        let count = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        XCTAssertEqual(count, 3)
    }

    // MARK: Private

    private var archive: Archive!
    private var watcher: StoreWatcher!
    private var engine: CaptureEngine!
    private var directory: URL!
    private var storeURL: URL!

    private static func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CaptureEngineFirstLaunchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
