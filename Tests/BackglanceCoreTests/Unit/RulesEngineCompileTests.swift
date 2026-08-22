@testable import BackglanceCore
import Foundation
import XCTest

/// Covers `RulesEngine.compile(_:)` (`RulesEngine+Compile.swift`): validation, the
/// skip-and-report-not-throw contract, and the `priority DESC, id ASC` sort that
/// `evaluate(_:compiled:bundleID:)` depends on. Matching semantics and evaluation order
/// themselves are covered in `RulesEngineEvaluateTests`. See
/// docs/features/RULES.md#business-logic-rulesengine.
final class RulesEngineCompileTests: XCTestCase {
    // MARK: Internal

    // MARK: - Disabled rules

    /// A disabled rule must not compile to an entry and must not be reported as a
    /// problem either — it is neither working nor broken, it is off.
    func testDisabledRuleIsSkippedSilently() {
        let (compiled, problems) = RulesEngine.compile([
            Self.rule(1, .highlight, "urgent", color: "amber", isEnabled: false),
        ])

        XCTAssertTrue(compiled.isEmpty)
        XCTAssertTrue(problems.isEmpty)
    }

    // MARK: - Empty / over-long pattern

    /// A blank pattern — e.g. from a hand-edited import — is reported, not thrown, and
    /// must not stop the rule after it from compiling.
    func testEmptyPatternIsReportedAndRestStillCompiles() {
        let (compiled, problems) = RulesEngine.compile([
            Self.rule(1, .highlight, "   ", color: "amber"),
            Self.rule(2, .mute, "slack"),
        ])

        XCTAssertEqual(compiled.entries.map(\.id), [2])
        XCTAssertEqual(problems.map(\.kind), [.emptyPattern])
        XCTAssertEqual(problems.first?.ruleID, 1)
    }

    /// 256 characters is the documented ceiling (docs/security/SECURITY.md); one over it
    /// is reported, and a sibling rule still compiles.
    func testOverLongPatternIsReportedAndRestStillCompiles() {
        let tooLong = String(repeating: "a", count: RuleLimits.maxPatternLength + 1)
        let (compiled, problems) = RulesEngine.compile([
            Self.rule(1, .mute, tooLong),
            Self.rule(2, .mute, "slack"),
        ])

        XCTAssertEqual(compiled.entries.map(\.id), [2])
        XCTAssertEqual(problems.map(\.kind), [.patternTooLong])
        XCTAssertEqual(problems.first?.ruleID, 1)
    }

    // MARK: - Highlight colour

    /// `highlight` without a `color` has nothing to paint with — reported, never
    /// defaulted to some arbitrary colour.
    func testHighlightRuleWithNoColorIsReported() {
        let (compiled, problems) = RulesEngine.compile([Self.rule(1, .highlight, "urgent", color: nil)])

        XCTAssertTrue(compiled.isEmpty)
        XCTAssertEqual(problems.map(\.kind), [.unknownColorToken])
    }

    /// A colour token that is not one of `HighlightColor`'s five cases — a typo, or a
    /// token from a future version — is reported the same way as a missing one.
    func testHighlightRuleWithUnknownColorTokenIsReported() {
        let (compiled, problems) = RulesEngine.compile([Self.rule(1, .highlight, "urgent", color: "chartreuse")])

        XCTAssertTrue(compiled.isEmpty)
        XCTAssertEqual(problems.map(\.kind), [.unknownColorToken])
    }

    // MARK: - Regex (v1.x)

    /// `kind = .regex` is planned for v1.x; in v1.0 it must be reported, never thrown,
    /// and must never disable the rules around it.
    func testRegexRuleIsReportedNotAvailableAndDoesNotBlockOtherRules() {
        let (compiled, problems) = RulesEngine.compile([
            Self.rule(1, .regex, "(a+)+$", color: "amber"),
            Self.rule(2, .mute, "slack"),
        ])

        XCTAssertEqual(compiled.entries.map(\.id), [2])
        XCTAssertEqual(problems.map(\.kind), [.notAvailableInThisVersion])
    }

    // MARK: - Matcher shape

    /// A pattern wrapped in double quotes compiles to a whole-word matcher with the
    /// quotes stripped; a bare pattern compiles to substring; `match_field == .app`
    /// compiles to a bundle-id matcher regardless of quoting.
    func testPatternShapeSelectsTheMatcher() {
        let (compiled, problems) = RulesEngine.compile([
            Self.rule(1, .mute, "\"invoice\""),
            Self.rule(2, .mute, "invoice"),
            Self.rule(3, .mute, "com.tinyspeck.SlackMacGap", field: .app),
        ])
        XCTAssertTrue(problems.isEmpty)
        let byID = Dictionary(uniqueKeysWithValues: compiled.entries.map { ($0.id, $0) })

        guard case let .word(needle) = byID[1]?.matcher else {
            return XCTFail("expected .word")
        }
        XCTAssertEqual(needle, "invoice")

        guard case let .substring(needle) = byID[2]?.matcher else {
            return XCTFail("expected .substring")
        }
        XCTAssertEqual(needle, "invoice")

        guard case let .bundleID(bundleID) = byID[3]?.matcher else {
            return XCTFail("expected .bundleID")
        }
        XCTAssertEqual(
            bundleID,
            "com.tinyspeck.slackmacgap",
            "app-field patterns lowercase plainly, never fold through matchKey"
        )
    }

    // MARK: - Sort order

    /// `evaluate` depends on `entries` already being in `priority DESC, id ASC` order —
    /// this is the one place that invariant is established.
    func testEntriesSortByPriorityDescendingThenIdAscending() {
        let (compiled, problems) = RulesEngine.compile([
            Self.rule(3, .mute, "a", priority: 0),
            Self.rule(1, .mute, "b", priority: 5),
            Self.rule(2, .mute, "c", priority: 5),
            Self.rule(4, .mute, "d", priority: 10),
        ])

        XCTAssertTrue(problems.isEmpty)
        XCTAssertEqual(compiled.entries.map(\.id), [4, 1, 2, 3])
    }

    // MARK: Private

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
}
