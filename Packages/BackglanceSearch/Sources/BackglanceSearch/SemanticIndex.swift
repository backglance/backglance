import BackglanceCore
import Foundation
import GRDB
import NaturalLanguage

// MARK: - SemanticHit

/// One notification the semantic branch thinks is about the same thing as the
/// query, and how sure it is.
public struct SemanticHit: Sendable, Equatable {
    // MARK: Lifecycle

    public init(notificationID: Int64, similarity: Double) {
        self.notificationID = notificationID
        self.similarity = similarity
    }

    // MARK: Public

    public let notificationID: Int64

    /// Cosine similarity; 1.0 is identical.
    public let similarity: Double
}

// MARK: - SemanticIndex

/// Meaning-based search, on device and off by default.
///
/// Everything here runs against `NLEmbedding.sentenceEmbedding(for: .english)`,
/// which is the only sentence-level model Apple ships broadly on macOS 14+.
/// That has consequences worth stating plainly rather than hiding behind a
/// toggle: the model is **English**, so Turkish or German text gets a vector
/// whose geometry means little, and short queries are noise — under three words
/// the branch is skipped rather than allowed to return something confident and
/// wrong (docs/features/SEARCH.md#what-semantic-search-cannot-do).
///
/// The model asset is absent on some Macs. That is not an error state: the
/// setting stays visible but disabled, and every search quietly runs full text
/// and fuzzy only. A search that returns fewer kinds of hit is a much smaller
/// problem than a search that fails.
///
/// An actor because the query-side embed and the scan both take real time, and
/// serializing them keeps a fast typist from fanning out ten concurrent
/// embeddings.
public actor SemanticIndex {
    // MARK: Lifecycle

    public init(archive: Archive) {
        self.archive = archive
        embedding = NLEmbedding.sentenceEmbedding(for: .english)
    }

    // MARK: Public

    /// Why the semantic branch could not answer. Neither case fails a search:
    /// the caller drops the semantic source and returns what it has.
    public enum SemanticError: Error, Equatable, Sendable {
        /// The on-device English sentence model is not installed on this Mac.
        case modelUnavailable

        /// The model returned a width the archive is not storing. A guard
        /// against silently comparing vectors from two different spaces.
        case dimensionMismatch(expected: Int, got: Int)

        // MARK: Public

        /// One plain sentence for Settings. Never contains the query.
        public var userMessage: String {
            switch self {
            case .modelUnavailable:
                String(localized: """
                The on-device English sentence model isn't available on this Mac. \
                Semantic search is off; full-text search still works.
                """)

            case let .dimensionMismatch(expected, got):
                String(localized: "The embedding model returned \(got) dimensions, expected \(expected).")
            }
        }
    }

    /// The model identifier and width written into every row, shared with
    /// ``BackglanceCore/Embedding`` so the store and the scan cannot disagree.
    public static let modelID = Embedding.currentModel
    public static let dimensions = Embedding.dimensions

    /// Below this, a match is coincidence. Found by trial against the seeded
    /// test archive; not user-facing, and deliberately generous — the merge
    /// weights a weak semantic hit far below a strong full-text one anyway.
    public static let similarityFloor = 0.35

    /// Whether this Mac has the model at all.
    public var isAvailable: Bool {
        embedding != nil
    }

    /// The text a notification is embedded as: what a person would read, in
    /// reading order.
    ///
    /// Built from the *archived* fields, which are already redacted — so what
    /// gets embedded is the placeholder, never a one-time code (Privacy
    /// Invariant #2).
    nonisolated public static func embeddableText(
        title: String?,
        subtitle: String?,
        body: String?
    ) -> String {
        [title, subtitle, body]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The vector for a piece of text — used for the query side, and by the
    /// indexer for each notification.
    ///
    /// An empty array means "nothing to embed" (blank text), which is not an
    /// error; a missing model is.
    public func embed(_ text: String) throws -> [Float] {
        guard let embedding else {
            throw SemanticError.modelUnavailable
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let vector = embedding.vector(for: trimmed) else {
            return []
        }
        guard vector.count == Self.dimensions else {
            throw SemanticError.dimensionMismatch(expected: Self.dimensions, got: vector.count)
        }
        return vector.map(Float.init)
    }

    /// Scores stored vectors against `queryVector`, newest candidates first.
    ///
    /// The same app and date predicates the full-text branch applies are
    /// applied here, so the two branches are ranking the same population — a
    /// semantic hit from outside the user's `after:` filter would be a bug, not
    /// a bonus.
    ///
    /// Rows are walked with a cursor rather than fetched whole: at the
    /// candidate ceiling this would otherwise materialize 40 MB of vectors to
    /// produce fifty results. A vector whose blob is the wrong width is skipped
    /// rather than thrown on — one corrupt row must not fail a search.
    public func search(
        queryVector: [Float],
        appIDs: [Int64] = [],
        after: Date? = nil,
        before: Date? = nil,
        candidateLimit: Int = 20_000,
        topK: Int = 50
    ) throws -> [SemanticHit] {
        guard queryVector.count == Self.dimensions else {
            return []
        }
        let (sql, arguments) = Self.candidateQuery(
            appIDs: appIDs,
            after: after,
            before: before,
            candidateLimit: candidateLimit
        )

        return try archive.pool.read { db in
            var hits: [SemanticHit] = []
            let cursor = try Row.fetchCursor(db, sql: sql, arguments: arguments)
            while let row = try cursor.next() {
                try Task.checkCancellation()
                let blob: Data = row["vector"]
                guard blob.count == Self.dimensions * MemoryLayout<Float>.size else {
                    continue
                }
                let values = blob.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let similarity = VectorSimilarity.cosine(queryVector, values)
                if similarity > Self.similarityFloor {
                    hits.append(SemanticHit(notificationID: row["id"], similarity: similarity))
                }
            }
            hits.sort { $0.similarity > $1.similarity }
            return Array(hits.prefix(topK))
        }
    }

    // MARK: Internal

    /// The candidate scan, built once so the tests can read it and the search
    /// path stays about scoring rather than string building.
    static func candidateQuery(
        appIDs: [Int64],
        after: Date?,
        before: Date?,
        candidateLimit: Int
    ) -> (sql: String, arguments: StatementArguments) {
        var sql = """
        SELECT e.notification_id AS id, e.vector AS vector
        FROM embeddings e
        JOIN notifications n ON n.id = e.notification_id
        WHERE n.is_deleted = 0 AND e.model = ? AND e.dims = ?
        """
        var arguments: StatementArguments = [modelID, dimensions]

        if !appIDs.isEmpty {
            sql += " AND n.app_id IN (" + appIDs.map { _ in "?" }.joined(separator: ",") + ")"
            arguments += StatementArguments(appIDs)
        }
        if let after {
            sql += " AND n.delivered_at >= ?"
            arguments += [after.timeIntervalSince1970]
        }
        if let before {
            sql += " AND n.delivered_at < ?"
            arguments += [before.timeIntervalSince1970]
        }
        sql += " ORDER BY n.delivered_at DESC LIMIT ?"
        arguments += [candidateLimit]

        return (sql, arguments)
    }

    // MARK: Private

    private let archive: Archive
    private let embedding: NLEmbedding?
}
