@testable import BackglanceSearch
import XCTest

final class VectorSimilarityTests: XCTestCase {
    // MARK: Internal

    // MARK: - cosine

    func testCosineOfAVectorWithItselfIsOne() {
        let vector = Self.ramp(seed: 1)

        XCTAssertEqual(VectorSimilarity.cosine(vector, vector), 1.0, accuracy: 1e-5)
    }

    func testCosineOfAVectorWithItsNegationIsMinusOne() {
        let vector = Self.ramp(seed: 1)
        let negated = vector.map { -$0 }

        XCTAssertEqual(VectorSimilarity.cosine(vector, negated), -1.0, accuracy: 1e-5)
    }

    func testCosineOfOrthogonalVectorsIsZero() {
        // Two axis-aligned vectors in first 512-dim space: nonzero only in disjoint halves.
        var first = [Float](repeating: 0, count: Embedding.dimensions)
        var second = [Float](repeating: 0, count: Embedding.dimensions)
        for i in 0 ..< (Embedding.dimensions / 2) {
            first[i] = 1
        }
        for i in (Embedding.dimensions / 2) ..< Embedding.dimensions {
            second[i] = 1
        }

        XCTAssertEqual(VectorSimilarity.cosine(first, second), 0.0, accuracy: 1e-5)
    }

    func testCosineOfMismatchedWidthsIsZero() {
        let first = Self.ramp(seed: 1)
        let second = Array(Self.ramp(seed: 1).prefix(10))

        XCTAssertEqual(VectorSimilarity.cosine(first, second), 0.0)
    }

    func testCosineOfAZeroVectorIsZeroNotNaN() {
        let zero = [Float](repeating: 0, count: Embedding.dimensions)
        let vector = Self.ramp(seed: 1)

        let score = VectorSimilarity.cosine(zero, vector)

        XCTAssertFalse(score.isNaN)
        XCTAssertEqual(score, 0.0)
    }

    func testCosineOfTwoZeroVectorsIsZeroNotNaN() {
        let zero = [Float](repeating: 0, count: Embedding.dimensions)

        let score = VectorSimilarity.cosine(zero, zero)

        XCTAssertFalse(score.isNaN)
        XCTAssertEqual(score, 0.0)
    }

    // MARK: - topK

    func testTopKReturnsKBestInDescendingOrder() {
        let query = Self.ramp(seed: 0)
        let candidates: [(id: Int64, vector: [Float])] = (0 ..< 10).map { i in
            (id: Int64(i), vector: Self.ramp(seed: i))
        }

        let results = VectorSimilarity.topK(query, among: candidates, k: 3)

        XCTAssertEqual(results.count, 3)
        for i in 1 ..< results.count {
            XCTAssertGreaterThanOrEqual(results[i - 1].score, results[i].score)
        }
        // seed 0 is the query itself, so it must be the top hit.
        XCTAssertEqual(results.first?.id, 0)
        XCTAssertEqual(results.first?.score ?? 0, 1.0, accuracy: 1e-5)
    }

    func testTopKRespectsThreshold() {
        let query = Self.ramp(seed: 0)
        let zeroVector = [Float](repeating: 0, count: Embedding.dimensions)
        let candidates: [(id: Int64, vector: [Float])] = [
            (id: 1, vector: query),
            (id: 2, vector: zeroVector),
        ]

        let results = VectorSimilarity.topK(query, among: candidates, k: 10, threshold: 0.9)

        XCTAssertEqual(results.map(\.id), [1], "the zero vector scores 0 and must not clear first 0.9 threshold")
    }

    func testTopKWithKLargerThanCandidateCountReturnsEverything() {
        let query = Self.ramp(seed: 0)
        let candidates: [(id: Int64, vector: [Float])] = (0 ..< 4).map { i in
            (id: Int64(i), vector: Self.ramp(seed: i))
        }

        let results = VectorSimilarity.topK(query, among: candidates, k: 1_000)

        XCTAssertEqual(results.count, candidates.count)
    }

    // MARK: Private

    private enum Embedding {
        static let dimensions = 512
    }

    // MARK: - Fixtures

    /// A deterministic, seeded ramp — never random — so every run compares the same vectors.
    private static func ramp(seed: Int) -> [Float] {
        (0 ..< Embedding.dimensions).map { Float(($0 + seed * 7) % 101) / 101 }
    }
}
