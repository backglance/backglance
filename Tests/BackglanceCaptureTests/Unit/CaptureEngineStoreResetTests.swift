@testable import BackglanceCapture
import BackglanceCore
import Foundation
import XCTest

/// ⚠️ `rec_id` only ever climbs while a store lives, so a tail below the cursor means the
/// store in front of us is not the one that cursor came from — the user reset their
/// notification database, or macOS replaced it. Resuming from the old cursor would skip
/// everything in the new store, quite possibly forever, which is the kind of failure
/// nobody notices until they go looking for a notification that was never archived.
final class CaptureEngineStoreResetTests: XCTestCase {
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

    /// The user reset their notification database, or macOS did. `rec_id` only ever climbs
    /// while a store lives, so a tail below the cursor means this is a different store —
    /// and resuming from the old cursor would skip everything in it, permanently.
    func testAStoreWhoseRecordsRestartIsReadFromTheBeginning() async throws {
        let engine = try XCTUnwrap(engine)
        let archive = try XCTUnwrap(archive)
        let storeURL = try XCTUnwrap(storeURL)
        try MiniatureStore.makeFile(at: storeURL, rows: (1 ... 6).map { MiniatureStore.notification(recID: Int64($0)) })
        await engine.start()
        await engine.tick(reason: .manual)

        // A brand-new store, numbering from 1 again.
        try FileManager.default.removeItem(at: storeURL)
        try MiniatureStore.makeFile(at: storeURL, rows: [
            MiniatureStore.notification(recID: 1, body: "After the reset"),
            MiniatureStore.notification(recID: 2, body: "Also after"),
        ])
        await engine.tick(reason: .poll)

        let metrics = await engine.metrics
        let bodies = try await archive.pool.read { db in
            try ArchivedNotification.fetchAll(db).compactMap(\.body)
        }
        XCTAssertEqual(metrics.storeResets, 1)
        XCTAssertTrue(bodies.contains("After the reset"), "the new store's notifications must be archived")
        XCTAssertTrue(bodies.contains("Also after"))
    }

    /// Forgetting the old store row ids is what makes that possible: without it the new
    /// store's first notifications would look like duplicates of ours and be dropped.
    func testAResetForgetsTheOldStoreRowIDsWithoutDeletingAnything() async throws {
        let engine = try XCTUnwrap(engine)
        let archive = try XCTUnwrap(archive)
        let storeURL = try XCTUnwrap(storeURL)
        try MiniatureStore.makeFile(at: storeURL, rows: (1 ... 4).map { MiniatureStore.notification(recID: Int64($0)) })
        await engine.start()
        await engine.tick(reason: .manual)
        let before = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }

        try FileManager.default.removeItem(at: storeURL)
        try MiniatureStore.makeFile(at: storeURL, rows: [MiniatureStore.notification(recID: 1, body: "Fresh")])
        await engine.tick(reason: .poll)

        let stored = try await archive.pool.read { db in try ArchivedNotification.fetchAll(db) }
        XCTAssertEqual(stored.count, before + 1, "nothing was deleted, and the new record was added")
        XCTAssertEqual(stored.filter { $0.storeRecId != nil }.count, 1, "only the new store's row keeps a rec id")
    }

    /// A store that simply has not grown since the last tick is not a reset.
    func testAnUnchangedStoreIsNotMistakenForAReset() async throws {
        let engine = try XCTUnwrap(engine)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: MiniatureStore.rows(3))
        await engine.start()
        await engine.tick(reason: .manual)

        await engine.tick(reason: .poll)

        let metrics = await engine.metrics
        XCTAssertEqual(metrics.storeResets, 0)
    }

    // MARK: Private

    private var archive: Archive?
    private var watcher: StoreWatcher?
    private var engine: CaptureEngine?
    private var directory: URL?
    private var storeURL: URL?

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureEngineStoreResetTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
