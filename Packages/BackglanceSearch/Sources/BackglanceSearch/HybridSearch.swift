import BackglanceCore
import Foundation
import GRDB

// MARK: - HybridSearch

/// The search engine: full text, then fuzzy and — if the user turned it on —
/// semantic, fused into one ranked list.
///
/// The three branches answer different questions. Full text finds the word you
/// typed. Fuzzy finds the word you *meant* when you typed it wrong. Semantic
/// finds the notification you are describing rather than quoting. They only
/// help together if their scores can be compared, and they cannot: bm25 is
/// negative and unbounded, cosine is 0…1, Levenshtein similarity is 0…1 with a
/// completely different distribution. So the fusion uses **ranks**, not scores
/// — each branch contributes `weight / (60 + rank)` for everything it returned,
/// and the sums decide the order. No hand-tuned normalisers to drift apart.
///
/// An actor because a fast typist would otherwise fan out one embedding and one
/// index scan per keystroke; serialized, a superseded search is cancelled
/// rather than raced.
///
/// See docs/features/SEARCH.md#hybridsearch-merge.
public actor HybridSearch {
    // MARK: Lifecycle

    public init(
        archive: Archive,
        semantic: SemanticIndex? = nil,
        fuzzy: FuzzyMatcher = FuzzyMatcher(),
        triage: any TriageEvaluating = NoTriage()
    ) {
        self.archive = archive
        self.semantic = semantic
        self.fuzzy = fuzzy
        self.triage = triage
        fts = FTSIndex(archive: archive)
        apps = AppResolver(archive: archive)
    }

    // MARK: Public

    /// The constants the merge is made of, in one place so a change to any of
    /// them is a change to a documented number rather than to a literal buried
    /// in a loop.
    public enum Limits {
        /// Rows scanned for a fuzzy match. Bounded because Levenshtein against
        /// 100k titles is ~90 M cell updates — the one thing here that would
        /// blow the latency budget on its own.
        public static let fuzzyCandidates = 5_000

        /// Fuzzy only runs when full text came back this thin. If FTS found
        /// plenty, the user spelled it right and guesses would only add noise.
        public static let fuzzyTriggerBelow = 5

        /// Under three words, cosine similarity between sentence vectors is not
        /// informative, so the semantic branch is skipped rather than allowed
        /// to be confidently wrong.
        public static let semanticMinWords = 3

        /// The usual reciprocal-rank-fusion constant: big enough that the gap
        /// between rank 1 and rank 2 does not dwarf everything below it.
        public static let rrfK = 60.0

        /// Ported weights. Semantic outranks full text when it fires at all,
        /// because it only fires on a sentence-shaped query — where the user
        /// has described rather than quoted.
        public static let weightFTS = 0.4
        public static let weightSemantic = 0.5
        public static let weightFuzzy = 0.3
    }

    /// Runs a query and returns the merged, ranked hits.
    ///
    /// - Parameters:
    ///   - query: the raw text and its limit.
    ///   - semanticEnabled: the user's Settings toggle. `false` skips the
    ///     semantic branch entirely — no embedding, no scan, no cost.
    /// - Throws: ``SearchError/invalidQuery(_:)`` for an unreadable date, and
    ///   ``SearchError/cancelled`` when a later keystroke superseded this
    ///   search. A failing *semantic* branch is never thrown: the hit simply
    ///   loses its semantic source.
    public func search(_ query: SearchQuery, semanticEnabled: Bool = false) async throws -> [SearchHit] {
        let parsed = try QueryParser.parse(query.text)
        guard !parsed.isEmpty else {
            return []
        }

        let appIDs = try apps.resolve(parsed)
        if parsed.namesAnApp, appIDs.isEmpty {
            // `from:xyz` matched no app. Zero results is the honest answer;
            // dropping the filter and showing everything is the failure that
            // makes people stop trusting a search box.
            return []
        }
        try checkCancellation()

        let ftsHits = try ftsCandidates(parsed, appIDs: appIDs, limit: query.limit)
        try checkCancellation()

        let fuzzyHits = try fuzzyMatches(parsed, appIDs: appIDs, ftsCount: ftsHits.count)
        let semanticHits = query.mode == .hybrid && semanticEnabled
            ? await semanticMatches(parsed, appIDs: appIDs)
            : []
        try checkCancellation()

        var merged = Self.fuse(fts: ftsHits, fuzzy: fuzzyHits, semantic: semanticHits)
        if parsed.flags.contains(.vip) {
            merged = try vipOnly(merged)
        }
        return Array(merged.prefix(query.limit))
    }

    /// Full text only, synchronously — the branch that has to answer inside a
    /// keystroke, and the one the timeline's search field calls while the user
    /// is still typing.
    nonisolated public func ftsOnly(_ query: SearchQuery, limit: Int = 200) throws -> [SearchHit] {
        let parsed = try QueryParser.parse(query.text)
        guard !parsed.isEmpty else {
            return []
        }
        let appIDs = try apps.resolve(parsed)
        if parsed.namesAnApp, appIDs.isEmpty {
            return []
        }
        let hits = try ftsCandidates(parsed, appIDs: appIDs, limit: limit)
        return Self.fuse(fts: hits, fuzzy: [], semantic: [])
    }

    // MARK: Internal

    /// Merges the branches by rank rather than by score.
    ///
    /// Static and pure: the whole point of rank fusion is that it can be
    /// checked on paper, so it is testable without an archive, an index or an
    /// embedding model.
    static func fuse(fts: [FTSHit], fuzzy: [FuzzyMatcher.Match], semantic: [SemanticHit]) -> [SearchHit] {
        struct Accumulator {
            var score = 0.0
            var sources: Set<SearchHit.Source> = []
            var snippet: String?
        }
        var accumulated: [Int64: Accumulator] = [:]

        func add(_ id: Int64, rank: Int, weight: Double, source: SearchHit.Source, snippet: String? = nil) {
            var entry = accumulated[id] ?? Accumulator()
            entry.score += weight * (1.0 / (Limits.rrfK + Double(rank)))
            entry.sources.insert(source)
            if entry.snippet == nil, let snippet, !snippet.isEmpty {
                entry.snippet = snippet
            }
            accumulated[id] = entry
        }

        for (index, hit) in fts.enumerated() {
            add(hit.notificationID, rank: index + 1, weight: Limits.weightFTS, source: .fts, snippet: hit.snippet)
        }
        for (index, hit) in semantic.enumerated() {
            add(hit.notificationID, rank: index + 1, weight: Limits.weightSemantic, source: .semantic)
        }
        for (index, match) in fuzzy.enumerated() {
            add(match.id, rank: index + 1, weight: Limits.weightFuzzy, source: .fuzzy)
        }

        let hits = accumulated.map { id, entry in
            SearchHit(notificationID: id, score: entry.score, snippet: entry.snippet, sources: entry.sources)
        }
        // Newest id breaks a tie, so an identical pair of scores still has a
        // stable order rather than a dictionary's.
        return hits.sorted { $0.score == $1.score ? $0.notificationID > $1.notificationID : $0.score > $1.score }
    }

    // MARK: Private

    private let archive: Archive
    private let fts: FTSIndex
    private let fuzzy: FuzzyMatcher
    private let semantic: SemanticIndex?
    private let triage: any TriageEvaluating
    private let apps: AppResolver

    nonisolated private func checkCancellation() throws {
        guard !Task.isCancelled else {
            throw SearchError.cancelled
        }
    }

    /// The full-text branch, or — for a query with no positive terms — the
    /// filters-only walk that stands in for it.
    nonisolated private func ftsCandidates(_ parsed: ParsedQuery, appIDs: [Int64], limit: Int) throws -> [FTSHit] {
        if let match = parsed.ftsMatch, !parsed.isNegationOnly {
            // The structured filters ride along inside the same statement. A
            // second pass over the candidate ids cost ~60 ms at a hundred
            // thousand notifications — enough on its own to miss the budget.
            let filter = parsed.hasStructuredFilters ? Self.filterFragment(parsed) : nil
            return try fts.search(match: match, appIDs: appIDs, filter: filter, limit: limit)
        }
        return try filterOnly(parsed, appIDs: appIDs, limit: limit)
    }

    /// A query with filters but no searchable text: `from:slack is:missed`,
    /// or a pure exclusion like `-draft`. Newest first, since there is no
    /// relevance to rank by.
    nonisolated private func filterOnly(_ parsed: ParsedQuery, appIDs: [Int64], limit: Int) throws -> [FTSHit] {
        let (sql, arguments) = Self.filterSQL(parsed, appIDs: appIDs, restrictedTo: nil, limit: limit)
        do {
            return try archive.pool.read { db in
                try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                    FTSHit(notificationID: row["id"], score: 0, snippet: "")
                }
            }
        } catch let error as SearchError {
            throw error
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// The fuzzy branch: only when full text came back thin, and only over
    /// candidates already narrowed by the same filters.
    private func fuzzyMatches(_ parsed: ParsedQuery, appIDs: [Int64], ftsCount: Int) throws -> [FuzzyMatcher.Match] {
        guard ftsCount < Limits.fuzzyTriggerBelow,
              let term = parsed.terms.last,
              term.count >= 3
        else {
            return []
        }
        let candidates = try fuzzyCandidates(parsed, appIDs: appIDs)
        return fuzzy.matches(query: term, in: candidates)
    }

    private func fuzzyCandidates(_ parsed: ParsedQuery, appIDs: [Int64]) throws -> [FuzzyMatcher.Candidate] {
        let (sql, arguments) = Self.fuzzyCandidateSQL(parsed, appIDs: appIDs)
        do {
            return try archive.pool.read { db in
                var candidates: [FuzzyMatcher.Candidate] = []
                for row in try Row.fetchAll(db, sql: sql, arguments: arguments) {
                    let id: Int64 = row["id"]
                    if let title: String = row["title"] {
                        candidates.append(.init(id: id, text: title))
                    }
                    if let sender: String = row["sender"] {
                        candidates.append(.init(id: id, text: sender))
                    }
                }
                return candidates
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// The semantic branch. Every failure here is swallowed on purpose: a Mac
    /// without the model, or a model that returns a surprise, costs the user
    /// one kind of hit — not their search.
    private func semanticMatches(_ parsed: ParsedQuery, appIDs: [Int64]) async -> [SemanticHit] {
        guard let semantic, parsed.terms.count >= Limits.semanticMinWords else {
            return []
        }
        guard await semantic.isAvailable else {
            return []
        }
        do {
            let vector = try await semantic.embed(parsed.terms.joined(separator: " "))
            guard !vector.isEmpty else {
                return []
            }
            return try await semantic.search(
                queryVector: vector,
                appIDs: appIDs,
                after: parsed.after,
                before: parsed.before
            )
        } catch {
            Log.search.notice("semantic branch skipped: \(String(describing: type(of: error)))")
            return []
        }
    }

    /// `is:vip` — pinned by a rule, or pinned by hand.
    ///
    /// Until `RulesEngine` ships, the injected evaluator is ``NoTriage`` and
    /// this reduces to the user's own pins. That is a smaller answer than the
    /// grammar promises, but a true one; a rule-less archive has no VIPs.
    private func vipOnly(_ hits: [SearchHit]) throws -> [SearchHit] {
        let ids = hits.map(\.notificationID)
        guard !ids.isEmpty else {
            return hits
        }
        let rows: [ArchivedNotification]
        do {
            rows = try archive.pool.read { db in
                try ArchivedNotification.filter(ids.contains(Column("id"))).fetchAll(db)
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
        var vip = Set<Int64>()
        for row in rows {
            guard let id = row.id else {
                continue
            }
            if row.isPinned || triage.evaluate(row).pinned {
                vip.insert(id)
            }
        }
        return hits.filter { vip.contains($0.notificationID) }
    }
}
