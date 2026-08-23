import SwiftUI

// MARK: - SearchFilter

/// One active filter, as the search bar's chip strip sees it
/// (docs/features/SEARCH.md#ui-components: "`FilterChip` — one per active
/// filter … tapping removes it and rewrites the query text").
///
/// `BackglanceUI` never imports `BackglanceSearch` — the chip strip renders
/// off a plain string, not a parsed `SearchQuery`. So a filter here is just
/// the label the user reads (`"from: Slack"`) paired with the exact
/// substring of the query text that produced it (`"from:slack"`). Removing a
/// chip is then nothing more than deleting that substring from the text and
/// letting the query re-parse — no knowledge of `QueryParser`'s grammar
/// required on this side of the module boundary.
public struct SearchFilter: Identifiable, Equatable, Sendable {
    // MARK: Lifecycle

    public init(id: String, label: String, token: String) {
        self.id = id
        self.label = label
        self.token = token
    }

    // MARK: Public

    public let id: String

    /// What the user reads on the chip, e.g. `"from: Slack"`.
    public let label: String

    /// The exact substring of the query text this filter came from, e.g.
    /// `"from:slack"`. Carried verbatim so removal is a text edit, not a
    /// re-serialization of a parsed token.
    public let token: String

    /// Deletes `filter.token` from `text` and tidies the whitespace left
    /// behind, so removing a chip never leaves a double space where the
    /// token used to sit (docs/features/SEARCH.md#ui-components).
    public static func removing(_ filter: SearchFilter, from text: String) -> String {
        guard let range = text.range(of: filter.token) else {
            return text
        }
        var result = text
        result.removeSubrange(range)
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - SearchFilterChip

/// A small capsule for one active filter. Removable chips show an `xmark`
/// button; a chip with no `onRemove` renders as a plain, non-interactive
/// label (docs/features/SEARCH.md#ui-components).
public struct SearchFilterChip: View {
    // MARK: Lifecycle

    public init(filter: SearchFilter, onRemove: ((SearchFilter) -> Void)? = nil) {
        self.filter = filter
        self.onRemove = onRemove
    }

    // MARK: Public

    public let filter: SearchFilter
    public var onRemove: ((SearchFilter) -> Void)?

    public var body: some View {
        HStack(spacing: 4) {
            Text(filter.label)
                .font(.caption)

            if onRemove != nil {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .accessibilityLabel(removeLabel)
                    .accessibilityAddTraits(.isButton)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture {
            onRemove?(filter)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(filter.label)
        .accessibilityAddTraits(onRemove != nil ? .isButton : [])
    }

    // MARK: Private

    private var removeLabel: String {
        String(
            localized: "Remove filter, \(filter.label)",
            comment: "Spoken by VoiceOver for a filter chip's close button; placeholder is the filter's own label"
        )
    }
}

// MARK: - Previews

#Preview {
    HStack {
        SearchFilterChip(
            filter: SearchFilter(id: "from", label: "from: Slack", token: "from:slack"),
            onRemove: PreviewChipAction.none
        )
        SearchFilterChip(
            filter: SearchFilter(id: "missed", label: "is: missed", token: "is:missed")
        )
    }
    .padding()
}

// MARK: - PreviewChipAction

/// A no-op the preview passes by name; a closure literal at the call site
/// would trip SwiftLint's trailing-closure rule.
private enum PreviewChipAction {
    static let none: @Sendable (SearchFilter) -> Void = { _ in }
}
