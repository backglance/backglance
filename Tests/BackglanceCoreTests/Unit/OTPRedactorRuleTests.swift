@testable import BackglanceCore
import BackglanceTestSupport
import Foundation
import XCTest

/// The exhaustive, seeded counterpart to `OTPRedactorTests`.
///
/// That file is a handful of readable, single-case examples that a reviewer can read
/// top to bottom. This one is a corpus: every keyword family, run many times over
/// codes of every width the shape allows, plus a false-positive corpus of ordinary
/// messages that must survive untouched. Where `OTPRedactorTests` answers "does the
/// redactor route a matched field into the right place", this file answers "across a
/// wide, seeded sample of realistic-looking traffic, does it fire on exactly the
/// right subset and nothing else".
///
/// 🔒 Privacy Invariant #5: no realistic one-time code may appear as a literal in this
/// file. Every code below comes from `SplitMix64` at run time — the same generator the
/// synthetic fixtures use — so nothing here could be mistaken for, or ever equal, a
/// code that actually arrived on someone's phone. The false-positive corpus is exempt
/// by construction: dates, prices, phone numbers and tracking numbers are deliberately
/// not codes, and are safe to write down verbatim.
final class OTPRedactorRuleTests: XCTestCase {
    // MARK: Internal

    // MARK: - True positives

    /// One template per keyword family the redactor ships with. `%@` marks where the
    /// synthetic code is substituted; every template carries a real keyword from
    /// `OTPPatterns.builtIn`, within the 40-character context window of `%@`, so a
    /// failure here means the redactor missed a code, not that the template forgot to
    /// earn one.
    func testEveryKeywordTemplateRedactsCodesOfEveryWidthAcrossFortyIterations() {
        var rng = SplitMix64(seed: 20_260_817)
        for (patternID, template) in Self.templates {
            for _ in 0 ..< 40 {
                let width = 4 + rng.int(below: 5) // 4...8
                var code = Self.syntheticCode(width: width, rng: &rng)
                // Sometimes split the code the way real senders do: "1234 56" / "123-456".
                if width >= 6, rng.int(below: 3) == 0 {
                    let mid = code.index(code.startIndex, offsetBy: width / 2)
                    let separator = rng.int(below: 2) == 0 ? " " : "-"
                    code = String(code[..<mid]) + separator + String(code[mid...])
                }
                let body = template.replacingOccurrences(of: "%@", with: code)

                let result = redactor.redact(.init(body: body))
                let redacted = result.content.body ?? ""

                XCTAssertTrue(
                    redacted.contains(OTPPatterns.placeholder),
                    "\(patternID): placeholder missing in \(redacted)"
                )
                XCTAssertFalse(redacted.contains(code), "\(patternID): original code survived in \(redacted)")
                XCTAssertFalse(
                    Self.containsCodeShapedRun(redacted),
                    "\(patternID): a 4-8 digit run remains in \(redacted)"
                )
                XCTAssertEqual(result.event?.kind, .otp, patternID)
                XCTAssertEqual(result.event?.patternId, patternID, "template: \(template)")
            }
        }
    }

    /// Some senders' SMS bodies are nothing but the code — no keyword anywhere to
    /// anchor a match, so the bare-field rule has to carry the whole thing on shape
    /// alone.
    func testABodyThatIsOnlyASyntheticCodeIsRedactedWithoutAKeywordAcrossFiftyIterations() {
        var rng = SplitMix64(seed: 20_260_818)
        for _ in 0 ..< 50 {
            let code = Self.syntheticCode(width: 4 + rng.int(below: 5), rng: &rng)
            let result = redactor.redact(.init(body: code))

            XCTAssertEqual(result.content.body, OTPPatterns.placeholder, "code: \(code)")
            XCTAssertEqual(result.event?.patternId, OTPPatterns.barePatternID)
        }
    }

    /// A sender who puts the code in both the title and the body should not get one
    /// field cleaned and the other left holding the original digits.
    func testASyntheticCodeAppearingInBothTitleAndBodyIsRedactedInBoth() {
        var rng = SplitMix64(seed: 20_260_819)
        let code = Self.syntheticCode(width: 6, rng: &rng)
        let result = redactor.redact(.init(
            title: "Code \(code)",
            body: "Your verification code is \(code)"
        ))

        XCTAssertFalse(Self.containsCodeShapedRun(result.content.title ?? ""), "title still carries a code-shaped run")
        XCTAssertFalse(Self.containsCodeShapedRun(result.content.body ?? ""), "body still carries a code-shaped run")
        XCTAssertNotNil(result.event)
    }

    /// The case the corpus above steers around, tested on its own rather than left
    /// uncovered.
    ///
    /// `syntheticCode(width:rng:)` rerolls a 4-digit draw that lands in 1900...2099,
    /// because a year-shaped group has to earn its keyword from within
    /// `OTPPatterns.yearWindow` rather than the usual window — and a template whose
    /// keyword sits further away than that would fail for a reason that is about the year
    /// heuristic rather than about the template. Steering around it in the corpus is only
    /// legitimate if the steered-around case is asserted somewhere, so it is asserted
    /// here: close keyword, year-shaped digits, still a code.
    func testAYearShapedCodeIsStillRedactedWhenTheKeywordIsCloseEnough() {
        var rng = SplitMix64(seed: 20_260_821)
        var digits = String(rng.next() % 10_000)
        while !OTPPatterns.isYearLike(String(repeating: "0", count: max(0, 4 - digits.count)) + digits) {
            digits = String(rng.next() % 10_000)
        }
        let code = String(repeating: "0", count: max(0, 4 - digits.count)) + digits

        let result = redactor.redact(.init(body: "Code \(code)"))

        XCTAssertEqual(result.content.body, "Code \(OTPPatterns.placeholder)", "code: \(code)")
        XCTAssertEqual(result.event?.patternId, "otp.keyword.en")
    }

    // MARK: - False positives

    /// Ordinary messages that happen to contain digit runs — years, prices, phone
    /// numbers, order numbers, times, invoice numbers, tracking numbers, scores,
    /// ISBNs — must come back byte-identical. None of these strings are one-time
    /// codes, and none of them contain one, so copying them verbatim breaks no
    /// privacy rule.
    func testOrdinaryMessagesWithDigitRunsComeBackByteIdenticalWithNoEvent() {
        for body in Self.falsePositiveCorpus {
            let content = OTPRedactor.Content(body: body)
            let result = redactor.redact(content)

            XCTAssertEqual(result.content, content, "false positive on: \(body)")
            XCTAssertNil(result.event, "false positive event on: \(body)")
        }
    }

    /// The keyword is present, but more than the 40-character context window away
    /// from the digit run — a keyword anywhere in a long message must not license
    /// redacting an unrelated number far away from it.
    func testAKeywordMoreThanTheContextWindowAwayFromTheDigitsLeavesThemUntouched() {
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 3) // 81 characters
        let body = "Please enter the code on the next screen. \(filler) Ref 48213."
        let content = OTPRedactor.Content(body: body)

        let result = redactor.redact(content)

        XCTAssertEqual(result.content, content)
        XCTAssertNil(result.event)
    }

    // MARK: Private

    /// One template per keyword family, spanning all three built-in languages. Every
    /// template contains a real keyword from `OTPPatterns.builtIn` (`code`,
    /// `verification`, `passcode`, `otp`, `one-time`, `pin`, `login` in English;
    /// `kod`, `doğrulama`, `şifre` in Turkish, prefix-matched; `code`,
    /// `bestätigungscode`, `einmalpasswort` in German), placed close enough to `%@`
    /// to fall inside the keyword window.
    private static let templates: [(patternID: String, template: String)] = [
        ("otp.keyword.en", "Your verification code is %@"),
        ("otp.keyword.en", "%@ is your one-time passcode. Do not share it."),
        ("otp.keyword.en", "Use PIN %@ to log in"),
        ("otp.keyword.en", "Login code: %@"),
        ("otp.keyword.en", "Your OTP is %@"),
        ("otp.keyword.tr", "Doğrulama kodunuz: %@"),
        ("otp.keyword.tr", "Tek kullanımlık şifreniz %@"),
        ("otp.keyword.tr", "Giriş kodu %@"),
        ("otp.keyword.de", "Ihr Bestätigungscode lautet %@"),
        ("otp.keyword.de", "Einmalpasswort: %@"),
        ("otp.keyword.de", "Zur Bestätigung Ihres Kontos senden wir den Bestätigungscode %@"),
    ]

    /// Ordinary messages that contain digit runs and must be left alone. Every one of
    /// these exercises a different false-positive guard: a year, a price, a phone
    /// number, an order number, a time, a room number, a date, a tracking number, a
    /// score plus an unrelated number with no keyword nearby, and an ISBN.
    private static let falsePositiveCorpus: [String] = [
        "See you at the 2026 reunion, same place as 2019",
        "Total charged: $1,249.00 — thanks for your order",
        "Call me back at +1 555 0100 when you land",
        "Order #48213 has shipped and arrives Thursday",
        "Your flight departs 18:45 from gate 22",
        "Meeting moved to room 4021, third floor",
        "Invoice 2026-0817 is due 2026-09-01",
        "Tracking number 1Z999AA10123456784",
        "The score was 3-1, then 4021 people left early",
        "ISBN 9780306406157 arrived today",
    ]

    private let redactor = OTPRedactor.default

    /// Digits of the requested width from the seeded generator; never a literal in
    /// source. Zero-padded so every width actually produces the requested number of
    /// digits, including when the generator draws a small value.
    ///
    /// A 4-digit draw that lands in 1900...2099 is rerolled: `OTPRedactor` deliberately
    /// treats a year-shaped group as a year rather than a code (`OTPPatterns.isYearLike`)
    /// and only lets a keyword within its much narrower `yearWindow` vouch for it — a
    /// long keyword such as "Bestätigungscode" sitting further than that from the digits
    /// would then be missed or misattributed. That is the redactor doing exactly what its
    /// own doc comment says a year should do; this corpus is about keyword-anchored
    /// redaction, so it steers around that documented edge rather than tripping over it.
    private static func syntheticCode(width: Int, rng: inout SplitMix64) -> String {
        var limit: UInt64 = 1
        for _ in 0 ..< width {
            limit *= 10
        }
        var digits = String(rng.next() % limit)
        digits = String(repeating: "0", count: width - digits.count) + digits
        while width == 4, OTPPatterns.isYearLike(digits) {
            digits = String(rng.next() % limit)
            digits = String(repeating: "0", count: width - digits.count) + digits
        }
        return digits
    }

    /// Whether any 4-8 digit run remains once the space/hyphen a split code might use
    /// is collapsed out — the same shape `OTPPatterns.codeRanges` looks for, checked
    /// independently of the redactor's own logic.
    private static func containsCodeShapedRun(_ text: String) -> Bool {
        let collapsed = text.replacingOccurrences(of: "[ -]", with: "", options: .regularExpression)
        return collapsed.range(of: #"\d{4,8}"#, options: .regularExpression) != nil
    }
}
