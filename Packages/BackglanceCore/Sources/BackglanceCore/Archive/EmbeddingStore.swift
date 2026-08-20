import Foundation
import GRDB

// MARK: - Embedding

/// One notification's sentence vector.
///
/// The vector is stored as raw little-endian `Float32`, not as JSON or a
/// separated string: 512 dimensions is 2 KB packed and roughly 6 KB as text,
/// and every similarity scan reads every byte of every vector it compares. The
/// model name travels with it so that a future model change can find and
/// re-embed the rows written by the old one instead of silently comparing
/// vectors from two different spaces.
///
/// See docs/features/SEARCH.md#the-embeddings-table.
public struct Embedding: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    // MARK: Lifecycle

    public init(
        notificationId: Int64,
        model: String = Embedding.currentModel,
        dims: Int,
        vector: Data,
        createdAt: UnixDate = .now
    ) {
        self.notificationId = notificationId
        self.model = model
        self.dims = dims
        self.vector = vector
        self.createdAt = createdAt
    }

    /// Packs a vector, refusing anything that is not the expected width.
    ///
    /// A short or long vector is a programming error, not user input — every
    /// caller gets its values from one `NLEmbedding` — and storing one would
    /// poison every similarity comparison that later reads it.
    public init?(notificationId: Int64, values: [Float], model: String = Embedding.currentModel) {
        guard values.count == Embedding.dimensions else {
            return nil
        }
        self.init(
            notificationId: notificationId,
            model: model,
            dims: values.count,
            vector: Embedding.pack(values)
        )
    }

    // MARK: Public

    /// `NLEmbedding.sentenceEmbedding(for: .english)`'s width.
    public static let dimensions = 512

    /// The model identifier written into new rows. Bumping it is what makes a
    /// re-embed findable: rows with an older identifier are the ones to redo.
    public static let currentModel = "nl.sentence.en.v1"

    public static let databaseTableName = "embeddings"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    /// → `notifications.id`, `ON DELETE CASCADE`, and the primary key: one
    /// vector per notification, replaced rather than accumulated.
    public var notificationId: Int64
    public var model: String
    public var dims: Int
    public var vector: Data
    public var createdAt: UnixDate

    /// The stored bytes back as floats, or `nil` if the blob is not a whole
    /// number of `Float32`s — a truncated write rather than a vector.
    public var values: [Float]? {
        guard vector.count == dims * MemoryLayout<Float>.size else {
            return nil
        }
        return vector.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }

    /// Little-endian `Float32`, which is also the native layout on every Mac
    /// this runs on, so packing is a copy rather than a conversion.
    public static func pack(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

// MARK: - Archive + embeddings

public extension Archive {
    /// Stores one vector, replacing any earlier one for that notification.
    ///
    /// Upsert rather than insert because re-embedding is routine: a thread
    /// update rewrites a notification's text, and the vector for the old text
    /// is then simply wrong.
    func upsertEmbedding(_ embedding: Embedding) throws {
        do {
            try pool.write { db in
                try embedding.upsert(db)
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// Stores a batch in one transaction.
    ///
    /// The indexer works in batches of fifty precisely so this can be one
    /// transaction rather than fifty: each commit is an fsync, and fifty of
    /// them per batch is what would make background indexing audible on a
    /// spinning fan.
    func upsertEmbeddings(_ embeddings: [Embedding]) throws {
        guard !embeddings.isEmpty else {
            return
        }
        do {
            try pool.write { db in
                for embedding in embeddings {
                    try embedding.upsert(db)
                }
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// Every stored vector, for a brute-force similarity scan.
    ///
    /// Whole-table by design: at 100k notifications this is 200 MB of vectors,
    /// which is why the semantic branch is opt-in and why the scan is bounded
    /// by `limit` — see docs/features/SEARCH.md#semantic-search for the
    /// argument against shipping an ANN index for a personal archive.
    func embeddings(model: String = Embedding.currentModel, limit: Int? = nil) throws -> [Embedding] {
        do {
            return try pool.read { db in
                var request = Embedding.filter(Column("model") == model)
                if let limit {
                    request = request.limit(limit)
                }
                return try request.fetchAll(db)
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// Notifications that have no vector for `model` yet, oldest id first.
    ///
    /// The indexer's work queue. Ordered by id rather than by date so that a
    /// run interrupted halfway resumes where it stopped instead of re-walking
    /// the newest rows.
    func notificationsMissingEmbeddings(model: String = Embedding.currentModel,
                                        limit: Int) throws -> [ArchivedNotification]
    {
        do {
            let sql = """
            SELECT n.* FROM notifications n
            LEFT JOIN embeddings e ON e.notification_id = n.id AND e.model = ?
            WHERE n.is_deleted = 0 AND e.notification_id IS NULL
            ORDER BY n.id
            LIMIT ?
            """
            return try pool.read { db in
                try ArchivedNotification.fetchAll(db, sql: sql, arguments: [model, limit])
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// How many vectors exist, and how many notifications there are to embed —
    /// the two numbers the "Indexing 3,120 of 41,000" progress line needs.
    func embeddingProgress(model: String = Embedding.currentModel) throws -> (indexed: Int, total: Int) {
        do {
            return try pool.read { db in
                let indexed = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM embeddings WHERE model = ?",
                    arguments: [model]
                ) ?? 0
                let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notifications WHERE is_deleted = 0") ?? 0
                return (indexed, total)
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// Drops every vector — what turning semantic search off does.
    ///
    /// Off has to mean gone, not merely unused: the vectors are derived from
    /// notification text, so leaving them behind would keep a machine-readable
    /// copy of everything the user just asked not to have indexed.
    func deleteAllEmbeddings() throws {
        do {
            try pool.write { db in
                try db.execute(sql: "DELETE FROM embeddings")
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }
}
