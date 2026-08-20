import BackglanceCore
import Foundation

// MARK: - QueryParser

/// Turns one text field into a ``ParsedQuery``: free text for FTS, fuzzy and
/// semantic search, plus structured filters for `WHERE`.
///
/// It never rejects free text — a filter with a value it doesn't recognize
/// (`is:foo`) or a key it has never heard of (`re:invoice`) degrades to a
/// plain search term rather than an error. The single exception is a
/// `before:`/`after:`/`on:` value that is neither a date nor a relative
/// offset, because there is no reasonable text interpretation of "search for
/// the word `soon`" that respects what the user actually typed after a date
/// key.
///
/// See docs/features/SEARCH.md#queryparser-grammar and
/// docs/api/API_DOCUMENTATION.md#queryparser-grammar. The two disagree on
/// whether `today`/`yesterday` are valid `after:` values; this type follows
/// SEARCH.md, the feature spec, and accepts them.
public enum QueryParser {
    // MARK: Public

    /// - Parameters:
    ///   - text: The raw search field contents, grammar included.
    ///   - now: The instant relative dates (`today`, `-7d`, …) resolve
    ///     against. Injected so tests don't depend on when they run.
    ///   - calendar: The calendar whose local midnight defines day
    ///     boundaries. Injected for the same reason, and because "local"
    ///     has to mean something specific in a test.
    /// - Throws: ``SearchError/invalidQuery(_:)`` for an unreadable
    ///   `before:`/`after:`/`on:` value. Never for anything else.
    public static func parse(
        _ text: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> ParsedQuery {
        var result = ParsedQuery()
        var positive: [String] = []
        var negative: [String] = []
        var lastFreeIndex: Int?

        for token in tokenize(text) {
            if token.isNegated {
                negative.append(ftsQuote(literalText(for: token)))
                continue
            }
            if try dispatchFilter(token, to: &result, now: now, calendar: calendar) {
                continue
            }
            appendFreeText(token, positive: &positive, terms: &result.terms, lastFreeIndex: &lastFreeIndex)
        }

        if let i = lastFreeIndex {
            positive[i] += "*"
        }
        result.ftsMatch = buildFtsMatch(positive: positive, negative: negative)
        return result
    }

    // MARK: Private

    /// One lexical unit: either a plain word or a quoted phrase, with an
    /// optional key when a phrase followed a `key:` prefix with no space
    /// (`sender:"Ayşe"`). Everything else with a colon (`before:2026-08-01`)
    /// keeps its full text in ``value`` and is split by ``splitKeyValue(_:)``
    /// later, because a colon inside a bare word is ambiguous until we know
    /// whether the key is one we recognize.
    private struct RawToken {
        var key: String?
        var value: String
        var isPhrase: Bool
        var isNegated: Bool
    }

    private static let knownKeys: Set<String> = [
        "from", "app", "sender", "thread", "before", "after", "on", "is", "has", "redacted",
    ]

    /// Applies a token that carries a recognized `key:value` filter.
    /// Returns `false` when the token isn't a filter at all (no colon, or an
    /// unknown key) or names a known key with a value we don't recognize
    /// (`is:foo`) — either way the caller falls back to free text.
    private static func dispatchFilter(
        _ token: RawToken,
        to result: inout ParsedQuery,
        now: Date,
        calendar: Calendar
    ) throws -> Bool {
        if let key = token.key {
            guard knownKeys.contains(key) else {
                return false
            }
            return try applyFilter(key: key, value: token.value, to: &result, now: now, calendar: calendar)
        }
        guard !token.isPhrase, let (key, value) = splitKeyValue(token.value), knownKeys.contains(key) else {
            return false
        }
        return try applyFilter(key: key, value: value, to: &result, now: now, calendar: calendar)
    }

    private static func applyFilter(
        key: String,
        value: String,
        to result: inout ParsedQuery,
        now: Date,
        calendar: Calendar
    ) throws -> Bool {
        switch key {
        case "from",
             "app":
            applyApp(value, to: &result)
        case "sender":
            result.sender = value
        case "thread":
            result.threadID = value
        case "before":
            result.before = try dayStart(of: value, key: key, now: now, calendar: calendar)
        case "after":
            result.after = try dayStart(of: value, key: key, now: now, calendar: calendar)
        case "on":
            try applyOn(value, key: key, to: &result, now: now, calendar: calendar)
        case "is":
            return applyIsFlag(value, to: &result)
        case "has":
            return applyHasFlag(value, to: &result)
        case "redacted":
            return applyRedacted(value, to: &result)
        default:
            return false
        }
        return true
    }

    /// `from:`/`app:` values are either a bundle id (`com.tinyspeck.slackmacgap`)
    /// or a display name fragment (`slack`); there's no resolver here — that
    /// lookup against the archive's known apps happens downstream — so this
    /// is a shape test, not a real answer to "does this app exist."
    private static func applyApp(_ value: String, to result: inout ParsedQuery) {
        if looksLikeBundleID(value) {
            result.bundleIDs.insert(value)
        } else {
            result.appNameContains = value
        }
    }

    private static func applyOn(
        _ value: String,
        key: String,
        to result: inout ParsedQuery,
        now: Date,
        calendar: Calendar
    ) throws {
        let start = try dayStart(of: value, key: key, now: now, calendar: calendar)
        result.after = start
        result.before = calendar.date(byAdding: .day, value: 1, to: start)
    }

    private static func applyIsFlag(_ value: String, to result: inout ParsedQuery) -> Bool {
        switch value.lowercased() {
        case "unread": result.flags.insert(.unread)
        case "read": result.flags.insert(.read)
        case "pinned": result.flags.insert(.pinned)
        case "missed": result.flags.insert(.missed)
        case "vip": result.flags.insert(.vip)
        default: return false
        }
        return true
    }

    private static func applyHasFlag(_ value: String, to result: inout ParsedQuery) -> Bool {
        switch value.lowercased() {
        case "link": result.flags.insert(.hasLink)
        case "attachment": result.flags.insert(.hasAttachment)
        default: return false
        }
        return true
    }

    private static func applyRedacted(_ value: String, to result: inout ParsedQuery) -> Bool {
        guard value.lowercased() == "yes" else {
            return false
        }
        result.flags.insert(.redacted)
        return true
    }

    private static func looksLikeBundleID(_ value: String) -> Bool {
        guard value.contains(".") else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // MARK: - Free text

    /// A phrase or bare word that isn't a filter: quoted for FTS, kept
    /// unquoted in ``ParsedQuery/terms`` for fuzzy/semantic, and — for bare
    /// words only — tracked as the current candidate for the trailing `*`
    /// so as-you-type prefix matching works. Phrases never get the star:
    /// `"flight confirmation"*` would match `"flight confirmation anything"`,
    /// which isn't what a phrase search means.
    private static func appendFreeText(
        _ token: RawToken,
        positive: inout [String],
        terms: inout [String],
        lastFreeIndex: inout Int?
    ) {
        let text = literalText(for: token)
        positive.append(ftsQuote(text))
        terms.append(text)
        if !token.isPhrase {
            lastFreeIndex = positive.count - 1
        }
    }

    /// The literal text a token contributes when it isn't being treated as a
    /// filter: `key:value` reconstructed for a quote-attached key
    /// (`sender:"Ayşe"` → `sender:Ayşe`), or the token's own text otherwise.
    private static func literalText(for token: RawToken) -> String {
        guard let key = token.key else {
            return token.value
        }
        return "\(key):\(token.value)"
    }

    private static func ftsQuote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func buildFtsMatch(positive: [String], negative: [String]) -> String? {
        guard !positive.isEmpty || !negative.isEmpty else {
            return nil
        }
        guard !positive.isEmpty else {
            return negative.joined(separator: " OR ")
        }
        var expr = "(" + positive.joined(separator: " ") + ")"
        for term in negative {
            expr += " NOT \(term)"
        }
        return expr
    }

    /// Splits `key:value` on the first colon. `nil` when there's no colon,
    /// the colon is the first character (`:foo` is free text, not an empty
    /// key), or there's nothing after it.
    private static func splitKeyValue(_ text: String) -> (String, String)? {
        guard let colon = text.firstIndex(of: ":"), colon != text.startIndex else {
            return nil
        }
        let key = text[..<colon].lowercased()
        let value = String(text[text.index(after: colon)...])
        guard !value.isEmpty else {
            return nil
        }
        return (key, value)
    }

    // MARK: - Dates

    private static func dayStart(of raw: String, key: String, now: Date, calendar: Calendar) throws -> Date {
        let value = raw.lowercased()
        if let named = namedDayStart(value, now: now, calendar: calendar) {
            return named
        }
        if let relative = relativeDayStart(value, now: now, calendar: calendar) {
            return relative
        }
        if let absolute = absoluteDayStart(value, calendar: calendar) {
            return absolute
        }
        throw SearchError.invalidQuery(
            "\(key): use yyyy-MM-dd, today, yesterday, or a relative offset like -7d, -2w, -36h."
        )
    }

    private static func namedDayStart(_ value: String, now: Date, calendar: Calendar) -> Date? {
        switch value {
        case "today":
            calendar.startOfDay(for: now)
        case "yesterday":
            calendar.date(byAdding: .day, value: -1, to: now).map { calendar.startOfDay(for: $0) }
        default:
            nil
        }
    }

    /// `-7d`, `-2w`, `-36h`: day and week offsets snap to that day's local
    /// midnight, hours stay exact — "36 hours ago" is a moment, not a day.
    private static func relativeDayStart(_ value: String, now: Date, calendar: Calendar) -> Date? {
        guard value.hasPrefix("-"), let unit = value.last else {
            return nil
        }
        let numberPart = value.dropFirst().dropLast()
        guard !numberPart.isEmpty, let amount = Int(numberPart), amount >= 0 else {
            return nil
        }
        switch unit {
        case "d":
            return calendar.date(byAdding: .day, value: -amount, to: now).map { calendar.startOfDay(for: $0) }
        case "w":
            return calendar.date(byAdding: .day, value: -7 * amount, to: now).map { calendar.startOfDay(for: $0) }
        case "h":
            return calendar.date(byAdding: .hour, value: -amount, to: now)
        default:
            return nil
        }
    }

    private static func absoluteDayStart(_ value: String, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else {
            return nil
        }
        return calendar.startOfDay(for: date)
    }

    // MARK: - Tokenizer

    /// Splits raw text into ``RawToken``s. A word runs until whitespace or a
    /// `"`; a `"` starts a phrase that runs to the matching close (or the
    /// end of the text, for an unbalanced quote); a `"` immediately after a
    /// `key:`-shaped word (no space) attaches to that key instead of
    /// starting a fresh, key-less phrase, so `sender:"Ayşe"` reads as one
    /// filter rather than the free word `sender:` next to a phrase. A `-`
    /// at the start of a word negates it; a lone `-` (nothing after it)
    /// produces no token at all.
    private static func tokenize(_ text: String) -> [RawToken] {
        var tokens: [RawToken] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace {
                i += 1
            }
            guard i < chars.count else {
                break
            }

            var negated = false
            if chars[i] == "-" {
                negated = true
                i += 1
            }
            guard i < chars.count, !chars[i].isWhitespace else {
                continue
            }

            let (token, next) = readToken(chars, from: i, negated: negated)
            tokens.append(token)
            i = next
        }
        return tokens
    }

    private static func readToken(_ chars: [Character], from start: Int, negated: Bool) -> (RawToken, Int) {
        if chars[start] == "\"" {
            let (value, next) = readPhrase(chars, from: start + 1)
            return (RawToken(key: nil, value: value, isPhrase: true, isNegated: negated), next)
        }

        let (head, afterHead) = readWord(chars, from: start)
        if afterHead < chars.count, chars[afterHead] == "\"", head.hasSuffix(":"), head.count > 1 {
            let key = String(head.dropLast())
            let (value, next) = readPhrase(chars, from: afterHead + 1)
            return (RawToken(key: key, value: value, isPhrase: true, isNegated: negated), next)
        }
        return (RawToken(key: nil, value: head, isPhrase: false, isNegated: negated), afterHead)
    }

    private static func readWord(_ chars: [Character], from start: Int) -> (String, Int) {
        var i = start
        var word = ""
        while i < chars.count, !chars[i].isWhitespace, chars[i] != "\"" {
            word.append(chars[i])
            i += 1
        }
        return (word, i)
    }

    /// Reads phrase content starting just past the opening `"`. `""` inside
    /// the phrase is a literal quote (so a phrase can contain one at all);
    /// a single `"` closes it. Running out of text without a close is the
    /// unbalanced-quote case: the phrase simply ends at the end of input.
    private static func readPhrase(_ chars: [Character], from start: Int) -> (String, Int) {
        var i = start
        var value = ""
        while i < chars.count {
            if chars[i] == "\"" {
                if i + 1 < chars.count, chars[i + 1] == "\"" {
                    value.append("\"")
                    i += 2
                    continue
                }
                i += 1
                break
            }
            value.append(chars[i])
            i += 1
        }
        return (value, i)
    }
}
