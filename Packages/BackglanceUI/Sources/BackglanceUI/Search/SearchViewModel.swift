import BackglanceCore
import Foundation
import Observation

// MARK: - SearchRunning

/// Something that can answer a ``BackglanceCore/SearchQuery``.
///
/// The engine — `HybridSearch`, with its FTS index, fuzzy matcher and
/// embeddings — lives in `BackglanceSearch`, which this package must never
/// import (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction). So
/// the view model depends on the *question* instead, and the app shell hands it
/// something that answers. Tests hand it a stub and get determinism for free.
public protocol SearchRunning: Sendable {
    /// - Parameter semanticEnabled: the user's Settings toggle, passed per call
    ///   because it can change between one keystroke and the next.
    func search(_ query: SearchQuery, semanticEnabled: Bool) async throws -> [SearchHit]
}

// MARK: - SearchViewModel

/// The search field's state: what was typed, what came back, and what is still
/// in flight.
///
/// Two things keep search cheap while someone is typing. A 120 ms debounce, so
/// a fast typist causes one query per pause rather than one per keystroke; and
/// cancellation, so a superseded query stops reading the archive rather than
/// racing the newer one to the finish. Both matter more than they sound: a
/// search that runs per keystroke is how a menu bar app ends up with a spinning
/// fan.
///
/// See docs/features/SEARCH.md#debounce-and-cancellation.
@MainActor
@Observable
public final class SearchViewModel {
    // MARK: Lifecycle

    public init(
        search: any SearchRunning,
        semanticEnabled: @escaping @Sendable () -> Bool = { false },
        debounce: Duration = .milliseconds(120)
    ) {
        self.search = search
        self.semanticEnabled = semanticEnabled
        self.debounce = debounce
    }

    deinit {
        task?.cancel()
    }

    // MARK: Public

    public private(set) var hits: [SearchHit] = []

    /// Whether a query is in flight. The bar shows a spinner on a delay, so a
    /// search that finishes quickly never flickers one.
    public private(set) var isSearching = false

    /// One sentence under the field — never an alert, and never the query text.
    public private(set) var inlineError: String?

    /// What the user typed. Assigning schedules a search; it does not run one.
    public var text = "" {
        didSet {
            guard oldValue != text else {
                return
            }
            schedule()
        }
    }

    /// Whether the field has anything worth searching for.
    public var hasQuery: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Which empty state the results area should show.
    public var emptyStateKind: SearchEmptyState.Kind {
        guard hasQuery else {
            return .noQuery
        }
        // A sentence-shaped query with the semantic branch off is the one case
        // worth explaining rather than just saying "nothing matched".
        if hits.isEmpty, !semanticEnabled(), looksLikeASentence {
            return .semanticOff
        }
        return .noResults
    }

    /// Clears the field and everything it produced. What `Esc` does before it
    /// closes anything.
    public func clear() {
        task?.cancel()
        text = ""
        hits = []
        inlineError = nil
        isSearching = false
    }

    /// Runs the current text immediately, skipping the debounce — what ↩ does.
    public func searchNow() async {
        task?.cancel()
        await run(text)
    }

    // MARK: Internal

    /// Three words or more, none of them carrying grammar. Short of that, the
    /// semantic hint would fire on `from:slack invoice` and read as nonsense.
    var looksLikeASentence: Bool {
        let words = text.split(separator: " ").filter { !$0.contains(":") && !$0.hasPrefix("-") }
        return words.count >= 3
    }

    // MARK: Private

    private let search: any SearchRunning
    private let semanticEnabled: @Sendable () -> Bool
    private let debounce: Duration

    @ObservationIgnored nonisolated(unsafe) private var task: Task<Void, Never>?

    private func schedule() {
        task?.cancel()
        let snapshot = text
        task = Task { [weak self] in
            guard let self else {
                return
            }
            // Sleeping first is what makes this a debounce rather than a
            // throttle: a cancelled sleep throws before any work is started.
            guard await (try? Task.sleep(for: debounce)) != nil else {
                return
            }
            await run(snapshot)
        }
    }

    private func run(_ snapshot: String) async {
        guard !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hits = []
            inlineError = nil
            isSearching = false
            return
        }

        isSearching = true
        do {
            let result = try await search.search(SearchQuery(text: snapshot), semanticEnabled: semanticEnabled())
            // A newer keystroke may have won while this was reading.
            try Task.checkCancellation()
            hits = result
            inlineError = nil
            isSearching = false
        } catch is CancellationError {
            // Superseded. The newer task owns the field now, and setting
            // anything here would fight it.
        } catch let error as SearchError {
            guard error != .cancelled else {
                return
            }
            inlineError = error.userMessage
            isSearching = false
        } catch {
            inlineError = String(localized: "Search failed. Try again in a moment.")
            isSearching = false
            // The type name only: a query string is notification content by
            // another name, and so is anything an error made out of one.
            Log.search.error("search failed: \(String(describing: type(of: error)))")
        }
    }
}
