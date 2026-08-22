@testable import BackglanceCore
import BackglanceTestSupport
import Foundation
import GRDB
import XCTest

final class EmbeddingStoreTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - Packing

    func testAVectorRoundTripsThroughItsBlob() throws {
        let values = Self.values(seed: 1)
        let embedding = try XCTUnwrap(Embedding(notificationId: 1, values: values))

        XCTAssertEqual(embedding.dims, Embedding.dimensions)
        XCTAssertEqual(embedding.vector.count, Embedding.dimensions * 4, "512 Float32 is 2 KB, not a text encoding")
        XCTAssertEqual(embedding.values, values)
    }

    /// A short vector is a bug in the caller, and storing one would poison every
    /// comparison that later read it.
    func testAWrongWidthVectorIsRefused() {
        XCTAssertNil(Embedding(notificationId: 1, values: [1, 2, 3]))
        XCTAssertNil(Embedding(notificationId: 1, values: []))
    }

    func testATruncatedBlobDecodesAsNothingRatherThanGarbage() {
        let embedding = Embedding(notificationId: 1, dims: Embedding.dimensions, vector: Data([1, 2, 3]))

        XCTAssertNil(embedding.values)
    }

    // MARK: - Storage

    func testUpsertReplacesRatherThanAccumulating() throws {
        let archive = try XCTUnwrap(archive)
        let id = try seedNotification()

        try archive.upsertEmbedding(XCTUnwrap(Embedding(notificationId: id, values: Self.values(seed: 1))))
        try archive.upsertEmbedding(XCTUnwrap(Embedding(notificationId: id, values: Self.values(seed: 2))))

        let stored = try archive.embeddings()
        XCTAssertEqual(stored.count, 1, "one vector per notification, replaced on re-embed")
        XCTAssertEqual(stored.first?.values, Self.values(seed: 2))
    }

    func testABatchLandsInOneTransaction() throws {
        let archive = try XCTUnwrap(archive)
        let ids = try (0 ..< 5).map { _ in try seedNotification() }

        try archive.upsertEmbeddings(ids.compactMap { Embedding(notificationId: $0, values: Self.values(seed: 3)) })

        XCTAssertEqual(try archive.embeddings().count, 5)
    }

    func testAnEmptyBatchIsANoOp() throws {
        let archive = try XCTUnwrap(archive)

        try archive.upsertEmbeddings([])

        XCTAssertTrue(try archive.embeddings().isEmpty)
    }

    /// A vector is derived from a notification's text, so a deleted notification
    /// that left its vector behind would leave a machine-readable trace of what
    /// the user deleted. The cascade makes that a database guarantee.
    func testDeletingANotificationTakesItsVectorWithIt() throws {
        let archive = try XCTUnwrap(archive)
        let id = try seedNotification()
        try archive.upsertEmbedding(XCTUnwrap(Embedding(notificationId: id, values: Self.values(seed: 4))))

        try archive.pool.write { db in
            try db.execute(sql: "DELETE FROM notifications WHERE id = ?", arguments: [id])
        }

        XCTAssertTrue(try archive.embeddings().isEmpty)
    }

    /// Turning semantic search off has to mean the vectors are gone, not merely
    /// unused.
    func testDeletingEveryVectorLeavesTheNotificationsAlone() throws {
        let archive = try XCTUnwrap(archive)
        let id = try seedNotification()
        try archive.upsertEmbedding(XCTUnwrap(Embedding(notificationId: id, values: Self.values(seed: 5))))

        try archive.deleteAllEmbeddings()

        XCTAssertTrue(try archive.embeddings().isEmpty)
        XCTAssertEqual(try archive.timelinePage().count, 1)
    }

    // MARK: - The indexer's queue

    func testTheQueueIsWhatHasNoVectorYet() throws {
        let archive = try XCTUnwrap(archive)
        let ids = try (0 ..< 4).map { _ in try seedNotification() }
        try archive.upsertEmbedding(XCTUnwrap(Embedding(
            notificationId: XCTUnwrap(ids.first),
            values: Self.values(seed: 6)
        )))

        let pending = try archive.notificationsMissingEmbeddings(limit: 10)

        XCTAssertEqual(pending.compactMap(\.id), Array(ids.dropFirst()))
    }

    /// A model change is how a re-embed becomes findable: rows written by the
    /// old model are exactly the ones the queue returns.
    func testVectorsFromAnotherModelDoNotCountAsIndexed() throws {
        let archive = try XCTUnwrap(archive)
        let id = try seedNotification()
        try archive.upsertEmbedding(
            XCTUnwrap(Embedding(notificationId: id, values: Self.values(seed: 7), model: "nl.sentence.en.v0"))
        )

        XCTAssertEqual(try archive.notificationsMissingEmbeddings(limit: 10).compactMap(\.id), [id])
        XCTAssertTrue(try archive.embeddings().isEmpty, "the scan only ever compares vectors from one model")
    }

    func testProgressReportsIndexedAgainstTotal() throws {
        let archive = try XCTUnwrap(archive)
        let ids = try (0 ..< 3).map { _ in try seedNotification() }
        try archive.upsertEmbedding(XCTUnwrap(Embedding(
            notificationId: XCTUnwrap(ids.first),
            values: Self.values(seed: 8)
        )))

        let progress = try archive.embeddingProgress()

        XCTAssertEqual(progress.indexed, 1)
        XCTAssertEqual(progress.total, 3)
    }

    // MARK: - Migration

    func testTheEmbeddingsTableShipsWithTheSchema() throws {
        let archive = try XCTUnwrap(archive)

        let exists = try archive.pool.read { db in
            try db.tableExists("embeddings")
        }

        XCTAssertTrue(exists, "the migration runs unconditionally; the table is simply empty while the feature is off")
        XCTAssertGreaterThanOrEqual(
            BackglanceCore.archiveSchemaVersion,
            2,
            "embeddings arrived in v2; every version after it keeps the table"
        )
    }

    // MARK: Private

    private static let dimensions = Embedding.dimensions

    private var archive: Archive?

    /// Deterministic, obviously synthetic vectors: a seeded ramp, not random
    /// noise, so a failure prints something a human can compare.
    private static func values(seed: Int) -> [Float] {
        (0 ..< dimensions).map { Float(($0 + seed) % 97) / 97 }
    }

    private func seedNotification() throws -> Int64 {
        let archive = try XCTUnwrap(archive)
        let app = try archive.upsertApp(bundleID: Stubs.BundleID.slack, now: Stubs.epoch)
        let stored = try archive.insert(ArchivedNotification(
            uuid: UUID().uuidString,
            appId: XCTUnwrap(app.id),
            title: "Fixture message \(UUID().uuidString.prefix(6))",
            deliveredAt: UnixDate(Stubs.epoch),
            capturedAt: UnixDate(Stubs.epoch)
        ))
        return try XCTUnwrap(stored.id)
    }
}
