import BackglanceCore
import Foundation

// MARK: - Pagination

/// Paging older rows in, one keyset page at a time.
/// See docs/features/TIMELINE.md#keyset-pagination.
public extension TimelineStore {
    /// Appends the next page. Called by the scroll sentinel, and safe to call
    /// again while one is in flight — the second call returns immediately rather
    /// than fetching the same page twice.
    func loadNextPage() async {
        guard hasMorePages, !isLoadingPage else {
            return
        }
        isLoadingPage = true
        defer { isLoadingPage = false }

        guard let after = cursor ?? rows.last.flatMap(TimelineCursor.init(row:)) else {
            hasMorePages = false
            return
        }

        do {
            // Bound outside the detached task: reading them inside would be a
            // hop back to the main actor for every page.
            let archive = archive
            let limit = Self.pageSize
            let page = try await Task.detached {
                try archive.timelinePage(after: after, limit: limit)
            }.value

            guard !page.isEmpty else {
                hasMorePages = false
                return
            }
            let known = Set(rows.compactMap(\.id))
            rows.append(contentsOf: page.filter { row in row.id.map { !known.contains($0) } ?? false })
            cursor = page.last.flatMap(TimelineCursor.init(row:))
            hasMorePages = page.count == Self.pageSize
            if rows.count > Self.maxRows {
                // Drop from the head, not the tail: the user is reading the
                // bottom of the list, and the subscription can refetch the top.
                rows.removeFirst(rows.count - Self.maxRows)
            }
            regroup()
        } catch {
            loadError = Self.message(for: error)
        }
    }
}
