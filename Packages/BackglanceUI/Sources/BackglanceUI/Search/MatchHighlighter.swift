import Foundation

// MARK: - MatchHighlighter

/// Turns an FTS5 `snippet()`/`highlight()` string into an `AttributedString`
/// with the matched runs bold (docs/features/SEARCH.md#ui-components,
/// docs/features/SEARCH.md#fts-ranking-and-highlighting).
///
/// FTS5 wraps each match in two private-use scalars — U+E000/U+E001 by
/// default — chosen precisely because no notification text can contain
/// them, so a marker is unambiguous, not merely unlikely. Runs between an
/// open and a matching close marker are marked with
/// `InlinePresentationIntentAttribute`, set through `AttributedString`'s
/// explicit-attribute-type subscript rather than the `.inlinePresentationIntent`
/// convenience property: under `StrictConcurrency`, that property (like a
/// SwiftUI range key path, `text[range].font = …`) is implemented as dynamic
/// member lookup that builds a `KeyPath` internally, and `KeyPath` isn't
/// `Sendable` — confirmed with `swiftc -strict-concurrency=complete` against
/// a two-line repro outside this file, so it is not particular to how this
/// type calls it. The subscript below takes the attribute's type as a plain
/// static argument instead of a key path, so no such value is ever formed.
public enum MatchHighlighter {
    /// - Parameters:
    ///   - snippet: the marked string, e.g. `"an \u{E000}invoice\u{E001} is due"`.
    ///   - open: the open marker. Defaults to FTS5's `char(57344)` (U+E000).
    ///   - close: the close marker. Defaults to FTS5's `char(57345)` (U+E001).
    /// - Returns: the same text, markers removed, matched runs emphasized.
    ///
    /// An open marker with no matching close (truncated snippet, or a future
    /// FTS5 build that changes its escaping) still emphasizes to the end of
    /// the string rather than losing the remaining text or crashing — the
    /// same "degrade, don't drop" posture the rest of search follows. A
    /// snippet with no markers at all comes back as plain text. Nesting
    /// cannot happen — FTS5 never emits an open marker inside a match — so
    /// this does not track a stack, only a single boolean.
    public static func attributed(
        _ snippet: String,
        open: String = "\u{E000}",
        close: String = "\u{E001}"
    ) -> AttributedString {
        guard let openScalar = open.unicodeScalars.first, open.unicodeScalars.count == 1,
              let closeScalar = close.unicodeScalars.first, close.unicodeScalars.count == 1
        else {
            // A caller-supplied marker that isn't a single scalar can't be
            // matched character-by-character below; treat the input as
            // already-plain text rather than mis-highlighting it.
            return AttributedString(snippet)
        }

        var result = AttributedString()
        var buffer = ""
        var isMatch = false

        func flush(emphasized: Bool) {
            guard !buffer.isEmpty else {
                return
            }
            var run = AttributedString(buffer)
            if emphasized {
                run[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self] = .stronglyEmphasized
            }
            result += run
            buffer = ""
        }

        for character in snippet {
            if character.unicodeScalars.count == 1,
               character.unicodeScalars[character.unicodeScalars.startIndex] == openScalar
            {
                flush(emphasized: isMatch)
                isMatch = true
                continue
            }
            if character.unicodeScalars.count == 1,
               character.unicodeScalars[character.unicodeScalars.startIndex] == closeScalar
            {
                flush(emphasized: isMatch)
                isMatch = false
                continue
            }
            buffer.append(character)
        }
        flush(emphasized: isMatch)
        return result
    }
}
