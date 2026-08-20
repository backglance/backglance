import SwiftUI

// MARK: - SemanticIndexProgress

/// The thin bar under the search bar while `EmbeddingIndexer` is building the
/// semantic index (docs/features/SEARCH.md#ui-components: "`SemanticIndexProgress`
/// … thin progress bar under the search bar while `EmbeddingIndexer` is
/// running; `"Indexing 3,120 of 41,000"`").
///
/// Renders nothing once the count catches up to the total, or when there is
/// nothing to index at all — a bar that lingers at 100% after the work is
/// done is noise, not status.
public struct SemanticIndexProgress: View {
    // MARK: Lifecycle

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }

    // MARK: Public

    public let done: Int
    public let total: Int

    public var body: some View {
        if total > 0, done < total {
            ProgressView(value: Double(done), total: Double(total))
                .progressViewStyle(.linear)
                .controlSize(.small)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(statusText)
        }
    }

    // MARK: Private

    /// "Indexing 3,120 of 41,000" — grouped per the user's locale, not a
    /// raw digit run, so a large archive still reads at a glance.
    private var statusText: String {
        let doneText = done.formatted(.number)
        let totalText = total.formatted(.number)
        return String(localized: "Indexing \(doneText) of \(totalText)")
    }
}

// MARK: - Previews

#Preview("In Progress") {
    SemanticIndexProgress(done: 3_120, total: 41_000)
        .padding()
        .frame(width: 380)
}

#Preview("Nothing To Index") {
    SemanticIndexProgress(done: 0, total: 0)
        .padding()
        .frame(width: 380)
}

#Preview("Finished") {
    SemanticIndexProgress(done: 41_000, total: 41_000)
        .padding()
        .frame(width: 380)
}
