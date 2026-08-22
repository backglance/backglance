@testable import BackglanceCore
import Foundation
import XCTest

/// Covers `RulesEngine.evaluate(_:compiled:bundleID:appIsMuted:)`
/// (`RulesEngine+Evaluate.swift`): matching semantics (folding, whole-word bounds,
/// field/app scope) and evaluation order / conflict resolution (accumulation, highlight
/// priority, VIP-beats-mute, per-app mute). See docs/features/RULES.md's "Matching
/// Semantics" and "Evaluation Order and Conflict Resolution" sections — the worked
/// example there is reproduced verbatim below.
final class RulesEngineEvaluateTests: XCTestCase {
    // MARK: Internal

    // MARK: - Fast path

    /// An empty compiled set costs nothing and matches nothing.
    func testNoRulesReturnsNone() {
        let triage = RulesEngine.evaluate(Self.notification(), compiled: .empty)

        XCTAssertEqual(triage, .none)
    }

    // MARK: - Worked example

    /// docs/features/RULES.md#evaluation-order-and-conflict-resolution's worked example,
    /// reproduced exactly: rule 3 beats rule 2 on priority for the highlight colour, rule
    /// 4's VIP cancels rule 1's mute, rule 5 misses on field (`body`, and this row has no
    /// body), rule 6 misses on app scope, and `matchedRuleIDs` lands in compiled order.
    /// This one table is the best regression test for the whole engine.
    func testWorkedExampleFromTheDoc() {
        let rules = [
            Self.rule(1, .mute, "com.tinyspeck.slackmacgap", field: .app, priority: 10),
            Self.rule(2, .highlight, "urgent", color: "red", priority: 0),
            Self.rule(
                3,
                .highlight,
                "\"deploy failed\"",
                field: .title,
                appBundleId: "com.tinyspeck.slackmacgap",
                color: "amber",
                priority: 5
            ),
            Self.rule(4, .vip, "ayse", field: .sender, priority: 0),
            Self.rule(5, .highlight, "invoice", field: .body, color: "green", priority: 20),
            Self.rule(6, .mute, "newsletter", appBundleId: "com.apple.mail", priority: 0),
        ]
        let (compiled, problems) = RulesEngine.compile(rules)
        XCTAssertTrue(problems.isEmpty)

        let triage = RulesEngine.evaluate(
            Self.notification(), compiled: compiled, bundleID: "com.tinyspeck.slackmacgap"
        )

        XCTAssertEqual(
            triage,
            Triage(highlight: .amber, pinned: true, muted: false, matchedRuleIDs: [1, 3, 2, 4])
        )
    }

    // MARK: - Whole word vs substring

    /// Bare patterns match anywhere, including inside a longer word.
    func testSubstringPatternMatchesInsideAWord() {
        XCTAssertTrue(Self.matches(pattern: "invoice", in: "Invoice #1"))
        XCTAssertTrue(Self.matches(pattern: "invoice", in: "three invoices"))
    }

    /// A quoted pattern must not match "invoices" or "reinvoiced" — only the bounded word.
    func testQuotedPatternRequiresWholeWordBounds() {
        XCTAssertTrue(Self.matches(pattern: "\"invoice\"", in: "an invoice arrived"))
        XCTAssertFalse(Self.matches(pattern: "\"invoice\"", in: "three invoices"))
        XCTAssertFalse(Self.matches(pattern: "\"invoice\"", in: "reinvoiced"))
    }

    /// A quoted multi-word pattern matches only the exact phrase, not its words separately.
    func testQuotedPhraseMatchesAsOneUnit() {
        XCTAssertTrue(Self.matches(pattern: "\"deploy failed\"", in: "deploy failed on main"))
        XCTAssertFalse(Self.matches(pattern: "\"deploy failed\"", in: "deploy has failed"))
    }

    // MARK: - Diacritic folding

    /// German `ß` folds to `ss` and umlauts drop their diacritics, so an ASCII-typed
    /// pattern still finds the accented original.
    func testGermanEszettAndUmlautsFold() {
        XCTAssertTrue(Self.matches(pattern: "strasse", in: "Hauptstraße 5"))
        XCTAssertTrue(Self.matches(pattern: "bestatigung", in: "Bestätigung nötig"))
    }

    /// The reason `matchKey` folds with `locale: nil`: on a Turkish-locale Mac,
    /// `"INVOICE".lowercased(with: Locale(identifier: "tr"))` produces a dotless "ı",
    /// which would silently stop a rule for "invoice" from matching its own shouted form.
    /// Locale neutrality — not a Turkish special case — is what keeps this working for
    /// every user, including the ones a locale-sensitive fold would single out.
    func testTurkishTextFoldsLocaleNeutrally() {
        XCTAssertTrue(Self.matches(pattern: "invoice", in: "INVOICE ATTACHED"))

        let (compiled, _) = RulesEngine.compile([Self.rule(1, .vip, "ayse", field: .sender)])
        var notification = Self.notification()
        notification.sender = "Ayşe"

        let triage = RulesEngine.evaluate(notification, compiled: compiled)

        XCTAssertTrue(triage.pinned, "ayse must match Ayşe regardless of the process locale")
    }

    // MARK: - Field and app scope

    /// A `body`-scoped rule must not fire on a title hit, even though `evaluate` folds
    /// both into the same `MatchInput`.
    func testMatchFieldRestrictsWhichTextIsSearched() {
        let (compiled, _) = RulesEngine.compile([Self.rule(1, .highlight, "urgent", field: .body, color: "amber")])

        let triage = RulesEngine.evaluate(Self.notification(), compiled: compiled)

        XCTAssertTrue(triage.matchedRuleIDs.isEmpty, "the word is in the title, not the body")
    }

    /// A rule scoped to Slack must never touch a Mail notification, even when the
    /// pattern would otherwise match.
    func testAppScopedRuleNeverMatchesAnotherApp() {
        let (compiled, _) = RulesEngine.compile([
            Self.rule(1, .mute, "deploy", appBundleId: "com.tinyspeck.slackmacgap"),
        ])

        let triage = RulesEngine.evaluate(Self.notification(), compiled: compiled, bundleID: "com.apple.mail")

        XCTAssertTrue(triage.matchedRuleIDs.isEmpty)
        XCTAssertFalse(triage.muted)
    }

    /// A `nil` bundle id is fail-closed, not "matches everything": app-scoped rules and
    /// `match_field == .app` rules must not fire when the app cannot be resolved.
    func testNilBundleIDSkipsAppScopedRules() {
        let (compiled, _) = RulesEngine.compile([
            Self.rule(1, .mute, "com.tinyspeck.slackmacgap", field: .app),
            Self.rule(2, .mute, "urgent", appBundleId: "com.tinyspeck.slackmacgap"),
        ])

        let triage = RulesEngine.evaluate(Self.notification(), compiled: compiled, bundleID: nil)

        XCTAssertTrue(triage.matchedRuleIDs.isEmpty)
        XCTAssertFalse(triage.muted)
    }

    // MARK: - VIP vs mute

    /// VIP wins regardless of priority — a mute rule at priority 100 still loses to a
    /// VIP rule at priority 0. The asymmetric risk (a missed VIP message vs. mild noise)
    /// is what the doc's resolution rule is built around.
    func testVIPBeatsMuteEvenAtFarLowerPriority() {
        let (compiled, _) = RulesEngine.compile([
            Self.rule(1, .mute, "com.tinyspeck.slackmacgap", field: .app, priority: 100),
            Self.rule(2, .vip, "ayse", field: .sender, priority: 0),
        ])

        let triage = RulesEngine.evaluate(
            Self.notification(), compiled: compiled, bundleID: "com.tinyspeck.slackmacgap"
        )

        XCTAssertTrue(triage.pinned)
        XCTAssertFalse(triage.muted, "a VIP is never hidden by a mute, whatever its priority")
    }

    /// Per-app mute (`apps.is_muted`) applies exactly like a `mute` rule, including the
    /// VIP exemption — `appIsMuted` is how a caller with no matching rule at all still
    /// gets an app collapsed.
    func testPerAppMuteAppliesButIsExemptedByVIP() {
        let mutedOnly = RulesEngine.evaluate(Self.notification(), compiled: .empty, appIsMuted: true)
        XCTAssertTrue(mutedOnly.muted)

        let (compiled, _) = RulesEngine.compile([Self.rule(1, .vip, "ayse", field: .sender)])
        let vipExempt = RulesEngine.evaluate(Self.notification(), compiled: compiled, appIsMuted: true)

        XCTAssertTrue(vipExempt.pinned)
        XCTAssertFalse(vipExempt.muted, "per-app mute gets the same VIP exemption a mute rule gets")
    }

    // MARK: - Input truncation

    /// A pathological body must not turn matching into an unbounded scan: everything past
    /// `RuleLimits.maxInputLength` folded characters is invisible to every rule.
    func testBodyIsTruncatedBeforeMatching() {
        var notification = Self.notification()
        notification.body = String(repeating: "x", count: RuleLimits.maxInputLength) + "invoice"

        let (compiled, _) = RulesEngine.compile([Self.rule(1, .highlight, "invoice", field: .body, color: "amber")])

        let triage = RulesEngine.evaluate(notification, compiled: compiled)

        XCTAssertTrue(triage.matchedRuleIDs.isEmpty, "the needle falls entirely past the truncation point")
    }

    // MARK: Private

    /// Compiles one `mute` rule for `pattern` over `text` (as the notification's title)
    /// and reports whether it matched — the shared shape behind the whole-word,
    /// substring and phrase tests above.
    private static func matches(pattern: String, in text: String) -> Bool {
        let (compiled, _) = RulesEngine.compile([Self.rule(1, .mute, pattern)])
        var notification = Self.notification()
        notification.title = text

        return !RulesEngine.evaluate(notification, compiled: compiled).matchedRuleIDs.isEmpty
    }

    private static func rule(
        _ id: Int64,
        _ kind: Rule.Kind,
        _ pattern: String,
        field: Rule.MatchField = .any,
        appBundleId: String? = nil,
        color: String? = nil,
        priority: Int = 0,
        isEnabled: Bool = true
    ) -> Rule {
        Rule(
            id: id,
            kind: kind,
            pattern: pattern,
            matchField: field,
            appBundleId: appBundleId,
            color: color,
            priority: priority,
            isEnabled: isEnabled,
            createdAt: UnixDate(Date(timeIntervalSince1970: 1_755_400_000))
        )
    }

    private static func notification() -> ArchivedNotification {
        ArchivedNotification(
            uuid: "F1B0A2C3-0000-4000-8000-000000000003",
            appId: 1,
            title: "URGENT: deploy failed on main",
            sender: "Ayşe",
            deliveredAt: UnixDate(Date(timeIntervalSince1970: 1_755_400_000)),
            capturedAt: UnixDate(Date(timeIntervalSince1970: 1_755_400_001))
        )
    }
}
