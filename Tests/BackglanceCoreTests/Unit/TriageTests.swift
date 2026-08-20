@testable import BackglanceCore
import Foundation
import XCTest

final class TriageTests: XCTestCase {
    // MARK: Internal

    // MARK: - Triage

    func testNoneIsEntirelyNeutral() {
        let triage = Triage.none

        XCTAssertNil(triage.highlight)
        XCTAssertFalse(triage.pinned)
        XCTAssertFalse(triage.muted)
        XCTAssertTrue(triage.matchedRuleIDs.isEmpty)
    }

    func testMemberwiseInitCarriesEveryField() {
        let triage = Triage(highlight: .amber, pinned: true, muted: true, matchedRuleIDs: [1, 3, 2])

        XCTAssertEqual(triage.highlight, .amber)
        XCTAssertTrue(triage.pinned)
        XCTAssertTrue(triage.muted)
        XCTAssertEqual(triage.matchedRuleIDs, [1, 3, 2], "matched ids stay in compiled order, not sorted")
    }

    /// The timeline caches triage per row, so two evaluations that agree have to
    /// compare equal — otherwise a cache hit would still redraw the row.
    func testEqualityComparesEveryField() {
        let base = Triage(highlight: .red, pinned: true, muted: false, matchedRuleIDs: [7])

        XCTAssertEqual(base, Triage(highlight: .red, pinned: true, muted: false, matchedRuleIDs: [7]))
        XCTAssertNotEqual(base, Triage(highlight: .blue, pinned: true, muted: false, matchedRuleIDs: [7]))
        XCTAssertNotEqual(base, Triage(highlight: .red, pinned: false, muted: false, matchedRuleIDs: [7]))
        XCTAssertNotEqual(base, Triage(highlight: .red, pinned: true, muted: true, matchedRuleIDs: [7]))
        XCTAssertNotEqual(base, Triage(highlight: .red, pinned: true, muted: false, matchedRuleIDs: [7, 8]))
    }

    // MARK: - HighlightColor

    /// The raw values are stored in `rules.color` and travel in exported rules
    /// files, so renaming one is an archive-format change, not a refactor.
    func testTokensAreTheFiveDocumentedNames() {
        XCTAssertEqual(HighlightColor.allCases.map(\.rawValue), ["amber", "red", "green", "blue", "purple"])
    }

    func testUnknownTokenDoesNotDecode() {
        XCTAssertNil(HighlightColor(rawValue: "chartreuse"))
    }

    // MARK: - NoTriage

    func testNoTriageReturnsNoneForEveryRow() {
        let evaluator = NoTriage()
        var notification = Self.notification()
        notification.isPinned = true

        XCTAssertEqual(
            evaluator.evaluate(notification),
            .none,
            "manual pin is the timeline's business, not the evaluator's"
        )
    }

    // MARK: Private

    private static func notification() -> ArchivedNotification {
        ArchivedNotification(
            uuid: "F1B0A2C3-0000-4000-8000-000000000001",
            appId: 1,
            title: "Fixture title",
            deliveredAt: UnixDate(Date(timeIntervalSince1970: 1_755_400_000)),
            capturedAt: UnixDate(Date(timeIntervalSince1970: 1_755_400_001))
        )
    }
}
