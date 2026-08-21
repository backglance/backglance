import Foundation

// MARK: - OTPRedactor

/// Replaces one-time codes with a placeholder before anything is written down.
///
/// 🔒 Privacy Invariant #2. This runs in memory, on the capture path, *before*
/// `Archive.insert` — so the original digits never reach the archive, the FTS index, the
/// embeddings, an export or the log. There is no key and no second copy: redaction is
/// irreversible by construction, not by policy. Switching redaction off later affects only
/// notifications captured afterwards, because there is nothing left to un-redact.
///
/// Pure and synchronous: no I/O, no logging, no archive. Everything it knows about what a
/// code looks like lives in ``OTPPatterns``; this type is only the walk over the fields and
/// the decision at each candidate.
///
/// It takes a ``Content`` triple rather than a `ParsedNotification` because that type
/// belongs to `BackglanceCapture`, which depends on this module and not the other way
/// round (docs/architecture/ARCHITECTURE.md#dependency-graph). `BackglanceCapture` adds the
/// one-line adapter.
///
/// See docs/features/PRIVACY_CONTROLS.md#otpredactor.
public struct OTPRedactor: Sendable {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - window: how far from a digit group a keyword still counts as context.
    ///   - keywordSets: the vocabulary. Injectable so a test can pin one language.
    ///   - now: the audit row's timestamp.
    public init(
        window: Int = OTPPatterns.keywordWindow,
        keywordSets: [OTPPatterns.KeywordSet] = OTPPatterns.builtIn,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.window = window
        self.keywordSets = keywordSets
        self.now = now
    }

    // MARK: Public

    /// The three fields that can hold a code.
    ///
    /// Sender, thread id and category are deliberately absent: a code does not arrive in
    /// them, and scanning fields that cannot contain one only adds false positives.
    public struct Content: Sendable, Equatable {
        // MARK: Lifecycle

        public init(title: String? = nil, subtitle: String? = nil, body: String? = nil) {
            self.title = title
            self.subtitle = subtitle
            self.body = body
        }

        // MARK: Public

        public var title: String?
        public var subtitle: String?
        public var body: String?
    }

    /// What came back. `event` is `nil` when nothing was touched — and in that case
    /// ``content`` is byte-identical to what went in, so a caller can rely on either.
    public struct Result: Sendable, Equatable {
        public let content: Content

        /// The audit row: `kind` and `pattern_id` and a timestamp. Never the original,
        /// never a hash of it, never its length.
        public let event: RedactionEvent?

        public var didRedact: Bool {
            event != nil
        }
    }

    /// The shipped configuration.
    public static let `default` = OTPRedactor()

    public let window: Int
    public let keywordSets: [OTPPatterns.KeywordSet]

    /// Redacts every code-shaped group the guards and the keyword context agree on.
    ///
    /// A keyword in the title or subtitle is context for digits in the *body*: titles are
    /// short, and senders routinely put "Verification code" in the title and the digits
    /// alone in the body. It does not work the other way round — a body long enough to
    /// mention "code" somewhere should not license redacting a number in the title.
    public func redact(_ content: Content) -> Result {
        // Evaluated once, not per field: the header is context, and it does not change.
        let headerSet = OTPPatterns.keywordSet(in: content.title ?? "", among: keywordSets)
            ?? OTPPatterns.keywordSet(in: content.subtitle ?? "", among: keywordSets)

        var redacted = content
        var patternID: String?

        for field in [\Content.title, \Content.subtitle, \Content.body] {
            guard let text = content[keyPath: field], !text.isEmpty else {
                continue
            }
            let outcome = redactField(text, headerSet: field == \Content.body ? headerSet : nil)
            guard let matched = outcome.patternID else {
                continue
            }
            redacted[keyPath: field] = outcome.text
            patternID = patternID ?? matched
        }

        guard let patternID else {
            return Result(content: content, event: nil)
        }
        return Result(
            content: redacted,
            event: RedactionEvent(kind: .otp, patternId: patternID, redactedAt: UnixDate(now()))
        )
    }

    // MARK: Private

    private let now: @Sendable () -> Date

    /// One field's worth of work.
    ///
    /// Candidates are replaced back to front so that an earlier range stays valid while a
    /// later one is being rewritten — the placeholder is a different length from the
    /// digits it replaces, so going forwards would invalidate every index after the first
    /// substitution.
    private func redactField(_ text: String, headerSet: OTPPatterns.KeywordSet?) -> (text: String, patternID: String?) {
        // A field that is nothing but a code needs no keyword — some senders' SMS bodies
        // are literally "445 566". A year is exempt: a notification whose whole body is
        // "2026" is far more likely a date than a code.
        if OTPPatterns.isBareCode(text) {
            let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !OTPPatterns.isYearLike(digits) {
                return (OTPPatterns.placeholder, OTPPatterns.barePatternID)
            }
        }

        var result = text
        var patternID: String?

        for range in OTPPatterns.codeRanges(in: text).reversed() {
            let digits = String(text[range])
            let before = String(text[text.startIndex ..< range.lowerBound].suffix(window))
            let after = String(text[range.upperBound...].prefix(window))

            guard OTPPatterns.hasCodeBoundaries(before: before, after: after),
                  !OTPPatterns.looksLikeDate(before: before, after: after),
                  !OTPPatterns.partOfLongerNumber(digits: digits, before: before, after: after)
            else {
                continue
            }

            guard let set = context(for: digits, before: before, after: after, headerSet: headerSet) else {
                continue
            }
            result = result.replacingCharacters(in: range, with: OTPPatterns.placeholder)
            patternID = set.patternID
        }
        return (result, patternID)
    }

    /// Which keyword set, if any, vouches for this group.
    ///
    /// A year-like group has to find its keyword within ``OTPPatterns/yearWindow`` and
    /// cannot borrow the header's: "see you in 2027" inside a notification titled
    /// "Login code" would otherwise be redacted, and the *year* is the part of that
    /// sentence the reader needs.
    private func context(
        for digits: String,
        before: String,
        after: String,
        headerSet: OTPPatterns.KeywordSet?
    ) -> OTPPatterns.KeywordSet? {
        let yearLike = OTPPatterns.isYearLike(digits)
        let reach = yearLike ? OTPPatterns.yearWindow : window
        let nearby = String(before.suffix(reach)) + " " + String(after.prefix(reach))
        if let set = OTPPatterns.keywordSet(in: nearby, among: keywordSets) {
            return set
        }
        return yearLike ? nil : headerSet
    }
}
