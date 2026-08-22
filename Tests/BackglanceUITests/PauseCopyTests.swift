import BackglanceCore
@testable import BackglanceUI
import Foundation
import XCTest

/// The pause menu's words, and the one sentence the status item's tooltip has to get right:
/// a paused Backglance should say until when, or a user cannot tell a five-minute pause
/// from one they set last Tuesday and forgot.
final class PauseCopyTests: XCTestCase {
    // MARK: Internal

    func testTheMenuOffersTheFourChoicesShortestFirst() {
        XCTAssertEqual(PauseCopy.choices, [.fifteenMinutes, .oneHour, .untilTomorrow, .indefinitely])
    }

    func testEveryChoiceHasATitleAndNoTwoShareOne() {
        let titles = PauseChoice.allCases.map { PauseCopy.menuTitle(for: $0) }

        XCTAssertFalse(titles.contains(where: \.isEmpty))
        XCTAssertEqual(Set(titles).count, titles.count)
    }

    // MARK: - The tooltip

    func testAnIndefinitePauseNamesNoTime() {
        XCTAssertEqual(PauseCopy.pausedClause(until: nil), "capture paused")
    }

    func testAPauseEndingTodayIsNamedByItsTimeAlone() throws {
        let calendar = try Self.calendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2_026, month: 8, day: 22, hour: 9)))
        let until = try XCTUnwrap(calendar.date(from: DateComponents(year: 2_026, month: 8, day: 22, hour: 17)))

        let clause = PauseCopy.pausedClause(until: until, now: now, calendar: calendar)

        XCTAssertTrue(clause.hasPrefix("capture paused until "), clause)
        XCTAssertFalse(
            PauseCopy.namesTheDay(of: until, now: now, calendar: calendar),
            "a pause ending today does not need to say which day"
        )
    }

    /// "Until tomorrow" ends at midnight, and "paused until 00:00" with no date reads as a
    /// pause that has already run out.
    func testAPauseEndingOnAnotherDayCarriesItsDate() throws {
        let calendar = try Self.calendar()
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2_026, month: 8, day: 22, hour: 22)))
        let until = try XCTUnwrap(PauseChoice.untilTomorrow.deadline(from: now, calendar: calendar))

        let style = PauseCopy.deadlineStyle(for: until, now: now, calendar: calendar)
        let clause = PauseCopy.pausedClause(until: until, now: now, calendar: calendar)

        XCTAssertTrue(PauseCopy.namesTheDay(of: until, now: now, calendar: calendar))
        XCTAssertEqual(clause, "capture paused until \(until.formatted(style))")
    }

    // MARK: Private

    private static func calendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Istanbul"))
        return calendar
    }
}
