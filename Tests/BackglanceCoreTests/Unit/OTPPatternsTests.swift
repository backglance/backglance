@testable import BackglanceCore
import Foundation
import XCTest

/// Covers `OTPPatterns` — the shapes and the vocabulary, one question at a time.
///
/// 🔒 Every string here is fabricated. Privacy Invariant #5 forbids a real verification
/// code in a fixture, and that applies to a test that is *about* verification codes more
/// than anywhere else: the digits below are sequential or obviously synthetic, never
/// anything that arrived on someone's phone.
///
/// The false-positive cases matter as much as the true positives. A redactor that eats
/// prices, phone numbers and dates is not cautious, it is broken — it destroys content
/// irreversibly, and the user cannot get it back to check.
final class OTPPatternsTests: XCTestCase {
    // MARK: Internal

    // MARK: - Shapes that are codes

    func testFourToEightDigitRunsAreCandidates() {
        for digits in ["1234", "12345", "123456", "1234567", "12345678"] {
            XCTAssertEqual(ranges(in: digits), [digits], "\(digits.count) digits is a code shape")
        }
    }

    func testThreeDigitsAloneIsNotACandidate() {
        XCTAssertTrue(ranges(in: "123").isEmpty, "too short to be a code, and far too common to guess at")
    }

    func testNineDigitsMatchesOnlyTheFirstEight() {
        // The shape caps at eight; the phone guard is what rejects the rest.
        XCTAssertEqual(ranges(in: "123456789"), ["12345678"])
    }

    func testSplitGroupsSeparatedByOneSpaceOrHyphenAreOneCandidate() {
        XCTAssertEqual(ranges(in: "123 456"), ["123 456"])
        XCTAssertEqual(ranges(in: "1234-5678"), ["1234-5678"])
    }

    func testACandidateIsFoundInsideASentence() {
        XCTAssertEqual(ranges(in: "Your code is 445566 and expires soon"), ["445566"])
    }

    // MARK: - The bare field

    func testAFieldThatIsNothingButDigitsIsBare() {
        XCTAssertTrue(OTPPatterns.isBareCode("445566"))
        XCTAssertTrue(OTPPatterns.isBareCode("  445 566 \n"), "leading and trailing space is still bare")
    }

    func testAFieldWithAnyWordsIsNotBare() {
        XCTAssertFalse(OTPPatterns.isBareCode("code 445566"))
        XCTAssertFalse(OTPPatterns.isBareCode("445566."), "a full stop is a sentence, not a bare code")
    }

    // MARK: - Boundaries: prices, times, percentages

    func testACurrencySymbolBeforeRejectsTheGroup() {
        for symbol in ["$", "£", "€", "₺"] {
            XCTAssertFalse(OTPPatterns.hasCodeBoundaries(before: "spent \(symbol)", after: " today"), symbol)
        }
    }

    func testACurrencyWordAfterRejectsTheGroup() {
        for word in ["USD", "EUR", "TRY", "TL", "GBP"] {
            XCTAssertFalse(OTPPatterns.hasCodeBoundaries(before: "total ", after: " \(word)"), word)
        }
    }

    func testADecimalOrThousandsSeparatorAfterRejectsTheGroup() {
        XCTAssertFalse(OTPPatterns.hasCodeBoundaries(before: "costs ", after: ".50"))
        XCTAssertFalse(OTPPatterns.hasCodeBoundaries(before: "costs ", after: ",50"))
    }

    func testAPercentAfterRejectsTheGroup() {
        XCTAssertFalse(OTPPatterns.hasCodeBoundaries(before: "up ", after: "% this year"))
    }

    func testAColonEitherSideRejectsTheGroup() {
        // Times and "ref: 1234"-style prefixes.
        XCTAssertFalse(OTPPatterns.hasCodeBoundaries(before: "at 12:", after: " sharp"))
        XCTAssertFalse(OTPPatterns.hasCodeBoundaries(before: "at ", after: ":30"))
    }

    func testAnOrdinaryWordBoundaryIsAccepted() {
        XCTAssertTrue(OTPPatterns.hasCodeBoundaries(before: "code is ", after: " — expires soon"))
        XCTAssertTrue(OTPPatterns.hasCodeBoundaries(before: "", after: ""), "a whole field is a valid boundary")
    }

    // MARK: - Dates

    func testADayMonthPrefixIsADate() {
        XCTAssertTrue(OTPPatterns.looksLikeDate(before: "on 01.09.", after: " at noon"), "01.09.2026")
        XCTAssertTrue(OTPPatterns.looksLikeDate(before: "on 1/9/", after: ""), "single-digit day and month")
    }

    func testAnIsoSuffixIsADate() {
        XCTAssertTrue(OTPPatterns.looksLikeDate(before: "due ", after: "-09-01"), "2026-09-01")
    }

    func testOrdinaryTextIsNotADate() {
        XCTAssertFalse(OTPPatterns.looksLikeDate(before: "your code is ", after: " — use it once"))
    }

    // MARK: - Phone numbers

    func testAnInternationalPrefixIsNotACode() {
        XCTAssertTrue(OTPPatterns.partOfLongerNumber(digits: "555 0100", before: "call +1 ", after: ""))
    }

    func testAParenthesisedAreaCodeIsNotACode() {
        XCTAssertTrue(OTPPatterns.partOfLongerNumber(digits: "010-0100", before: "call (555) ", after: ""))
    }

    func testARunOfMoreThanEightDigitsIsNotACode() {
        XCTAssertTrue(OTPPatterns.partOfLongerNumber(digits: "12345678", before: "", after: "9012"))
    }

    func testAnOrdinarySixDigitCodeIsNotPartOfALongerNumber() {
        XCTAssertFalse(OTPPatterns.partOfLongerNumber(digits: "445566", before: "code is ", after: " thanks"))
    }

    func testAdjacentWordsWithDigitsDoNotExtendTheRun() {
        // "445566 in 30 minutes" — the 30 is a different number, cut off by the letters.
        XCTAssertFalse(OTPPatterns.partOfLongerNumber(digits: "445566", before: "", after: " in 30 minutes"))
    }

    // MARK: - Years

    func testFourDigitsInTheYearRangeAreYearLike() {
        XCTAssertTrue(OTPPatterns.isYearLike("2027"))
        XCTAssertTrue(OTPPatterns.isYearLike("1999"))
    }

    func testFourDigitsOutsideTheYearRangeAreNot() {
        XCTAssertFalse(OTPPatterns.isYearLike("1234"))
        XCTAssertFalse(OTPPatterns.isYearLike("4455"))
    }

    func testOnlyFourDigitGroupsCanBeYearLike() {
        XCTAssertFalse(OTPPatterns.isYearLike("20270"))
        XCTAssertFalse(OTPPatterns.isYearLike("202"))
    }

    // MARK: - Keywords

    func testEnglishKeywordsMatchTheirOwnSet() {
        for keyword in ["code", "verification", "passcode", "OTP", "one-time", "PIN", "login"] {
            XCTAssertEqual(
                OTPPatterns.keywordSet(in: "Your \(keyword) is")?.patternID,
                "otp.keyword.en",
                keyword
            )
        }
    }

    func testGermanKeywordsMatchTheirOwnSet() {
        for keyword in ["Bestätigungscode", "Einmalpasswort"] {
            XCTAssertEqual(OTPPatterns.keywordSet(in: "Ihr \(keyword) lautet")?.patternID, "otp.keyword.de", keyword)
        }
    }

    func testTurkishKeywordsMatchWithTheirSuffixes() {
        // The stem never appears bare in the wild — Turkish agglutinates.
        for text in ["kodunuz", "doğrulama kodu", "şifreniz"] {
            XCTAssertEqual(OTPPatterns.keywordSet(in: text)?.patternID, "otp.keyword.tr", text)
        }
    }

    func testTurkishKeywordsMatchWithoutTheirDiacritics() {
        // What a sender without a Turkish keyboard writes, and what folding has to reach.
        XCTAssertEqual(OTPPatterns.keywordSet(in: "dogrulama kodunuz")?.patternID, "otp.keyword.tr")
        XCTAssertEqual(OTPPatterns.keywordSet(in: "sifreniz")?.patternID, "otp.keyword.tr")
    }

    func testKeywordsMatchRegardlessOfCase() {
        XCTAssertNotNil(OTPPatterns.keywordSet(in: "YOUR CODE IS"))
        XCTAssertNotNil(OTPPatterns.keywordSet(in: "Your Code Is"))
    }

    func testAPluralKeywordStillMatches() {
        // "Your codes are…" is ordinary English, and an exact-token rule would let both
        // codes through. A missed code is the worse way to fail: the digits get archived.
        XCTAssertEqual(OTPPatterns.keywordSet(in: "your codes are")?.patternID, "otp.keyword.en")
        XCTAssertEqual(OTPPatterns.keywordSet(in: "two passcodes below")?.patternID, "otp.keyword.en")
    }

    func testThePluralAllowanceIsASuffixOnlyAndDoesNotReopenSubstringMatching() {
        // Only a trailing "s", so "barcode" — a word the lists are *inside* — still misses.
        XCTAssertNil(OTPPatterns.keywordSet(in: "scan the barcodes below"))
        XCTAssertNil(OTPPatterns.keywordSet(in: "shipping updates"))
    }

    func testAKeywordInsideALongerWordDoesNotMatch() {
        // The whole reason matching is tokenised: substring matching would redact a
        // shipping notification's tracking number and a barcode's digits.
        XCTAssertNil(OTPPatterns.keywordSet(in: "your shipping update"), "shipping contains pin")
        XCTAssertNil(OTPPatterns.keywordSet(in: "scan the barcode below"), "barcode contains code")
        XCTAssertNil(OTPPatterns.keywordSet(in: "encoded payload"), "encoded contains code")
    }

    func testTextWithNoKeywordMatchesNothing() {
        XCTAssertNil(OTPPatterns.keywordSet(in: "Your package arrives tomorrow"))
        XCTAssertNil(OTPPatterns.keywordSet(in: ""))
        XCTAssertNil(OTPPatterns.keywordSet(in: "445566"), "digits alone are not a keyword")
    }

    // MARK: - The vocabulary itself

    func testEveryBuiltInSetHasAStablePatternID() {
        // These identifiers reach `redactions.pattern_id`. Renaming one silently changes
        // what every historical audit row claims happened.
        XCTAssertEqual(OTPPatterns.builtIn.map(\.patternID), ["otp.keyword.en", "otp.keyword.tr", "otp.keyword.de"])
        XCTAssertEqual(OTPPatterns.barePatternID, "otp.bare")
    }

    func testKeywordsAreStoredFolded() {
        // A keyword registered with capitals or diacritics would never match a folded
        // token, and would fail silently. The initializer folds so it cannot happen.
        let set = OTPPatterns.KeywordSet(patternID: "otp.keyword.test", keywords: ["Doğrulama", "CODE"])
        XCTAssertEqual(set.keywords, ["dogrulama", "code"])
    }

    func testOnlyTheDeclaredLanguagesShip() {
        XCTAssertEqual(OTPPatterns.builtIn.count, 3, "a new language is a code PR with tests, not a translation")
    }

    // MARK: - matchKey

    func testMatchKeyFoldsCaseAndDiacritics() {
        XCTAssertEqual("İstanbul".matchKey, "istanbul")
        XCTAssertEqual("ISTANBUL".matchKey, "istanbul")
        XCTAssertEqual("doğrulama".matchKey, "dogrulama")
    }

    func testMatchKeyIsLocaleNeutral() {
        // 🔒 The Turkish dotless-I rule: `lowercased(with: tr)` maps "PIN" to "pın", which
        // would silently switch the English keyword off for Turkish users.
        XCTAssertEqual("PIN".matchKey, "pin")
        XCTAssertEqual("I".matchKey, "i")
    }

    // MARK: Private

    private func ranges(in text: String) -> [String] {
        OTPPatterns.codeRanges(in: text).map { String(text[$0]) }
    }
}
