import BackglanceCore
import Observation
import SwiftUI

// MARK: - SearchBar

/// The search field: magnifier, text field, clear button, a delayed
/// spinner, the chip strip, the semantic-index progress bar and the inline
/// error (docs/features/SEARCH.md#ui-components: "`SearchBar` — `TextField`
/// with magnifier, clear button, filter-chip strip; `⌘F` focuses it in
/// popover and window; `Esc` clears then closes").
///
/// `model` is `@Bindable`: the field's own state — `text`, and everything
/// downstream of it — lives on `SearchViewModel`, not on this view. That
/// view model owns the debounce and cancellation documented in
/// docs/features/SEARCH.md#debounce-and-cancellation; this view only reads
/// and writes through the binding and never schedules a search itself,
/// except for the two keys that bypass the debounce on purpose (↩ and the
/// clear half of Esc).
public struct SearchBar: View {
    // MARK: Lifecycle

    public init(
        model: SearchViewModel,
        filters: [SearchFilter] = [],
        indexProgress: (done: Int, total: Int)? = nil,
        onRemoveFilter: ((SearchFilter) -> Void)? = nil,
        onEscape: (() -> Void)? = nil
    ) {
        self.model = model
        self.filters = filters
        self.indexProgress = indexProgress
        self.onRemoveFilter = onRemoveFilter
        self.onEscape = onEscape
    }

    // MARK: Public

    public let filters: [SearchFilter]
    public let indexProgress: (done: Int, total: Int)?
    public var onRemoveFilter: ((SearchFilter) -> Void)?
    public var onEscape: (() -> Void)?

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            field

            if !filters.isEmpty {
                chipStrip
            }

            if let indexProgress {
                SemanticIndexProgress(done: indexProgress.done, total: indexProgress.total)
            }

            if let inlineError = model.inlineError {
                Text(inlineError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        // Esc is handled here, one level up from the field, so it still
        // fires with focus resting on a filter chip's remove button and not
        // only while the text field itself is first responder.
        .onKeyPress(.escape) {
            handleEscape()
            return .handled
        }
        // A hidden button carries the ⌘F shortcut rather than an
        // `.onKeyPress("f", modifiers: .command)` on the field: a key-press
        // handler would have to recognize and swallow exactly one chord
        // while leaving every ordinary keystroke (including a literal "f"
        // someone is typing) alone. A `keyboardShortcut` on a button that
        // never renders does the same job through the menu-key system,
        // which already knows the difference.
        .background {
            Button(String(localized: "Focus search")) {
                isFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
            .accessibilityHidden(true)
        }
    }

    // MARK: Private

    @Bindable private var model: SearchViewModel

    @FocusState private var isFocused: Bool

    /// Flips true only after `model.isSearching` has held for the delay
    /// below — the mechanism behind "a fast search never flickers a
    /// spinner."
    @State private var showsSpinner = false

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(String(localized: "Search"), text: $model.text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit {
                    Task { await model.searchNow() }
                }
                // docs/reference/ACCESSIBILITY.md#identifiers-for-ui-tests.
                .accessibilityIdentifier("timeline.searchField")

            if showsSpinner {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }

            if model.hasQuery {
                Button(action: model.clear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear search"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        // A sleep that outlives its own search is exactly the debounce
        // pattern `SearchViewModel.schedule()` uses for the same reason
        // (docs/features/SEARCH.md#debounce-and-cancellation): keying the
        // task on `isSearching` means a search that finishes inside 200 ms
        // cancels this sleep before it ever sets the flag, so the spinner
        // never appears at all rather than appearing and instantly vanishing.
        .task(id: model.isSearching) {
            guard model.isSearching else {
                showsSpinner = false
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else {
                return
            }
            showsSpinner = model.isSearching
        }
    }

    private var chipStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(filters) { filter in
                    SearchFilterChip(filter: filter, onRemove: onRemoveFilter)
                }
            }
        }
    }

    /// Clear then close, never both: text still in the field means Esc's
    /// job is done once it is gone, so `onEscape` (closing the popover, say)
    /// only fires on the second, empty-field press.
    private func handleEscape() {
        if model.hasQuery {
            model.clear()
        } else {
            onEscape?()
        }
    }
}

// MARK: - Previews

#Preview("Empty") {
    SearchBar(model: SearchViewModel(search: PreviewSearchEngine()))
        .frame(width: 380)
}

#Preview("With Filters and Progress") {
    let model = SearchViewModel(search: PreviewSearchEngine())
    model.text = "from:slack invoice"
    return SearchBar(
        model: model,
        filters: [
            SearchFilter(id: "from", label: "from: Slack", token: "from:slack"),
            SearchFilter(id: "missed", label: "is: missed", token: "is:missed"),
        ],
        indexProgress: (done: 3_120, total: 41_000),
        onRemoveFilter: PreviewBarAction.removeFilter,
        onEscape: PreviewBarAction.escape
    )
    .frame(width: 380)
}

// MARK: - PreviewSearchEngine

/// Answers every query with no hits — the previews above only need
/// `SearchViewModel` to construct, never to actually search.
private struct PreviewSearchEngine: SearchRunning {
    func search(_ query: SearchQuery, semanticEnabled: Bool) async throws -> [SearchHit] {
        []
    }
}

// MARK: - PreviewBarAction

/// No-ops the previews pass by name; a closure literal at the call site
/// would trip SwiftLint's trailing-closure rule.
private enum PreviewBarAction {
    static let removeFilter: @Sendable (SearchFilter) -> Void = { _ in }
    static let escape: @Sendable () -> Void = {}
}
