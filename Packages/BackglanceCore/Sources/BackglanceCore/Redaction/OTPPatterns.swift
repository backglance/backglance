import Foundation

// MARK: - OTPPatterns

/// The matching data behind one-time-code redaction: which words mean "this is a code",
/// what a code looks like, and which digit groups are something else wearing the same
/// shape.
///
/// Split from the redactor on purpose. Everything here answers a question about a string
/// and returns a fact; ``OTPRedactor`` decides what to do about it. That is what lets the
/// false-positive guards — the part that actually decides whether someone's rent payment
/// gets mangled — be tested one at a time, by name, instead of only through their effect
/// on a whole notification.
///
/// 🔒 The keyword lists are **compiled in, not localized resources**. Three reasons, all
/// load-bearing (docs/reference/INTERNATIONALIZATION.md#otp-keyword-lists-live-in-code):
///
/// 1. They are matching data, not UI text. All lists are active at once regardless of the
///    UI language — someone running an English UI still receives Turkish SMS.
/// 2. Changing redaction behaviour must go through code review and these tests, not
///    through a translation PR.
/// 3. Each list has a stable `pattern_id` that is recorded in the `redactions` audit row,
///    so a false positive can be discussed by identifier rather than by quoting content.
///
/// See docs/features/PRIVACY_CONTROLS.md#detection-patterns.
public enum OTPPatterns {
    // MARK: Public

    /// One language's worth of "a code is nearby" vocabulary.
    public struct KeywordSet: Sendable, Equatable {
        // MARK: Lifecycle

        /// - Parameters:
        ///   - keywords: stored folded through ``Swift/String/matchKey``, so a caller
        ///     cannot accidentally register a keyword that never matches.
        ///   - prefixMatch: for agglutinative languages. Turkish suffixes mean the word
        ///     in the wild is "kodunuz" or "şifreniz", never the bare stem.
        public init(patternID: String, keywords: [String], prefixMatch: Bool = false) {
            self.patternID = patternID
            self.keywords = keywords.map(\.matchKey)
            self.prefixMatch = prefixMatch
        }

        // MARK: Public

        /// Recorded in `redactions.pattern_id`. Stable: changing one rewrites history's
        /// meaning without rewriting history.
        public let patternID: String

        /// Already folded to match keys.
        public let keywords: [String]

        /// Whether a token starting with a keyword counts as that keyword.
        public let prefixMatch: Bool
    }

    /// What replaces the digits. Irreversible by design: there is no key, no cipher and no
    /// second copy — the original never reaches the archive at all.
    public static let placeholder = "[code redacted]"

    /// The `pattern_id` for a field that is nothing but a code.
    public static let barePatternID = "otp.bare"

    /// How far from a digit group a keyword still counts as context.
    ///
    /// Forty characters is about one clause. Wider starts pulling in the keyword from an
    /// unrelated sentence; narrower misses "Your verification code for Example is 123456".
    public static let keywordWindow = 40

    /// The narrower window for a group that could be a year.
    ///
    /// "See you in 2027, login at example.com" has a keyword 20 characters away and is not
    /// a code. Four digits in the 1900–2099 range have to earn it from much closer.
    public static let yearWindow = 12

    /// The built-in vocabulary. English, Turkish and German, all active at once.
    public static let builtIn: [KeywordSet] = [
        KeywordSet(
            patternID: "otp.keyword.en",
            keywords: ["code", "verification", "passcode", "otp", "one-time", "pin", "login"]
        ),
        KeywordSet(
            patternID: "otp.keyword.tr",
            keywords: ["kod", "doğrulama", "şifre"],
            prefixMatch: true
        ),
        KeywordSet(
            patternID: "otp.keyword.de",
            keywords: ["code", "bestätigungscode", "einmalpasswort"]
        ),
    ]

    /// Every digit group in `text` that has the shape of a code, in source order.
    ///
    /// Shape only — whether a group *is* a code depends on the guards and the keyword
    /// context, which the redactor applies. Deliberately no lookaround: the boundary rules
    /// live in ``hasCodeBoundaries(before:after:)`` where they can be read and tested,
    /// rather than inside a pattern nobody can debug.
    public static func codeRanges(in text: String) -> [Range<String.Index>] {
        text.ranges(of: digitGroup)
    }

    /// Whether the whole field, trimmed, is nothing but a code.
    ///
    /// Some senders' SMS bodies are literally "123 456", with no words at all — no keyword
    /// can rescue those, so the shape alone has to be enough.
    public static func isBareCode(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(of: digitGroup) != nil
    }

    /// Whether the characters either side of a group let it be a code at all.
    ///
    /// Rejects the shapes that are *made* of digit groups: prices, percentages, times and
    /// reference numbers glued into a longer run.
    ///
    /// - Parameters:
    ///   - before: the text immediately preceding the group, nearest character last.
    ///   - after: the text immediately following it, nearest character first.
    public static func hasCodeBoundaries(before: String, after: String) -> Bool {
        if let previous = before.last, rejectedBefore.contains(previous) {
            return false
        }
        if let next = after.first, rejectedAfter.contains(next) {
            return false
        }
        // "4999 EUR" is a price even though a space separates them.
        let trailing = after.drop(while: \.isWhitespace).prefix(3).uppercased()
        return !currencyWords.contains { trailing.hasPrefix($0) }
    }

    /// Whether a group is part of a date written around it — `01.09.2026`, `2026-09-01`.
    public static func looksLikeDate(before: String, after: String) -> Bool {
        before.firstMatch(of: dateBefore) != nil || after.firstMatch(of: dateAfter) != nil
    }

    /// Whether the group is a slice of a longer number, which is how phone numbers look.
    ///
    /// Walks outward through the characters a phone number is allowed to contain. More
    /// than eight digits in the run, or a leading `+`, is not a code: `+1 555 0100` and
    /// `(555) 010-0100` both contain a perfectly code-shaped `0100`.
    public static func partOfLongerNumber(digits: String, before: String, after: String) -> Bool {
        var run = digits.count { $0.isNumber }
        for character in before.reversed() {
            if character.isNumber {
                run += 1
            } else if character == "+" {
                return true
            } else if !phoneGlue.contains(character) {
                break
            }
        }
        for character in after {
            if character.isNumber {
                run += 1
            } else if !phoneGlue.contains(character) {
                break
            }
        }
        return run > 8
    }

    /// Whether a group could be a year, and so has to earn its keyword from closer up.
    public static func isYearLike(_ digits: String) -> Bool {
        guard digits.count == 4, let value = Int(digits) else {
            return false
        }
        return (1_900 ... 2_099).contains(value)
    }

    /// The first keyword set with a keyword among `text`'s words, or `nil`.
    ///
    /// Tokenised on anything that is not a letter or a hyphen, so "pin" does not match
    /// inside "shipping" and "code" does not match inside "barcode" — substring matching
    /// here would redact half the notifications an online shop sends.
    public static func keywordSet(in text: String, among sets: [KeywordSet] = builtIn) -> KeywordSet? {
        let tokens = text.matchKey.split { !($0.isLetter || $0 == "-") }.map(String.init)
        guard !tokens.isEmpty else {
            return nil
        }
        return sets.first { set in
            set.keywords.contains { keyword in
                tokens.contains { set.prefixMatch ? $0.hasPrefix(keyword) : $0 == keyword }
            }
        }
    }

    // MARK: Private

    /// 4–8 digits, or two groups of 3–4 split by one space or hyphen.
    ///
    /// A literal rather than a runtime-compiled `NSRegularExpression`: a typo here is a
    /// build error instead of a `try!` that crashes on the first notification, which is
    /// not a trade anyone should take on the one type standing between a verification code
    /// and permanent storage.
    private static let digitGroup = #/\d{3,4}[ -]\d{3,4}|\d{4,8}/#

    private static let dateBefore = #/\d{1,2}[./-]\d{1,2}[./-]\s?$/#
    private static let dateAfter = #/^(\s?[./-]\d{1,2}[./-]\d{1,2}|-\d{2}-\d{2})/#

    /// A group glued to any of these is part of a number, not a code.
    private static let rejectedBefore: Set<Character> = [".", ",", ":", "+", "(", "€", "₺", "$", "£", "¥", "₹"]

    private static let rejectedAfter: Set<Character> = [".", ",", ":", "%", "€", "₺", "$", "£", "¥", "₹"]

    /// Checked against the first three characters after the group, uppercased.
    private static let currencyWords = ["USD", "EUR", "TRY", "TL", "GBP"]

    /// What a phone number may contain between its digits.
    private static let phoneGlue: Set<Character> = [" ", "-", "(", ")", "+"]
}
