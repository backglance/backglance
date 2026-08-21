@testable import BackglanceCore
import Foundation
import XCTest

/// Covers `OTPRedactor` — the walk over a notification's fields and the decision to
/// replace or leave a digit run, end to end.
///
/// 🔒 Every digit string here is fabricated: sequential (`123456`) or a repeated pair
/// (`445566`, `778899`). Privacy Invariant #5 forbids anything that could pass for a real
/// verification code, and a file about redacting codes is exactly where that discipline
/// matters most.
///
/// `OTPPatternsTests` covers the individual shape/boundary/keyword questions in isolation.
/// This file is the other half: does the redactor route those answers into the right
/// fields, does it survive doing so more than once per field, and does the audit row it
/// produces carry nothing but an identifier and a timestamp.
final class OTPRedactorTests: XCTestCase {
    // MARK: Internal

    // MARK: - Codes that must be redacted

    func testAKeywordAndDigitsInTheSameSentenceAreRedacted() throws {
        let result = redactor.redact(.init(body: "Your verification code is 445566"))

        XCTAssertTrue(try XCTUnwrap(result.content.body?.contains(OTPPatterns.placeholder)))
        XCTAssertFalse(try XCTUnwrap(result.content.body?.contains("445566")))
        XCTAssertEqual(result.event?.patternId, "otp.keyword.en")
    }

    func testABareFieldOfNothingButDigitsIsRedactedWithoutAKeyword() {
        // Some senders' SMS bodies are literally "445 566" — no word anywhere to anchor a
        // keyword match, so the shape alone has to carry it.
        let result = redactor.redact(.init(body: "445 566"))

        XCTAssertEqual(result.content.body, OTPPatterns.placeholder)
        XCTAssertEqual(result.event?.patternId, "otp.bare")
    }

    func testTurkishKeywordWithColonIsRedacted() throws {
        let result = redactor.redact(.init(body: "Doğrulama kodunuz: 445566"))

        XCTAssertFalse(try XCTUnwrap(result.content.body?.contains("445566")))
        XCTAssertEqual(result.event?.patternId, "otp.keyword.tr")
    }

    func testTurkishKeywordWithoutDiacriticsIsRedacted() throws {
        // What a sender typing without a Turkish keyboard actually writes.
        let result = redactor.redact(.init(body: "Dogrulama kodunuz 445566"))

        XCTAssertFalse(try XCTUnwrap(result.content.body?.contains("445566")))
        XCTAssertEqual(result.event?.patternId, "otp.keyword.tr")
    }

    func testGermanKeywordIsRedacted() throws {
        let result = redactor.redact(.init(body: "Ihr Bestätigungscode lautet 445566"))

        XCTAssertFalse(try XCTUnwrap(result.content.body?.contains("445566")))
        XCTAssertEqual(result.event?.patternId, "otp.keyword.de")
    }

    func testAKeywordInAShortTitleIsContextForDigitsInTheBody() throws {
        let result = redactor.redact(.init(title: "Verification code", body: "445566"))

        XCTAssertEqual(result.content.title, "Verification code", "the title itself has no digits to touch")
        XCTAssertFalse(try XCTUnwrap(result.content.body?.contains("445566")))
        XCTAssertNotNil(result.event)
    }

    func testTheHeaderContextPathIsWhatRedactsABodyWithNoKeywordOfItsOwn() throws {
        // The case above goes through the bare-field rule, which needs no keyword at all —
        // so it never actually exercises header context. This body has words around the
        // digits and no keyword of its own; only the title can vouch for it.
        let result = redactor.redact(.init(title: "Verification code", body: "Use 445566 to sign in"))

        XCTAssertFalse(try XCTUnwrap(result.content.body?.contains("445566")))
        XCTAssertEqual(try XCTUnwrap(result.event).patternId, "otp.keyword.en")
    }

    func testAPluralKeywordInTheBodyStillRedacts() throws {
        // Ordinary English. An exact-token rule would let this straight through.
        let result = redactor.redact(.init(body: "Your codes are 445566 and 778899"))

        let body = try XCTUnwrap(result.content.body)
        XCTAssertFalse(body.contains("445566"))
        XCTAssertFalse(body.contains("778899"))
        XCTAssertEqual(try XCTUnwrap(result.event).patternId, "otp.keyword.en")
    }

    func testMultipleCodesInOneBodyAreBothRedacted() throws {
        // Each code carries its own nearby "code", so this exercises the reversed,
        // back-to-front replacement rather than the keyword-context search: a bug in the
        // reversal would leave one digit run intact, or slice the string at the wrong
        // index once the first (different-length) replacement shifted things.
        let result = redactor.redact(.init(body: "Use code 445566 or code 778899 to sign in"))
        let body = try XCTUnwrap(result.content.body)

        XCTAssertFalse(body.contains("445566"))
        XCTAssertFalse(body.contains("778899"))
        XCTAssertEqual(body.components(separatedBy: OTPPatterns.placeholder).count - 1, 2, "both codes replaced")
    }

    func testACodeInTheTitleItselfIsRedacted() throws {
        let result = redactor.redact(.init(title: "Login code 445566"))

        XCTAssertFalse(try XCTUnwrap(result.content.title?.contains("445566")))
        XCTAssertEqual(result.event?.patternId, "otp.keyword.en")
    }

    // MARK: - Text that must survive untouched

    func testAPriceIsNotRedacted() {
        // If this fails, the currency-word guard in `hasCodeBoundaries` broke, and every
        // receipt notification loses its total.
        let content = OTPRedactor.Content(body: "Your order total is 4999 USD")
        let result = redactor.redact(content)

        XCTAssertEqual(result.content, content)
        XCTAssertNil(result.event)
    }

    func testAPhoneNumberIsNotRedacted() {
        // If this fails, `partOfLongerNumber` stopped recognising the leading "+", and a
        // support line's callback number gets mangled into "[code redacted]".
        let content = OTPRedactor.Content(body: "Call us on +1 555 0100 for help")
        let result = redactor.redact(content)

        XCTAssertEqual(result.content, content)
        XCTAssertNil(result.event)
    }

    func testADateIsNotRedacted() {
        // If this fails, the dot-separated boundary guard broke, and every appointment
        // reminder loses its date.
        let content = OTPRedactor.Content(body: "Your appointment is on 01.09.2026")
        let result = redactor.redact(content)

        XCTAssertEqual(result.content, content)
        XCTAssertNil(result.event)
    }

    func testAYearWithAKeywordFarAwayIsNotRedacted() {
        // "login" sits at the very start of the sentence; the year is 21 characters later
        // (" expires, see you in " between them), which is well outside the 12-character
        // year window. If this fails, a year window regression is letting an unrelated
        // keyword anywhere in a long sentence license a false redaction.
        let body = "Your login expires, see you in 2027 at the earliest"
        let content = OTPRedactor.Content(body: body)
        let result = redactor.redact(content)

        XCTAssertEqual(result.content, content)
        XCTAssertNil(result.event)
    }

    func testATrackingNumberWithNoKeywordIsNotRedacted() {
        // "shipping" contains "pin" as a substring, not as a word — if tokenisation ever
        // regresses to substring matching, this is the notification that starts losing its
        // tracking number.
        let content = OTPRedactor.Content(body: "Your shipping update: package 12345678 is out for delivery")
        let result = redactor.redact(content)

        XCTAssertEqual(result.content, content)
        XCTAssertNil(result.event)
    }

    func testTextWithNoDigitsComesBackByteIdentical() {
        let content = OTPRedactor.Content(
            title: "Weekly digest",
            subtitle: "From your team",
            body: "Nothing new to report this week."
        )
        let result = redactor.redact(content)

        XCTAssertEqual(result.content, content)
        XCTAssertNil(result.event)
    }

    // MARK: - The audit row

    func testTheAuditRowCarriesOnlyKindPatternAndTimestamp() throws {
        let result = redactor.redact(.init(body: "Your verification code is 445566"))
        let event = try XCTUnwrap(result.event)

        XCTAssertEqual(event.kind, .otp)
        XCTAssertEqual(event.patternId, "otp.keyword.en")
        XCTAssertEqual(event.redactedAt, UnixDate(fixedDate))
    }

    func testRedactionEventHasNoPropertyThatCouldHoldContent() {
        // A future field added to hold "context" or a preview would be exactly the leak
        // Privacy Invariant #2 forbids. Pinning the property set here means adding one
        // fails this test, not a privacy review months later.
        let event = RedactionEvent(
            id: 1,
            notificationId: 2,
            kind: .otp,
            patternId: "otp.bare",
            redactedAt: UnixDate(fixedDate)
        )
        let propertyNames = Set(Mirror(reflecting: event).children.compactMap(\.label))

        XCTAssertEqual(propertyNames, ["id", "notificationId", "kind", "patternId", "redactedAt"])
    }

    func testPatternIdIsTheFirstMatchInTitleSubtitleBodyOrder() throws {
        let result = redactor.redact(.init(
            title: "Ihr Bestätigungscode lautet 112233",
            subtitle: "Doğrulama kodunuz: 223344",
            body: "Your code is 334455"
        ))

        XCTAssertFalse(try XCTUnwrap(result.content.title?.contains("112233")))
        XCTAssertFalse(try XCTUnwrap(result.content.subtitle?.contains("223344")))
        XCTAssertFalse(try XCTUnwrap(result.content.body?.contains("334455")))
        XCTAssertEqual(result.event?.patternId, "otp.keyword.de", "title is scanned before subtitle and body")
    }

    // MARK: - Structural

    func testDefaultUsesTheBuiltInPatternsAndWindow() {
        XCTAssertEqual(OTPRedactor.default.keywordSets, OTPPatterns.builtIn)
        XCTAssertEqual(OTPRedactor.default.window, OTPPatterns.keywordWindow)
    }

    func testAnInjectedSingleLanguageKeywordSetDoesNotMatchAnotherLanguage() {
        let englishOnly = OTPRedactor(keywordSets: [OTPPatterns.builtIn[0]]) { [fixedDate] in fixedDate }
        let content = OTPRedactor.Content(body: "Doğrulama kodunuz: 445566")
        let result = englishOnly.redact(content)

        XCTAssertEqual(
            result.content,
            content,
            "no English keyword in a Turkish message, so nothing licenses a redaction"
        )
        XCTAssertNil(result.event)
    }

    // MARK: Private

    private let fixedDate = Date(timeIntervalSince1970: 1_755_421_200)

    private lazy var redactor = OTPRedactor { [fixedDate] in fixedDate }
}
