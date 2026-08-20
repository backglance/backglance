import BackglanceCore
import Foundation

// MARK: - EmbeddingIndexer

/// Walks the archive turning notifications into vectors, fifty at a time.
///
/// The work is genuinely large — every notification the user has ever received
/// — so it is a background job that can be stopped at any point and resumed
/// later without repeating itself: the queue is "notifications with no vector
/// yet", so progress is the database's, not a counter this actor has to keep
/// safe across a relaunch.
///
/// Each batch is one transaction and is followed by a short sleep. Both are
/// deliberate: fifty separate commits would be fifty fsyncs, and a tight loop
/// would compete with the capture path for the same writer. Indexing is never
/// urgent enough to make live capture wait.
///
/// See docs/features/SEARCH.md#semantic-search.
public actor EmbeddingIndexer {
    // MARK: Lifecycle

    public init(archive: Archive, index: SemanticIndex, batchSize: Int = 50) {
        self.archive = archive
        self.index = index
        self.batchSize = batchSize
        var captured: AsyncStream<Progress>.Continuation?
        progressStream = AsyncStream { captured = $0 }
        continuation = captured
    }

    deinit {
        continuation?.finish()
    }

    // MARK: Public

    /// How far along the run is. `total` is the size of the queue when the run
    /// started, so it does not creep upward as capture adds rows mid-run.
    public struct Progress: Sendable, Equatable {
        // MARK: Lifecycle

        public init(done: Int = 0, total: Int = 0) {
            self.done = done
            self.total = total
        }

        // MARK: Public

        public var done: Int
        public var total: Int

        /// `nil` when there is nothing to do — a progress bar for an empty
        /// queue is worse than no progress bar.
        public var fraction: Double? {
            total > 0 ? min(1, Double(done) / Double(total)) : nil
        }
    }

    /// Progress for the bar under the search field.
    nonisolated public let progressStream: AsyncStream<Progress>

    public private(set) var progress = Progress()

    /// Whether a run is in flight.
    public var isRunning: Bool {
        task != nil
    }

    /// Starts indexing, or does nothing if a run is already going.
    public func start() {
        guard task == nil else {
            return
        }
        task = Task(priority: .utility) { [weak self] in
            await self?.run()
        }
    }

    /// Stops the run where it is. The rows already embedded stay embedded, and
    /// the next `start()` picks up from the queue rather than the beginning.
    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Runs to completion — the form the tests use, and the one a caller wants
    /// when it needs the index warm before searching.
    public func runToCompletion() async {
        await run()
    }

    // MARK: Private

    private let archive: Archive
    private let index: SemanticIndex
    private let batchSize: Int
    private let continuation: AsyncStream<Progress>.Continuation?

    private var task: Task<Void, Never>?

    private func run() async {
        do {
            let counts = try archive.embeddingProgress()
            progress = Progress(done: 0, total: max(0, counts.total - counts.indexed))
            continuation?.yield(progress)

            while !Task.isCancelled {
                let batch = try archive.notificationsMissingEmbeddings(limit: batchSize)
                guard !batch.isEmpty else {
                    break
                }
                let embeddings = try await embed(batch)
                try archive.upsertEmbeddings(embeddings)

                progress.done += batch.count
                continuation?.yield(progress)
                // Let capture have the writer back before asking for it again.
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch is CancellationError {
            Log.search.info("embedding indexer cancelled at \(progress.done)/\(progress.total)")
        } catch let error as SemanticIndex.SemanticError {
            // The model is missing or the wrong shape. Semantic search stays
            // switched on in Settings, which shows the reason and a retry;
            // full-text search is untouched either way.
            Log.search.error("embedding indexer stopped: \(String(describing: error))")
        } catch {
            Log.search.error("embedding indexer stopped: \(String(describing: type(of: error)))")
        }
        task = nil
    }

    /// Embeds one batch, skipping rows there is nothing to embed for.
    ///
    /// A notification with no text at all — imports contain a few — is skipped
    /// rather than stored as a zero vector, which would match everything
    /// equally badly and pollute every scan that read it.
    private func embed(_ batch: [ArchivedNotification]) async throws -> [Embedding] {
        var embeddings: [Embedding] = []
        embeddings.reserveCapacity(batch.count)

        for notification in batch {
            try Task.checkCancellation()
            guard let id = notification.id else {
                continue
            }
            let text = SemanticIndex.embeddableText(
                title: notification.title,
                subtitle: notification.subtitle,
                body: notification.body
            )
            let values = try await index.embed(text)
            guard !values.isEmpty, let embedding = Embedding(notificationId: id, values: values) else {
                continue
            }
            embeddings.append(embedding)
        }
        return embeddings
    }
}
