import BackglanceCore
@testable import BackglanceSearch
import BackglanceTestSupport
import Foundation
import XCTest

final class EmbeddingIndexerTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - Progress

    func testAnEmptyArchiveHasNothingToIndex() async throws {
        let indexer = try makeIndexer()

        await indexer.runToCompletion()

        let progress = await indexer.progress
        XCTAssertEqual(progress, EmbeddingIndexer.Progress(done: 0, total: 0))
        XCTAssertNil(progress.fraction, "a progress bar for an empty queue is worse than none")
    }

    func testProgressIsAFractionOnlyWhenThereIsWorkToDo() {
        XCTAssertNil(EmbeddingIndexer.Progress(done: 0, total: 0).fraction)
        XCTAssertEqual(EmbeddingIndexer.Progress(done: 25, total: 100).fraction, 0.25)
        XCTAssertEqual(
            EmbeddingIndexer.Progress(done: 120, total: 100).fraction,
            1,
            "capture can add rows mid-run; the bar must not overrun"
        )
    }

    /// The queue is the database's, so a run that stops halfway and starts
    /// again picks up where it left off instead of re-embedding everything.
    func testTheQueueShrinksAsVectorsLand() throws {
        let archive = try XCTUnwrap(archive)
        for _ in 0 ..< 3 {
            _ = try seedNotification()
        }
        let before = try archive.notificationsMissingEmbeddings(limit: 10).count
        try archive.upsertEmbedding(XCTUnwrap(Embedding(
            notificationId: XCTUnwrap(archive.timelinePage().first?.id),
            values: Self.ramp()
        )))

        let after = try archive.notificationsMissingEmbeddings(limit: 10).count

        XCTAssertEqual(before, 3)
        XCTAssertEqual(after, 2)
    }

    // MARK: - Running

    func testStoppingBeforeStartingIsHarmless() async throws {
        let indexer = try makeIndexer()

        await indexer.stop()

        let running = await indexer.isRunning
        XCTAssertFalse(running)
    }

    /// Where the model exists, a run leaves every notification embedded; where
    /// it does not, the run ends quietly and full-text search is unaffected.
    func testARunEmbedsEverythingOrEndsQuietly() async throws {
        let archive = try XCTUnwrap(archive)
        for _ in 0 ..< 3 {
            _ = try seedNotification()
        }
        let index = SemanticIndex(archive: archive)
        let available = await index.isAvailable
        let indexer = EmbeddingIndexer(archive: archive, index: index, batchSize: 2)

        await indexer.runToCompletion()

        let stored = try archive.embeddings().count
        if available {
            XCTAssertEqual(stored, 3, "every seeded notification has text to embed")
            XCTAssertTrue(try archive.notificationsMissingEmbeddings(limit: 10).isEmpty)
        } else {
            XCTAssertEqual(stored, 0, "no model, no vectors — and no failure either")
        }
    }

    // MARK: Private

    private var archive: Archive?

    private static func ramp() -> [Float] {
        (0 ..< Embedding.dimensions).map { Float($0 % 97) / 97 }
    }

    private func makeIndexer() throws -> EmbeddingIndexer {
        let archive = try XCTUnwrap(archive)
        return EmbeddingIndexer(archive: archive, index: SemanticIndex(archive: archive))
    }

    @discardableResult
    private func seedNotification() throws -> Int64 {
        let archive = try XCTUnwrap(archive)
        let app = try archive.upsertApp(bundleID: Stubs.BundleID.slack, now: Stubs.epoch)
        let stored = try archive.insert(ArchivedNotification(
            uuid: UUID().uuidString,
            appId: XCTUnwrap(app.id),
            title: "Fixture message \(UUID().uuidString.prefix(6))",
            body: "Deploy finished",
            deliveredAt: UnixDate(Stubs.epoch),
            capturedAt: UnixDate(Stubs.epoch)
        ))
        return try XCTUnwrap(stored.id)
    }
}
