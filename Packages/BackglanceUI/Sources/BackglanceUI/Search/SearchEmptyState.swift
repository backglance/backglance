import SwiftUI

// MARK: - SearchEmptyState

/// The three reasons the results list has nothing to draw
/// (docs/features/SEARCH.md#ui-components: "`SearchEmptyState` — three
/// variants: no query yet …, no results …, semantic-off hint …").
///
/// As with `EmptyStateView` on the timeline, a button only appears when the
/// matching closure is supplied, so a read-only host (a preview, an
/// embedded results strip with nowhere to send the action) simply omits it.
public struct SearchEmptyState: View {
    // MARK: Lifecycle

    public init(
        kind: Kind,
        onClearFilters: (() -> Void)? = nil,
        onEnableSemantic: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.onClearFilters = onClearFilters
        self.onEnableSemantic = onEnableSemantic
    }

    // MARK: Public

    /// Which of the three empty reasons applies. Decided by the search view
    /// model, not by this view — `SearchEmptyState` only renders it.
    public enum Kind: Equatable, Sendable {
        /// The search field is empty; show the grammar hint.
        case noQuery
        /// The query ran and matched nothing.
        case noResults
        /// The query reads as a natural-language sentence but Semantic
        /// search is off (Settings ▸ Search), so it was never tried.
        case semanticOff
    }

    public let kind: Kind
    public var onClearFilters: (() -> Void)?
    public var onEnableSemantic: (() -> Void)?

    public var body: some View {
        VStack(spacing: 8) {
            // `.largeTitle`, not a fixed point size, so the system text-size
            // preference scales the symbol along with everything else on the
            // screen (docs/reference/ACCESSIBILITY.md#text-size).
            Image(systemName: symbolName)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            content
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Private

    private var symbolName: String {
        switch kind {
        case .noQuery: "magnifyingglass"
        case .noResults: "magnifyingglass"
        case .semanticOff: "sparkles"
        }
    }

    /// One string, not nine.
    ///
    /// The examples are interpolated as styled `Text` runs, so the sentence
    /// stays a single localizable key with four placeholders — a translator
    /// gets a sentence to translate rather than nine fragments to reassemble —
    /// and no `Text + Text` concatenation, which is deprecated.
    private var hintText: Text {
        Text("""
        Try \(Self.code("from:slack invoice")), \(Self.code("sender:\"Ayşe\" after:-7d")), \
        \(Self.code("is:missed has:link")), or a sentence like \
        \(Self.code("the message about the invoice")) with Semantic search on.
        """)
    }

    private var buttonTitle: String? {
        switch kind {
        case .noResults: String(localized: "Clear filters")
        case .semanticOff: String(localized: "Turn on Semantic Search")
        case .noQuery: nil
        }
    }

    private var action: (() -> Void)? {
        switch kind {
        case .noResults: onClearFilters
        case .semanticOff: onEnableSemantic
        case .noQuery: nil
        }
    }

    /// The `.noQuery` sentence is reproduced verbatim from the `search.hint`
    /// string in docs/features/SEARCH.md#ui-components; do not paraphrase it
    /// here without updating that table too. The grammar examples render as
    /// monospaced runs inside the sentence rather than as one flat string.
    @ViewBuilder private var content: some View {
        switch kind {
        case .noQuery:
            hintText

        case .noResults:
            Text(String(localized: "Nothing matched."))

        case .semanticOff:
            Text(String(
                localized: "This looks like a sentence. Semantic search is off, so only exact words were tried."
            ))
        }
    }

    /// One grammar example, rendered the way the docs write it.
    private static func code(_ example: String) -> Text {
        Text(verbatim: example).fontDesign(.monospaced)
    }
}

// MARK: - Previews

#Preview("No Query") {
    SearchEmptyState(kind: .noQuery)
}

#Preview("No Results") {
    SearchEmptyState(kind: .noResults, onClearFilters: PreviewEmptyStateAction.none)
}

#Preview("Semantic Off") {
    SearchEmptyState(kind: .semanticOff, onEnableSemantic: PreviewEmptyStateAction.none)
}

// MARK: - PreviewEmptyStateAction

/// A no-op the previews pass by name; a closure literal at the call site
/// would trip SwiftLint's trailing-closure rule.
private enum PreviewEmptyStateAction {
    static let none: @Sendable () -> Void = {}
}
