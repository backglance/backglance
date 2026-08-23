import BackglanceCore
import BackglanceSearch
import BackglanceUI
import Foundation
import Observation

// MARK: - SearchService

/// The app's search, and the one place the engine meets the interface.
///
/// `BackglanceUI` cannot import `BackglanceSearch`
/// (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction), so the
/// view model asks its questions through `SearchRunning` and this is what
/// answers them. Everything the semantic feature owns — the model, the
/// background indexer, the setting that turns both on — lives here too, because
/// they are one decision from the user's point of view: "index my notifications
/// so I can search them by meaning".
@MainActor
@Observable
final class SearchService: SearchRunning {
    // MARK: Lifecycle

    /// - Parameter triage: the app's one `RulesEngine`, so `is:vip` and pinned-first
    ///   ordering in search settle against the same rules the timeline draws with.
    ///   `HybridSearch` already took a `triage` and already used it — for the `is:vip`
    ///   post-filter and the pinned tier — but this type never passed one, so it silently
    ///   defaulted to `NoTriage()` and evaluated every row as `Triage.none`: a VIP rule
    ///   matched nothing in search while highlighting rows in the timeline
    ///   (BACKGLANCE-241). Defaulted here too, for previews and for tests that do not
    ///   care, but the app always supplies the shared instance.
    init(
        archive: Archive,
        triage: any TriageEvaluating = NoTriage(),
        defaults: UserDefaults = .standard
    ) {
        self.archive = archive
        self.defaults = defaults
        let index = SemanticIndex(archive: archive)
        semantic = index
        indexer = EmbeddingIndexer(archive: archive, index: index)
        hybrid = HybridSearch(archive: archive, semantic: index, triage: triage)
        semanticEnabled = defaults.bool(forKey: Self.semanticEnabledKey)
    }

    // MARK: Internal

    /// `search.semanticEnabled` — off unless the user says otherwise, which is
    /// the whole posture of the feature: nothing is embedded until asked.
    static let semanticEnabledKey = "search.semanticEnabled"

    /// How far the background indexer has got. `nil` when it is not running.
    private(set) var indexProgress: (done: Int, total: Int)?

    /// Whether this Mac has the sentence model at all. `false` disables the
    /// toggle rather than hiding it — a missing model is worth explaining.
    private(set) var isSemanticAvailable = true

    var semanticEnabled: Bool {
        didSet {
            guard oldValue != semanticEnabled else {
                return
            }
            defaults.set(semanticEnabled, forKey: Self.semanticEnabledKey)
            if semanticEnabled {
                startIndexing()
            } else {
                stopIndexing()
            }
        }
    }

    /// `SearchRunning`: the view model's one question.
    nonisolated func search(_ query: SearchQuery, semanticEnabled: Bool) async throws -> [SearchHit] {
        try await hybrid.search(query, semanticEnabled: semanticEnabled)
    }

    /// Called at launch: picks the indexer back up if the user left it on, and
    /// records whether the model exists so Settings can say so.
    func start() {
        Task { [semantic] in
            let available = await semantic.isAvailable
            await MainActor.run { self.isSemanticAvailable = available }
            if await MainActor.run(body: { self.semanticEnabled }), available {
                await MainActor.run { self.startIndexing() }
            }
        }
    }

    /// Throws away every vector. Offered next to the toggle because turning the
    /// feature off should be able to mean "and forget what you learned", not
    /// just "stop learning".
    func deleteEmbeddings() {
        do {
            try archive.deleteAllEmbeddings()
            indexProgress = nil
        } catch {
            Log.search.error("could not delete embeddings: \(String(describing: type(of: error)))")
        }
    }

    // MARK: Private

    private let archive: Archive
    private let defaults: UserDefaults
    private let semantic: SemanticIndex
    private let indexer: EmbeddingIndexer
    private let hybrid: HybridSearch

    @ObservationIgnored private var progressTask: Task<Void, Never>?

    private func startIndexing() {
        progressTask?.cancel()
        let stream = indexer.progressStream
        progressTask = Task { @MainActor [weak self] in
            for await progress in stream {
                self?.indexProgress = (progress.done, progress.total)
            }
        }
        Task { [indexer] in await indexer.start() }
    }

    private func stopIndexing() {
        progressTask?.cancel()
        progressTask = nil
        indexProgress = nil
        Task { [indexer] in await indexer.stop() }
    }
}
