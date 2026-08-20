import Accelerate
import Foundation

// MARK: - VectorSimilarity

/// Cosine similarity and top-K ranking over `NLEmbedding` vectors.
///
/// Brute force, on purpose. A personal archive tops out around 100k notifications — 100k ×
/// 512 `Float32` is 200 MB, and a linear scan over that is a matter of milliseconds on
/// Apple silicon (`vDSP` does the dot product and both magnitudes in native code, not a
/// Swift loop). An approximate-nearest-neighbor index would need to be built, kept warm,
/// and kept in sync with every insert, update and retention delete the archive already does
/// — a second index shadowing the first, for a speedup nobody sitting in front of a search
/// bar would notice. See docs/features/SEARCH.md#semantic-search.
public enum VectorSimilarity {
    /// Cosine similarity of `a` and `b`, in `-1...1`.
    ///
    /// Returns `0` — never `NaN` — when the widths differ or either vector has zero
    /// magnitude. A `NaN` score would compare unequal to everything, including itself,
    /// which is exactly the kind of thing that silently scrambles a sort: `topK` and any
    /// caller downstream of it assume every score is an ordinary comparable `Double`.
    public static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else {
            return 0
        }
        let count = vDSP_Length(lhs.count)
        var dot: Float = 0
        vDSP_dotpr(lhs, 1, rhs, 1, &dot, count)

        var magLHS: Float = 0
        vDSP_svesq(lhs, 1, &magLHS, count)
        var magRHS: Float = 0
        vDSP_svesq(rhs, 1, &magRHS, count)

        let denominator = Double(magLHS.squareRoot()) * Double(magRHS.squareRoot())
        guard denominator > 0 else {
            return 0
        }
        return Double(dot) / denominator
    }

    /// The `k` best-scoring candidates against `query`, descending, with score at or above
    /// `threshold`.
    ///
    /// Brute force over `candidates` — see the type doc comment for why that is the right
    /// call here rather than an ANN index. `k` larger than the candidate count simply
    /// returns everything that cleared `threshold`.
    public static func topK(
        _ query: [Float],
        among candidates: [(id: Int64, vector: [Float])],
        k: Int,
        threshold: Double = 0
    ) -> [(id: Int64, score: Double)] {
        guard k > 0 else {
            return []
        }
        var scored: [(id: Int64, score: Double)] = []
        scored.reserveCapacity(candidates.count)
        for candidate in candidates {
            let score = cosine(query, candidate.vector)
            if score >= threshold {
                scored.append((id: candidate.id, score: score))
            }
        }
        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(k))
    }
}
