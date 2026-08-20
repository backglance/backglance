import BackglanceCore
import Foundation
import GRDB

// MARK: - The structured half of a query

/// Everything `WHERE`-shaped: the filters that cannot live inside an FTS5
/// `MATCH` expression and have to be applied as ordinary SQL.
///
/// Built as `(sql, arguments)` pairs by pure static functions so the predicates
/// can be read — and tested — without a database, and so that every value the
/// user typed arrives as a bound argument rather than as text spliced into a
/// statement.
extension HybridSearch {
    /// Selects notification ids matching a query's structured filters.
    ///
    /// - Parameters:
    ///   - restrictedTo: when non-nil, narrows to these ids — used to filter an
    ///     FTS candidate set rather than re-scanning the table.
    ///   - limit: `nil` leaves the result unbounded, which is only safe with
    ///     `restrictedTo` set.
    static func filterSQL(
        _ parsed: ParsedQuery,
        appIDs: [Int64],
        restrictedTo ids: [Int64]?,
        limit: Int?
    ) -> (sql: String, arguments: StatementArguments) {
        var sql = "SELECT n.id AS id FROM notifications n WHERE n.is_deleted = 0"
        var arguments = StatementArguments()

        if let ids, !ids.isEmpty {
            sql += " AND n.id IN (" + placeholders(ids.count) + ")"
            arguments += StatementArguments(ids)
        }
        appendCommonFilters(to: &sql, arguments: &arguments, parsed: parsed, appIDs: appIDs, prefix: "n.")

        if parsed.isNegationOnly, let match = parsed.ftsMatch {
            // FTS5 has no unary NOT, so an exclusion-only query is expressed as
            // "everything except what this match finds" instead.
            sql += " AND n.id NOT IN (SELECT rowid FROM notifications_fts WHERE notifications_fts MATCH ?)"
            arguments += [match]
        }

        sql += " ORDER BY n.delivered_at DESC"
        if let limit {
            sql += " LIMIT ?"
            arguments += [limit]
        }
        return (sql, arguments)
    }

    /// The structured predicates alone, as a fragment to graft onto another
    /// statement's `WHERE`.
    ///
    /// Used by the full-text path so a filtered search stays one query. The
    /// fragment assumes the notifications table is aliased `n`.
    static func filterFragment(_ parsed: ParsedQuery) -> (sql: String, arguments: StatementArguments) {
        var sql = ""
        var arguments = StatementArguments()
        appendCommonFilters(to: &sql, arguments: &arguments, parsed: parsed, appIDs: [], prefix: "n.")
        return (sql, arguments)
    }

    /// Titles and senders to fuzz against: recent, filtered, and bounded.
    ///
    /// Bounded at ``Limits/fuzzyCandidates`` because edit distance over the
    /// whole archive is the one operation here that cannot fit the budget —
    /// against five thousand rows it is a few milliseconds, against a hundred
    /// thousand it is a stall.
    static func fuzzyCandidateSQL(_ parsed: ParsedQuery,
                                  appIDs: [Int64]) -> (sql: String, arguments: StatementArguments)
    {
        var sql = "SELECT id, title, sender FROM notifications WHERE is_deleted = 0"
        var arguments = StatementArguments()
        appendCommonFilters(to: &sql, arguments: &arguments, parsed: parsed, appIDs: appIDs, prefix: "")
        sql += " ORDER BY delivered_at DESC LIMIT ?"
        arguments += [HybridSearch.Limits.fuzzyCandidates]
        return (sql, arguments)
    }

    // MARK: Private

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    /// The predicates every path shares. `prefix` is `"n."` where the statement
    /// aliases the table and empty where it does not.
    private static func appendCommonFilters(
        to sql: inout String,
        arguments: inout StatementArguments,
        parsed: ParsedQuery,
        appIDs: [Int64],
        prefix: String
    ) {
        if !appIDs.isEmpty {
            sql += " AND \(prefix)app_id IN (" + placeholders(appIDs.count) + ")"
            arguments += StatementArguments(appIDs)
        }
        if let after = parsed.after {
            sql += " AND \(prefix)delivered_at >= ?"
            arguments += [after.timeIntervalSince1970]
        }
        if let before = parsed.before {
            sql += " AND \(prefix)delivered_at < ?"
            arguments += [before.timeIntervalSince1970]
        }
        if let sender = parsed.sender, !sender.isEmpty {
            sql += " AND lower(\(prefix)sender) LIKE ? ESCAPE '\\'"
            arguments += ["%\(AppResolver.escapingWildcards(sender.lowercased()))%"]
        }
        if let thread = parsed.threadID, !thread.isEmpty {
            sql += " AND \(prefix)thread_id = ?"
            arguments += [thread]
        }
        appendFlags(to: &sql, parsed: parsed, prefix: prefix)
    }

    /// `is:` and `has:`, each one predicate. `is:vip` is deliberately absent:
    /// it is decided by the rules engine after the fact, not by a column.
    private static func appendFlags(to sql: inout String, parsed: ParsedQuery, prefix: String) {
        for flag in parsed.flags {
            switch flag {
            case .unread:
                sql += " AND \(prefix)is_read = 0"

            case .read:
                sql += " AND \(prefix)is_read = 1"

            case .pinned:
                sql += " AND \(prefix)is_pinned = 1"

            case .missed:
                // Either it arrived while the user was away, or the system
                // never put it on screen at all.
                sql += " AND (\(prefix)away_session_id IS NOT NULL OR \(prefix)presented = 0)"

            case .hasLink:
                sql += " AND \(prefix)deep_link IS NOT NULL"

            case .hasAttachment:
                sql += " AND \(prefix)attachments_json IS NOT NULL"

            case .redacted:
                sql += " AND \(prefix)redaction = 'otp'"

            case .vip:
                continue
            }
        }
    }
}

// MARK: - ParsedQuery + filters

public extension ParsedQuery {
    /// Whether anything here needs a `WHERE` clause of its own.
    ///
    /// `is:vip` does not count: it is settled against the rules engine after
    /// the candidates are in hand, not by a predicate.
    var hasStructuredFilters: Bool {
        after != nil
            || before != nil
            || !(sender ?? "").isEmpty
            || !(threadID ?? "").isEmpty
            || !flags.subtracting([.vip]).isEmpty
    }
}
