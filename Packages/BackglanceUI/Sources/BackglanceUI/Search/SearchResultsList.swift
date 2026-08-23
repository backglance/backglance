import BackglanceCore
import SwiftUI

// MARK: - SearchResultsList

/// The results area under the search bar, grouped into "Best matches" and
/// "Similar" (docs/features/SEARCH.md#ui-components: "`SearchResultsList` …
/// `LazyVStack` of `NotificationRow` … sections `Best matches` / `Similar`
/// (semantic-only hits)").
///
/// `SearchHit` carries an id and a score, not a row — search returns
/// identifiers so a hundred-hit query never decodes a hundred notifications
/// nobody scrolls to (`SearchHit`'s own doc comment in
/// `BackglanceCore/Search/SearchQuery.swift`). So this view is handed the
/// hits alongside a `[Int64: TimelineItem]` the caller already fetched in
/// one batched query. A hit whose id is missing from `rows` — a race with a
/// delete between the search and the fetch, or a row that failed to decode —
/// is skipped rather than faked; there is nothing honest to draw for it.
public struct SearchResultsList: View {
    // MARK: Lifecycle

    public init(
        hits: [SearchHit],
        rows: [Int64: TimelineItem],
        mode: TimelineViewMode = .compact,
        selectedID: Int64? = nil,
        onOpen: ((Int64) -> Void)? = nil
    ) {
        self.hits = hits
        self.rows = rows
        self.mode = mode
        self.selectedID = selectedID
        self.onOpen = onOpen
    }

    // MARK: Public

    public let hits: [SearchHit]
    public let rows: [Int64: TimelineItem]
    public let mode: TimelineViewMode
    public let selectedID: Int64?
    public let onOpen: ((Int64) -> Void)?

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    section(title: bestMatchesTitle, hits: bestMatches)
                    section(title: similarTitle, hits: similar)
                }
            }
            // The same pattern TimelineView uses to keep a keyboard
            // selection on screen (docs/features/TIMELINE.md
            // #timelineview-and-timelinesection): ↑/↓ live upstream in the
            // view model that owns `selectedID`, this view only has to
            // follow it, including across the "Best matches" → "Similar"
            // boundary.
            .onChange(of: selectedID) { _, id in
                if let id {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    // MARK: Private

    /// Horizontal inset that lines the snippet up under a row's title
    /// rather than under its icon: `NotificationRow`'s own outer padding
    /// (10) plus its icon column (20 wide, 8 spacing before the text).
    private static let snippetLeadingInset: CGFloat = 38

    private var bestMatchesTitle: String {
        String(localized: "Best matches", comment: "Section header over search results that matched the words typed")
    }

    private var similarTitle: String {
        String(localized: "Similar", comment: "Section header over search results that matched by meaning only")
    }

    /// FTS or fuzzy hits — a literal or typo-tolerant match on the words
    /// themselves, which earns more confidence than meaning alone.
    private var bestMatches: [SearchHit] {
        hits.filter { $0.sources.contains(.fts) || $0.sources.contains(.fuzzy) }
    }

    /// Semantic-only hits: nothing matched the words, only the meaning — a
    /// weaker signal that gets its own, clearly-labelled section rather than
    /// blending into the results above it.
    private var similar: [SearchHit] {
        hits.filter { $0.sources.contains(.semantic) && !$0.sources.contains(.fts) && !$0.sources.contains(.fuzzy) }
    }

    /// A section with nothing to draw — every hit's row missing from
    /// `rows`, or the source split above simply had nothing for it — renders
    /// nothing at all, not an empty header.
    @ViewBuilder
    private func section(title: String, hits: [SearchHit]) -> some View {
        let present = hits.filter { rows[$0.notificationID] != nil }
        if !present.isEmpty {
            Section {
                ForEach(present) { hit in
                    row(for: hit)
                }
            } header: {
                SearchSectionHeader(title: title)
            }
        }
    }

    @ViewBuilder
    private func row(for hit: SearchHit) -> some View {
        if let item = rows[hit.notificationID] {
            VStack(alignment: .leading, spacing: 2) {
                NotificationRow(item: displayItem(item), mode: mode, onOpen: onOpen)
                if let snippet = hit.snippet {
                    Text(MatchHighlighter.attributed(snippet))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.leading, Self.snippetLeadingInset)
                        .padding(.trailing, 10)
                }
            }
            .id(hit.notificationID)
        }
    }

    /// `TimelineItem.isSelected` is part of the value, not derived (see the
    /// type's own doc comment: "a selection change redraws exactly two
    /// rows"). This view is handed `selectedID` instead, so it stamps that
    /// onto the item it is about to draw rather than trusting whatever
    /// `isSelected` the caller's `rows` lookup happened to carry.
    private func displayItem(_ item: TimelineItem) -> TimelineItem {
        var item = item
        item.isSelected = item.id == selectedID
        return item
    }
}

// MARK: - SearchSectionHeader

/// The pinned "Best matches" / "Similar" label, styled to match
/// `DayHeader` — the same thin-material strip the timeline uses for its own
/// pinned day headers, so a results list dropped into either host reads as
/// the same app (docs/features/SEARCH.md#ui-components).
private struct SearchSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.smallCaps())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Previews

#Preview("Mixed Sources") {
    let items = PreviewData.items
    let rows = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
    let hits = [
        SearchHit(notificationID: items[0].id, score: 0.9, snippet: "\u{E000}Deploy\u{E001} finished", sources: [.fts]),
        SearchHit(notificationID: items[1].id, score: 0.7, snippet: nil, sources: [.fuzzy]),
        SearchHit(notificationID: items[2].id, score: 0.4, snippet: nil, sources: [.semantic]),
    ]

    SearchResultsList(hits: hits, rows: rows, selectedID: items[0].id)
        .frame(width: 380, height: 420)
}

#Preview("No Rows Present") {
    SearchResultsList(hits: [], rows: [:])
        .frame(width: 380, height: 200)
}
