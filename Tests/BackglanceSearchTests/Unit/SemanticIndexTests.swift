import BackglanceCore
@testable import BackglanceSearch
import BackglanceTestSupport
import Foundation
import GRDB
import XCTest

// MARK: - SemanticIndexTests

final class SemanticIndexTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - The text that gets embedded

    /// Reading order, joined the way a person would read it — and built from
    /// the archived fields, which are already redacted, so what is embedded is
    /// the placeholder rather than a code.
    func testEmbeddableTextJoinsWhatIsThere() {
        XCTAssertEqual(
            SemanticIndex.embeddableText(title: "Deploy finished", subtitle: "main", body: "Fixture message 000042"),
            "Deploy finished · main · Fixture message 000042"
        )
        XCTAssertEqual(
            SemanticIndex.embeddableText(title: "Deploy finished", subtitle: nil, body: nil),
            "Deploy finished"
        )
        XCTAssertEqual(
            SemanticIndex.embeddableText(title: nil, subtitle: "", body: "[code redacted]"),
            "[code redacted]"
        )
        XCTAssertEqual(SemanticIndex.embeddableText(title: nil, subtitle: nil, body: nil), "")
    }

    // MARK: - The candidate scan

    /// The semantic branch has to rank the same population the full-text branch
    /// does: a hit from outside the user's `after:` filter would be a bug, not
    /// a bonus.
    func testTheCandidateQueryAppliesTheSameFiltersFullTextDoes() {
        let (sql, _) = SemanticIndex.candidateQuery(
            appIDs: [1, 2],
            after: Stubs.epoch,
            before: Stubs.epoch.addingTimeInterval(3_600),
            candidateLimit: 100
        )

        XCTAssertTrue(sql.contains("n.is_deleted = 0"), sql)
        XCTAssertTrue(sql.contains("e.model = ?"), "only ever one model's vectors in one scan")
        XCTAssertTrue(sql.contains("n.app_id IN (?,?)"), sql)
        XCTAssertTrue(sql.contains("n.delivered_at >= ?"), sql)
        XCTAssertTrue(sql.contains("n.delivered_at < ?"), sql)
        XCTAssertTrue(sql.hasSuffix("ORDER BY n.delivered_at DESC LIMIT ?"), sql)
    }

    func testWithoutFiltersTheScanIsUnrestricted() {
        let (sql, arguments) = SemanticIndex.candidateQuery(appIDs: [], after: nil, before: nil, candidateLimit: 10)

        XCTAssertFalse(sql.contains("app_id IN"))
        XCTAssertFalse(sql.contains("delivered_at >="), "no date filter, though the ordering still names the column")
        XCTAssertFalse(sql.contains("delivered_at <"))
        XCTAssertTrue(arguments.description.contains("nl.sentence.en.v1"), arguments.description)
    }

    // MARK: - Scoring

    func testAQueryVectorOfTheWrongWidthScoresNothing() async throws {
        let index = try SemanticIndex(archive: XCTUnwrap(archive))

        let hits = try await index.search(queryVector: [1, 2, 3])

        XCTAssertTrue(hits.isEmpty, "a mismatched width is a caller bug, not a search with no results")
    }

    /// The scan ranks by cosine and keeps only what clears the floor, so an
    /// identical vector comes first and an opposite one is not returned at all.
    func testStoredVectorsAreRankedAgainstTheQuery() async throws {
        let archive = try XCTUnwrap(archive)
        let identical = try seed(vector: Self.ramp(seed: 1))
        let opposite = try seed(vector: Self.ramp(seed: 1).map { -$0 })
        let unrelated = try seed(vector: Self.ramp(seed: 40))

        let index = SemanticIndex(archive: archive)
        let hits = try await index.search(queryVector: Self.ramp(seed: 1))

        XCTAssertEqual(hits.first?.notificationID, identical)
        XCTAssertEqual(hits.first?.similarity ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertFalse(hits.contains { $0.notificationID == opposite }, "an opposite vector is below the floor")
        XCTAssertTrue(hits.contains { $0.notificationID == unrelated } || hits.count == 1)
    }

    func testACorruptVectorIsSkippedRatherThanFailingTheSearch() async throws {
        let archive = try XCTUnwrap(archive)
        let good = try seed(vector: Self.ramp(seed: 2))
        let broken = try seedNotification()
        let insert = """
        INSERT INTO embeddings(notification_id, model, dims, vector, created_at)
        VALUES (?, ?, ?, ?, ?)
        """
        // `await`: inside an async test GRDB resolves `write` to its async overload.
        try await archive.pool.write { db in
            try db.execute(
                sql: insert,
                arguments: [broken, Embedding.currentModel, Embedding.dimensions, Data([1, 2, 3]), 0]
            )
        }

        let hits = try await SemanticIndex(archive: archive).search(queryVector: Self.ramp(seed: 2))

        XCTAssertEqual(hits.map(\.notificationID), [good], "one corrupt row must not fail the whole search")
    }

    func testTopKBoundsTheResult() async throws {
        let archive = try XCTUnwrap(archive)
        for offset in 0 ..< 5 {
            _ = try seed(vector: Self.ramp(seed: 1 + offset))
        }

        let hits = try await SemanticIndex(archive: archive).search(queryVector: Self.ramp(seed: 1), topK: 2)

        XCTAssertLessThanOrEqual(hits.count, 2)
    }

    // MARK: - Availability

    /// The model asset is missing on some Macs. That is a state, not a failure:
    /// the toggle stays visible and disabled, and search runs without it.
    func testTheModelReportsWhetherItIsAvailableAtAll() async throws {
        let index = try SemanticIndex(archive: XCTUnwrap(archive))

        let available = await index.isAvailable
        if available {
            let vector = try await index.embed("Fixture message about an invoice")
            XCTAssertEqual(vector.count, SemanticIndex.dimensions)
            let blank = try await index.embed("   ")
            XCTAssertTrue(blank.isEmpty, "blank text is nothing to embed, not an error")
        } else {
            do {
                _ = try await index.embed("fixture text")
                XCTFail("a missing model has to be reported, not silently empty")
            } catch {
                XCTAssertEqual(error as? SemanticIndex.SemanticError, .modelUnavailable)
            }
        }
    }

    // MARK: Private

    private var archive: Archive?

    /// A deterministic ramp — a stand-in for a sentence vector that a human can
    /// compare when an assertion fails.
    private static func ramp(seed: Int) -> [Float] {
        (0 ..< Embedding.dimensions).map { Float(($0 &* 7 &+ seed) % 101) / 101 }
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

    @discardableResult
    private func seed(vector: [Float]) throws -> Int64 {
        let archive = try XCTUnwrap(archive)
        let id = try seedNotification()
        try archive.upsertEmbedding(XCTUnwrap(Embedding(notificationId: id, values: vector)))
        return id
    }
}
