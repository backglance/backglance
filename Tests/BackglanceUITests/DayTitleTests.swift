@testable import BackglanceUI
import Foundation
import XCTest

final class DayTitleTests: XCTestCase {
    // MARK: Internal

    // MARK: - Thresholds

    func testTodayAndYesterdayAreNamedRatherThanDated() {
        XCTAssertEqual(title(daysAgo: 0), "Today")
        XCTAssertEqual(title(daysAgo: 1), "Yesterday")
    }

    /// Within the last week the weekday is the fastest thing to read: "Monday"
    /// answers "when was this" without any arithmetic.
    func testDaysWithinTheLastWeekReadAsAWeekday() {
        let title = title(daysAgo: 3)

        XCTAssertTrue(title.contains("Monday"), title)
        XCTAssertTrue(title.contains("Dec"), title)
        XCTAssertFalse(title.contains("2025"), "a weekday header does not need the year: \(title)")
    }

    /// Six days back is still inside the window; seven would print the same
    /// weekday as today, which reads as the *coming* Monday rather than the past one.
    func testTheWeekdayWindowEndsAtSixDays() {
        XCTAssertTrue(title(daysAgo: 6).contains("Friday"), title(daysAgo: 6))
        XCTAssertEqual(title(daysAgo: 7), "25 December 2025")
    }

    func testOlderDaysGetTheFullDate() {
        XCTAssertEqual(title(daysAgo: 40), "22 November 2025")
    }

    // MARK: - Locale and time zone

    /// The header is formatted in the user's locale, not in the developer's.
    func testTheCalendarsLocaleDecidesTheFormat() {
        var calendar = TimelineFixtures.istanbul
        calendar.locale = Locale(identifier: "de_DE")
        let day = calendar.startOfDay(for: Self.now.addingTimeInterval(-40 * 86_400))

        let german = DayTitle.string(for: day, calendar: calendar, now: Self.now)

        XCTAssertTrue(german.contains("November"), german)
        XCTAssertFalse(german.contains(","), "German writes the date without the English comma: \(german)")
    }

    /// "Today" is decided by the user's midnight. The same instant is today in
    /// Istanbul and still yesterday in London.
    func testTodayIsRelativeToTheCalendarsTimeZone() {
        // 2026-01-01 00:30 Istanbul == 2025-12-31 21:30 UTC.
        let justAfterIstanbulMidnight = Date(timeIntervalSince1970: 1_767_216_600)
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London") ?? .gmt
        london.locale = Locale(identifier: "en_GB")

        let istanbulTitle = DayTitle.string(
            for: TimelineFixtures.istanbul.startOfDay(for: justAfterIstanbulMidnight),
            calendar: TimelineFixtures.istanbul,
            now: justAfterIstanbulMidnight
        )
        let londonTitle = DayTitle.string(
            for: london.startOfDay(for: justAfterIstanbulMidnight),
            calendar: london,
            now: justAfterIstanbulMidnight
        )

        XCTAssertEqual(istanbulTitle, "Today")
        XCTAssertEqual(londonTitle, "Today", "each calendar names its own day; only the date underneath differs")
        XCTAssertNotEqual(
            TimelineFixtures.istanbul.startOfDay(for: justAfterIstanbulMidnight),
            london.startOfDay(for: justAfterIstanbulMidnight)
        )
    }

    // MARK: Private

    /// Thursday, 1 January 2026, 12:00 Istanbul — frozen so the weekday
    /// assertions above mean something.
    private static let now = Date(timeIntervalSince1970: 1_767_258_000)

    private func title(daysAgo days: Int) -> String {
        let calendar = TimelineFixtures.istanbul
        let day = calendar.startOfDay(for: Self.now.addingTimeInterval(-Double(days) * 86_400))
        return DayTitle.string(for: day, calendar: calendar, now: Self.now)
    }
}
