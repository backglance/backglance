import BackglanceCore
import Foundation
import GRDB

// MARK: - AppResolver

/// Turns what the user typed after `from:` into the app rows it means.
///
/// Three passes, narrowest first: an exact bundle id, then a display name, then
/// a substring of either. `from:mail` matching both Mail and Airmail is the
/// correct answer, not an ambiguity to resolve — the user narrows it with the
/// bundle id if they meant one of them.
///
/// A term that matches nothing is a real answer too: the search returns no
/// results rather than quietly dropping the filter and showing everything,
/// which is the failure mode that makes people distrust a search box.
///
/// See docs/features/SEARCH.md#hybridsearch-merge.
public struct AppResolver: Sendable {
    // MARK: Lifecycle

    public init(archive: Archive) {
        self.archive = archive
    }

    // MARK: Public

    /// The `apps.id` values a parsed query's app filters name.
    ///
    /// Returns an empty array when the query names no app at all *and* when it
    /// names one that does not exist; ``ParsedQuery/namesAnApp`` is what
    /// distinguishes the two for the caller.
    public func resolve(_ query: ParsedQuery) throws -> [Int64] {
        guard query.namesAnApp else {
            return []
        }
        do {
            return try archive.pool.read { db in
                var ids = Set<Int64>()

                if !query.bundleIDs.isEmpty {
                    let apps = try AppRecord.filter(query.bundleIDs.contains(Column("bundle_id"))).fetchAll(db)
                    ids.formUnion(apps.compactMap(\.id))
                }

                // 🔒 Both sides fold the same way. `display_name_key` is
                // `String.matchKey` written at insert time, and the needle is folded
                // here — SQLite's `lower()` folds A–Z only, so comparing against
                // `lower(display_name)` used to miss every non-ASCII name
                // (`from:isbank` did not find "İŞBANK"). Bundle identifiers are ASCII
                // by Apple's own rules, so `lower()` is still right for that half.
                if let needle = query.appNameContains?.matchKey, !needle.isEmpty {
                    let sql = """
                    SELECT id FROM apps
                    WHERE display_name_key LIKE ? ESCAPE '\\'
                       OR lower(bundle_id) LIKE ? ESCAPE '\\'
                    """
                    let pattern = "%\(Self.escapingWildcards(needle))%"
                    let matched = try Int64.fetchAll(db, sql: sql, arguments: [pattern, pattern])
                    ids.formUnion(matched)
                }

                return ids.sorted()
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    // MARK: Internal

    /// `%` and `_` are wildcards in `LIKE`, and the term comes from a text
    /// field the user typed — `from:100_000` should look for that string, not
    /// for "100" followed by any character.
    static func escapingWildcards(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: Private

    private let archive: Archive
}

// MARK: - ParsedQuery + apps

public extension ParsedQuery {
    /// Whether the query names an app at all, by bundle id or by name.
    ///
    /// The difference between "no app filter" and "an app filter that matched
    /// nothing" is the difference between showing everything and showing
    /// nothing, so it gets a name rather than being re-derived at each call.
    var namesAnApp: Bool {
        !bundleIDs.isEmpty || !(appNameContains ?? "").isEmpty
    }
}
