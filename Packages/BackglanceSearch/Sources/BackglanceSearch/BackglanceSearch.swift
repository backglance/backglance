import Foundation

/// Module marker for `BackglanceSearch`.
///
/// The real types (`FTSIndex`, `QueryParser`, `FuzzyMatcher`, the semantic index and
/// the hybrid ranker) land in Phase 2.
public enum BackglanceSearch {
    /// Weights the hybrid ranker combines its three signals with.
    ///
    /// Ported from PasteShelf's `HybridSearchEngine`; do not retune without a benchmark.
    public enum Weights {
        public static let fullText = 0.4
        public static let semantic = 0.5
        public static let fuzzy = 0.3
    }
}
