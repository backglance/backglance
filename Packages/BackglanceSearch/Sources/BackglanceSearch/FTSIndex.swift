import BackglanceCore
import Foundation
import GRDB

// MARK: - FTSHit

/// One row `FTSIndex.search` found, before `HybridSearch` merges it with fuzzy and
/// semantic hits.
///
/// `score` is the raw `bm25()` value: SQLite's convention is that *lower is better*
/// (it is a cost, not a similarity), which is why `HybridSearch` negates it before
/// combining ranks with the other engines rather than treating it as one more 0…1
/// score. See docs/features/SEARCH.md#fts-ranking-and-highlighting.
public struct FTSHit: Sendable, Equatable {
    public let notificationID: Int64
    public let score: Double
    public let snippet: String
}

// MARK: - FTSIndex

/// The full-text layer: one `MATCH` statement against `notifications_fts`, ranked
/// with per-column `bm25()` weights and highlighted with `snippet()`.
///
/// `FTSIndex` does not parse anything a user typed — it takes an already-built FTS5
/// `MATCH` expression from `QueryParser` and runs it. Keeping the grammar and the
/// query execution in separate types is what lets `QueryParser` be tested against
/// plain strings, with no database in the loop, and what lets `FTSIndex` be tested
/// against plain `MATCH` strings, with no grammar in the loop.
///
/// See docs/features/SEARCH.md#fts-ranking-and-highlighting.
public struct FTSIndex: Sendable {
    // MARK: Lifecycle

    public init(archive: Archive) {
        self.archive = archive
    }

    // MARK: Public

    /// Private-use scalars marking the start and end of a match inside a snippet.
    ///
    /// `notifications_fts`'s `snippet()`/`highlight()` need two marker strings to
    /// wrap a match in; U+E000 and U+E001 sit in the Private Use Area, so no
    /// notification's own title, body or sender can ever contain one and be
    /// mistaken for a match boundary. `BackglanceUI/MatchHighlighter` walks these
    /// back out into an `AttributedString`'s emphasis ranges.
    public static let markerOpen = "\u{E000}"
    public static let markerClose = "\u{E001}"

    /// Runs one FTS5 `MATCH` query and returns ranked, highlighted hits.
    ///
    /// `match` is a fully-built FTS5 expression — quoting, phrase syntax, `NOT`
    /// clauses and prefix stars are `QueryParser`'s job, not this method's. Every
    /// other piece of user-controlled data (`match` itself, `appIDs`) is bound as a
    /// statement argument; nothing is interpolated into the SQL string.
    ///
    /// Column weights favour the title (3.0) and sender (2.0) over the subtitle
    /// (1.5) and body (1.0), so a query that matches a sender name or a title
    /// outranks one that merely appears in a long body — the weight order mirrors
    /// the column order in `notifications_fts(title, subtitle, body, sender)`
    /// (see `ArchiveMigrations.ftsTableSQL`), so `bm25()`'s four positional
    /// arguments are `bm25(notifications_fts, titleWeight, subtitleWeight,
    /// bodyWeight, senderWeight)`.
    ///
    /// - Parameters:
    ///   - match: a prepared FTS5 `MATCH` expression, e.g. `"invoice"* AND
    ///     sender:"ayşe"*`.
    ///   - appIDs: restricts results to these `apps.id` values; empty means no
    ///     filter.
    ///   - limit: the most rows to return, applied in SQL so a broad query never
    ///     pulls more than this out of the database.
    /// - Throws: ``SearchError/indexUnavailable`` if `notifications_fts` does not
    ///   exist (only reachable mid-migration); rethrows any other database error.
    public func search(match: String, appIDs: [Int64] = [], limit: Int = 200) throws -> [FTSHit] {
        try withIndex { db in
            var sql = """
            SELECT n.id AS id,
                   bm25(notifications_fts, 3.0, 1.5, 1.0, 2.0) AS score,
                   snippet(notifications_fts, 2, char(57344), char(57345), '…', 12) AS snippet
            FROM notifications_fts
            JOIN notifications n ON n.id = notifications_fts.rowid
            WHERE notifications_fts MATCH ?
              AND n.is_deleted = 0
            """
            var arguments: StatementArguments = [match]

            if !appIDs.isEmpty {
                sql += " AND n.app_id IN (" + appIDs.map { _ in "?" }.joined(separator: ",") + ")"
                arguments += StatementArguments(appIDs)
            }

            sql += " ORDER BY score LIMIT ?"
            arguments += [limit]

            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                FTSHit(notificationID: row["id"], score: row["score"], snippet: row["snippet"])
            }
        }
    }

    /// Rebuilds the index from `notifications` from scratch.
    ///
    /// Worth running after a bulk import (thousands of rows land outside the
    /// per-insert trigger's normal rhythm and this gives the term dictionary a
    /// clean pass) or after `verify()`-equivalent tooling reports the index
    /// corrupt. It is the same `'rebuild'` command the `v1_fts` migration runs once
    /// to backfill archives created before FTS existed.
    public func rebuild() throws {
        try withIndex { db in
            try db.execute(sql: "INSERT INTO notifications_fts(notifications_fts) VALUES ('rebuild')")
        }
    }

    /// Merges the index's internal b-tree segments into one.
    ///
    /// Worth running after a large batch of deletions (retention pruning a lot of
    /// history at once, or a panic wipe of a subset of apps) — deletes leave behind
    /// tombstones that `'optimize'` compacts, which keeps `MATCH` queries fast
    /// without needing a full `'rebuild'`.
    public func optimize() throws {
        try withIndex { db in
            try db.execute(sql: "INSERT INTO notifications_fts(notifications_fts) VALUES ('optimize')")
        }
    }

    // MARK: Private

    private let archive: Archive

    /// Runs `body` against the archive, turning "the table isn't there" into
    /// ``SearchError/indexUnavailable`` instead of a raw GRDB error the UI has no
    /// sentence for. `notifications_fts` is only ever missing mid-migration; every
    /// other database failure is a genuine bug and is left to propagate as-is.
    /// GRDB's `read` rethrows exactly what `body` throws, so ``SearchError`` reaches
    /// the caller unwrapped.
    private func withIndex<T>(_ body: (Database) throws -> T) throws -> T {
        try archive.pool.read { db in
            guard try db.tableExists("notifications_fts") else {
                throw SearchError.indexUnavailable
            }
            return try body(db)
        }
    }
}
