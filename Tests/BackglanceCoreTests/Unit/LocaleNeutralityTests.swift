@testable import BackglanceCore
import Foundation
import XCTest

/// The Turkish locale rule, pinned.
///
/// Turkish has four letters where English has two — `I`/`ı` dotless and `İ`/`i` dotted —
/// so under Turkish casing rules `"I"` lowercases to `"ı"`. Every equality, prefix or
/// containment check built on a locale-sensitive case operation therefore stops matching
/// on a Turkish-locale Mac, and on no other. That is the worst shape a bug can have: it
/// passes CI, it passes review, and it fails only for the users whose language the feature
/// was written for.
///
/// These tests exist because the fix is invisible. Nothing about `lowercased()` versus
/// `lowercased(with:)` reads as important at a call site, so the behaviour is asserted
/// here and the spelling is enforced by the `no_locale_sensitive_case_folding` SwiftLint
/// rule. Neither alone would hold: the linter cannot tell whether the *result* is right,
/// and a test cannot stop the next call site from being written the wrong way.
///
/// 🔒 The digit strings below are repeated pairs (`445566`), the same fabrication
/// `OTPRedactorTests` uses: Privacy Invariant #5 forbids anything that could pass for a
/// real verification code.
///
/// See docs/reference/INTERNATIONALIZATION.md#the-turkish-locale-rule.
final class LocaleNeutralityTests: XCTestCase {
    // MARK: - The failure mode itself

    /// Documents what is being defended against, so that a reader who has never met this
    /// bug can see it happen rather than take the rule on trust.
    func testTheDottedDotlessIBugIsReal() {
        let turkish = Locale(identifier: "tr")

        XCTAssertEqual("TITLE".lowercased(with: turkish), "tıtle")
        XCTAssertNotEqual("TITLE".lowercased(with: turkish), "title")
        XCTAssertEqual("PIN".lowercased(with: turkish), "pın")
    }

    /// And what the sanctioned spelling does instead. `lowercased()` with no argument
    /// applies the Unicode default mapping, which does not depend on anybody's locale.
    func testBareLowercasedIsLocaleIndependent() {
        XCTAssertEqual("TITLE".lowercased(), "title")
        XCTAssertEqual("PIN".lowercased(), "pin")
        XCTAssertEqual("İSTANBUL".lowercased(), "i̇stanbul")
    }

    // MARK: - matchKey

    /// The primitive every internal comparison goes through. A shouted keyword folds to
    /// the same key as a typed one, with a dotted i rather than a dotless one.
    func testMatchKeyFoldsCaseWithoutTheTurkishTrap() {
        XCTAssertEqual("PIN".matchKey, "pin")
        XCTAssertEqual("TITLE".matchKey, "title")
        XCTAssertEqual("Login Code".matchKey, "login code")
    }

    /// Diacritics fold too, in both directions. Someone typing a rule on a keyboard
    /// without Turkish layout writes "dogrulama"; the sender wrote "Doğrulama". Both have
    /// to reach the same key or the rule matches nothing on exactly the messages it was
    /// written for.
    func testMatchKeyFoldsDiacriticsInBothDirections() {
        XCTAssertEqual("Doğrulama".matchKey, "dogrulama")
        XCTAssertEqual("dogrulama".matchKey, "dogrulama")
        XCTAssertEqual("ŞİFRE".matchKey, "sifre")
    }

    /// "İstanbul", "ISTANBUL" and "istanbul" are one key. This is the doc's own example,
    /// and it is the one that would break first: the dotted capital İ is what a Turkish
    /// sender's app name actually contains.
    func testTheThreeSpellingsOfIstanbulAreOneKey() {
        let keys = Set(["İstanbul", "ISTANBUL", "istanbul", "İSTANBUL"].map(\.matchKey))

        XCTAssertEqual(keys, ["istanbul"])
    }

    /// Bundle identifiers are ASCII in practice, which is exactly why the wrong spelling
    /// would survive review here: it would look harmless right up until an app shipped
    /// one that was not.
    func testBundleIdentifiersCompareEqualAfterNeutralFolding() {
        XCTAssertEqual("com.tinyspeck.slackmacgap".lowercased(), "COM.TINYSPECK.SLACKMACGAP".lowercased())
        XCTAssertNotEqual("com.apple.MobileSMS".lowercased(), "com.apple.mail".lowercased())
    }

    // MARK: - The paths that depend on it

    /// 🔒 Redaction is the path where this stops being a correctness question. A Turkish
    /// keyword that fails to match is a one-time code archived in plain text, on the Macs
    /// whose language the keyword list was written for.
    func testTheRedactorMatchesATurkishKeywordShoutedAndUnaccented() {
        for body in ["DOĞRULAMA KODUNUZ 445566", "Dogrulama kodunuz 445566"] {
            let result = OTPRedactor.default.redact(OTPRedactor.Content(body: body))

            XCTAssertEqual(result.event?.patternId, "otp.keyword.tr", body)
            XCTAssertFalse(result.content.body?.contains("445566") ?? true, body)
        }
    }

    /// The same for English, where the trap is the plainest word in the list: "PIN".
    func testTheRedactorMatchesAShoutedEnglishKeyword() {
        let result = OTPRedactor.default.redact(OTPRedactor.Content(body: "YOUR PIN IS 445566"))

        XCTAssertEqual(result.event?.patternId, "otp.keyword.en")
        XCTAssertFalse(result.content.body?.contains("445566") ?? true)
    }

    /// Presenting detection matches a window title by prefix, and window titles are
    /// shouted more often than not.
    func testPresentationTitleMatchingSurvivesTheTurkishTrap() {
        let observation = PresentationPolicy.Observation(
            windows: [.init(ownerName: "Microsoft Teams", name: "SHARING CONTROLS")]
        )

        XCTAssertTrue(PresentationPolicy().isPresenting(observation))
    }

    // MARK: - What is still allowed to be locale-aware

    /// Sorting for display is the one place a locale *should* decide, because the user
    /// expects their own alphabet's order. Asserting the order itself would be asserting
    /// the runner's locale, so this asserts what is actually guaranteed: a total order
    /// that loses nothing.
    func testDisplaySortMayBeLocaleAwareAndStaysStable() {
        let names = ["iTerm", "İşbank", "Ivory", "index"]

        let sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        XCTAssertEqual(Set(sorted), Set(names))
        XCTAssertEqual(sorted.count, names.count)
    }
}
