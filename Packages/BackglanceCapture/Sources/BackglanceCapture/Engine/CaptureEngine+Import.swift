import BackglanceCore
import Foundation

// MARK: - ImportProgress

/// How far a first-launch import has got, for the onboarding screen's progress bar.
///
/// `expectedTotal` comes from the adapter's probe when it produced a count, and is `nil`
/// otherwise — which the UI renders as an indeterminate bar rather than as a guess.
public struct ImportProgress: Sendable, Equatable {
    // MARK: Lifecycle

    public init(scanned: Int, archived: Int, expectedTotal: Int? = nil, oldestSeen: Date? = nil) {
        self.scanned = scanned
        self.archived = archived
        self.expectedTotal = expectedTotal
        self.oldestSeen = oldestSeen
    }

    // MARK: Public

    /// Store records read so far, including ones that were excluded or already archived.
    public var scanned: Int

    /// Rows actually written.
    public var archived: Int

    /// What the probe said the store holds, if it said anything.
    public var expectedTotal: Int?

    /// The oldest delivery date seen so far — what the "from the last N days" line is
    /// built from.
    public var oldestSeen: Date?
}

// MARK: - ImportSummary

/// What an import did.
public struct ImportSummary: Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        archived: Int = 0,
        duplicates: Int = 0,
        excluded: Int = 0,
        failed: Int = 0,
        oldest: Date? = nil
    ) {
        self.archived = archived
        self.duplicates = duplicates
        self.excluded = excluded
        self.failed = failed
        self.oldest = oldest
    }

    // MARK: Public

    public var archived: Int
    public var duplicates: Int
    public var excluded: Int
    public var failed: Int

    /// The oldest notification the store still had.
    public var oldest: Date?

    // There is deliberately no `userSentence` here any more. It claimed in its own doc
    // comment to be "the one sentence onboarding shows", and it was not: onboarding builds
    // its text from the raw counts in `ImportProgressView.countSentence`, and a repository-
    // wide search found no other caller either — only the two tests that existed to test
    // it. A method kept alive solely by its own tests, while describing UI it is not, is
    // worse than no method, so it went (BACKGLANCE-216). If a caller ever wants the fuller
    // "this is all the system still had" line, it belongs next to the view that shows it,
    // where the string catalog's plural inflection actually resolves — see the note on
    // `ImportProgressView.countSentence`.
}

// MARK: - CaptureEngine + import

public extension CaptureEngine {
    /// Archives everything the store still holds, from the beginning.
    ///
    /// The one deliberately *backwards*-looking thing capture does. macOS keeps roughly a
    /// week of notifications and prunes the rest, so this is the user's only chance to
    /// keep what is already there — after which the archive only grows forwards.
    ///
    /// Three properties matter:
    ///
    /// - **The live cursor is not touched.** Import walks its own cursor from the start
    ///   while the live one stays at the tail, so a tick that lands mid-import still only
    ///   archives what is new. The two overlap by design and `store_rec_id` absorbs it.
    /// - **Re-running is safe.** Every row it re-reads is a duplicate, counted and
    ///   skipped. Settings offers "Import again" for people who granted Full Disk Access
    ///   after onboarding.
    /// - **Cancelling keeps what it archived** but does not record `last_import_at`, so
    ///   Settings still offers the import rather than pretending it happened.
    ///
    /// Runs on the engine's actor, so live ticks queue behind it; the timeline and search
    /// keep working on the archive throughout.
    ///
    /// - Parameter progress: called after each batch, on the actor.
    /// - Throws: ``CaptureError`` if the store cannot be read, or `CancellationError`.
    @discardableResult
    func importExisting(progress: (@Sendable (ImportProgress) async -> Void)? = nil) async throws -> ImportSummary {
        guard let adapter = currentAdapter else {
            // Nothing resolved an adapter, so there is nothing to read. The caller shows
            // the degraded reason it already has rather than a second error.
            throw CaptureError.degraded(.storeNotFound)
        }

        var summary = ImportSummary()
        var importCursor = StoreCursor.start
        var expectedTotal: Int?
        var scanned = 0

        while true {
            let batch = try readImportBatch(with: adapter, after: importCursor, expectedTotal: &expectedTotal)
            guard !batch.isEmpty else {
                break
            }

            for raw in batch {
                switch await archiveOne(raw, source: .imports) {
                case .archived,
                     .updated:
                    summary.archived += 1

                case .duplicate:
                    summary.duplicates += 1

                case .excluded:
                    summary.excluded += 1

                case .failed:
                    summary.failed += 1
                }

                if let delivered = raw.deliveredDate {
                    summary.oldest = min(summary.oldest ?? delivered, delivered)
                }
                importCursor = adapter.cursor(for: raw)
            }

            scanned += batch.count
            await progress?(ImportProgress(
                scanned: scanned,
                archived: summary.archived,
                expectedTotal: expectedTotal,
                oldestSeen: summary.oldest
            ))

            // Checked between batches, not within one: a batch that is already archived
            // should be finished and counted rather than half-attributed.
            try Task.checkCancellation()
        }

        try archive.saveLastImport(Date())
        let archived = summary.archived
        let duplicates = summary.duplicates
        let excluded = summary.excluded
        let failed = summary.failed
        Log.capture.notice("""
        import: \(archived) archived, \(duplicates) duplicate, \
        \(excluded) excluded, \(failed) failed
        """)
        return summary
    }
}

// MARK: - Reading

private extension CaptureEngine {
    /// One import batch, from its own snapshot.
    ///
    /// A snapshot per batch rather than one for the whole import: the copy is the user's
    /// entire notification history, and an import of a large store would otherwise hold
    /// it on disk for the duration.
    func readImportBatch(
        with adapter: any StoreAdapter,
        after cursor: StoreCursor,
        expectedTotal: inout Int?
    ) throws -> [RawStoreRecord] {
        let snapshot = try StoreSnapshot.take(of: storeURL())
        defer { snapshot.discard() }

        return try snapshot.read { db in
            if expectedTotal == nil, case let .ok(recordCount) = try adapter.probe(db) {
                expectedTotal = recordCount
            }
            return try adapter.records(after: cursor, in: db)
        }
    }
}
