@testable import BackglanceSearch
import Foundation
import XCTest

/// Covers `QueryParser`'s grammar token by token, plus the combined example
/// from docs/features/SEARCH.md#queryparser-grammar. Every date test runs
/// against a frozen `now` and a pinned calendar (Europe/Istanbul, en_GB) so
/// none of it depends on when the suite runs. All text here is synthetic.
final class QueryParserTests: XCTestCase {
    // MARK: Internal

    // MARK: - Structured filters

    func testFromKeywordWithDisplayNameSetsAppNameContains() throws {
        let parsed = try QueryParser.parse("from:slack", now: now, calendar: calendar)
        XCTAssertEqual(parsed.appNameContains, "slack")
        XCTAssertTrue(parsed.bundleIDs.isEmpty)
    }

    func testFromKeywordWithBundleIDShapeSetsBundleIDs() throws {
        let parsed = try QueryParser.parse("from:com.tinyspeck.slackmacgap", now: now, calendar: calendar)
        XCTAssertEqual(parsed.bundleIDs, ["com.tinyspeck.slackmacgap"])
        XCTAssertNil(parsed.appNameContains)
    }

    func testAppKeywordIsAnAliasForFrom() throws {
        let parsed = try QueryParser.parse("app:com.example.Notes", now: now, calendar: calendar)
        XCTAssertEqual(parsed.bundleIDs, ["com.example.Notes"])
    }

    func testSenderKeywordIsStructuredNotFTS() throws {
        let parsed = try QueryParser.parse("sender:Ayşe", now: now, calendar: calendar)
        XCTAssertEqual(parsed.sender, "Ayşe")
        XCTAssertNil(parsed.ftsMatch)
    }

    func testSenderKeywordWithQuotedValue() throws {
        let parsed = try QueryParser.parse("sender:\"Ayşe Yılmaz\"", now: now, calendar: calendar)
        XCTAssertEqual(parsed.sender, "Ayşe Yılmaz")
    }

    func testThreadKeyword() throws {
        let parsed = try QueryParser.parse("thread:abc123", now: now, calendar: calendar)
        XCTAssertEqual(parsed.threadID, "abc123")
    }

    // MARK: - is: / has: / redacted:

    func testIsFlags() throws {
        let expected: [String: ParsedQuery.Flag] = [
            "unread": .unread, "read": .read, "pinned": .pinned, "missed": .missed, "vip": .vip,
        ]
        for (value, flag) in expected {
            let parsed = try QueryParser.parse("is:\(value)", now: now, calendar: calendar)
            XCTAssertEqual(parsed.flags, [flag], "is:\(value)")
        }
    }

    func testHasFlags() throws {
        let expected: [String: ParsedQuery.Flag] = ["link": .hasLink, "attachment": .hasAttachment]
        for (value, flag) in expected {
            let parsed = try QueryParser.parse("has:\(value)", now: now, calendar: calendar)
            XCTAssertEqual(parsed.flags, [flag], "has:\(value)")
        }
    }

    func testRedactedYes() throws {
        let parsed = try QueryParser.parse("redacted:yes", now: now, calendar: calendar)
        XCTAssertEqual(parsed.flags, [.redacted])
    }

    func testRedactedNoFallsBackToFreeText() throws {
        let parsed = try QueryParser.parse("redacted:no", now: now, calendar: calendar)
        XCTAssertTrue(parsed.flags.isEmpty)
        XCTAssertEqual(parsed.terms, ["redacted:no"])
    }

    func testUnknownIsValueFallsBackToFreeText() throws {
        let parsed = try QueryParser.parse("is:archived", now: now, calendar: calendar)
        XCTAssertTrue(parsed.flags.isEmpty)
        XCTAssertEqual(parsed.terms, ["is:archived"])
    }

    func testUnknownHasValueFallsBackToFreeText() throws {
        let parsed = try QueryParser.parse("has:reminder", now: now, calendar: calendar)
        XCTAssertTrue(parsed.flags.isEmpty)
        XCTAssertEqual(parsed.terms, ["has:reminder"])
    }

    func testUnknownKeyFallsBackToFreeText() throws {
        let parsed = try QueryParser.parse("re:invoice", now: now, calendar: calendar)
        XCTAssertEqual(parsed.terms, ["re:invoice"])
        XCTAssertEqual(parsed.ftsMatch, "(\"re:invoice\"*)")
    }

    // MARK: - Dates

    func testBeforeAbsoluteDate() throws {
        let parsed = try QueryParser.parse("before:2026-08-01", now: now, calendar: calendar)
        XCTAssertEqual(parsed.before, dayStart(year: 2_026, month: 8, day: 1))
        XCTAssertNil(parsed.after)
    }

    func testAfterAbsoluteDate() throws {
        let parsed = try QueryParser.parse("after:2026-08-01", now: now, calendar: calendar)
        XCTAssertEqual(parsed.after, dayStart(year: 2_026, month: 8, day: 1))
    }

    func testAfterToday() throws {
        let parsed = try QueryParser.parse("after:today", now: now, calendar: calendar)
        XCTAssertEqual(parsed.after, dayStart(year: 2_026, month: 8, day: 20))
    }

    func testAfterYesterday() throws {
        let parsed = try QueryParser.parse("after:yesterday", now: now, calendar: calendar)
        XCTAssertEqual(parsed.after, dayStart(year: 2_026, month: 8, day: 19))
    }

    func testAfterRelativeDaysSnapsToStartOfDay() throws {
        let parsed = try QueryParser.parse("after:-7d", now: now, calendar: calendar)
        XCTAssertEqual(parsed.after, dayStart(year: 2_026, month: 8, day: 13))
    }

    func testAfterRelativeWeeksSnapsToStartOfDay() throws {
        let parsed = try QueryParser.parse("after:-2w", now: now, calendar: calendar)
        XCTAssertEqual(parsed.after, dayStart(year: 2_026, month: 8, day: 6))
    }

    func testAfterRelativeHoursIsExactNotSnapped() throws {
        let parsed = try QueryParser.parse("after:-36h", now: now, calendar: calendar)
        let expected = calendar.date(byAdding: .hour, value: -36, to: now)
        XCTAssertEqual(parsed.after, expected)
        XCTAssertNotEqual(parsed.after, dayStart(year: 2_026, month: 8, day: 19))
    }

    func testOnKeywordProducesBothBounds() throws {
        let parsed = try QueryParser.parse("on:2026-08-15", now: now, calendar: calendar)
        XCTAssertEqual(parsed.after, dayStart(year: 2_026, month: 8, day: 15))
        XCTAssertEqual(parsed.before, dayStart(year: 2_026, month: 8, day: 16))
    }

    func testInvalidDateThrowsWithoutEchoingTheQuery() {
        XCTAssertThrowsError(try QueryParser.parse("before:whenever soon", now: now, calendar: calendar)) { error in
            guard case let SearchError.invalidQuery(reason) = error else {
                return XCTFail("expected .invalidQuery, got \(error)")
            }
            XCTAssertFalse(reason.contains("whenever"))
            XCTAssertFalse(reason.contains("soon"))
            XCTAssertTrue(reason.hasPrefix("before:"))
        }
    }

    // MARK: - Free text, phrases, negation

    func testBareWordIsFreeTextWithPrefixStar() throws {
        let parsed = try QueryParser.parse("invoice", now: now, calendar: calendar)
        XCTAssertEqual(parsed.terms, ["invoice"])
        XCTAssertEqual(parsed.ftsMatch, "(\"invoice\"*)")
    }

    func testPrefixStarOnlyOnLastFreeTerm() throws {
        let parsed = try QueryParser.parse("invoice over", now: now, calendar: calendar)
        XCTAssertEqual(parsed.terms, ["invoice", "over"])
        XCTAssertEqual(parsed.ftsMatch, "(\"invoice\" \"over\"*)")
    }

    func testQuotedPhraseNeverGetsThePrefixStar() throws {
        let parsed = try QueryParser.parse("\"flight confirmation\" invoice", now: now, calendar: calendar)
        XCTAssertEqual(parsed.ftsMatch, "(\"flight confirmation\" \"invoice\"*)")
    }

    func testQuoteEscapingDoublesInternalQuotesBothWays() throws {
        let parsed = try QueryParser.parse("\"say \"\"hi\"\" now\"", now: now, calendar: calendar)
        XCTAssertEqual(parsed.terms, ["say \"hi\" now"])
        XCTAssertEqual(parsed.ftsMatch, "(\"say \"\"hi\"\" now\")")
    }

    func testUnbalancedQuoteRunsToTheEndOfTheText() throws {
        let parsed = try QueryParser.parse("foo \"bar baz", now: now, calendar: calendar)
        XCTAssertEqual(parsed.terms, ["foo", "bar baz"])
        XCTAssertEqual(parsed.ftsMatch, "(\"foo\"* \"bar baz\")")
    }

    func testNegatedWordBecomesNotClause() throws {
        let parsed = try QueryParser.parse("invoice -draft", now: now, calendar: calendar)
        XCTAssertEqual(parsed.ftsMatch, "(\"invoice\"*) NOT \"draft\"")
    }

    func testNegatedPhraseBecomesNotClause() throws {
        let parsed = try QueryParser.parse("invoice -\"junk mail\"", now: now, calendar: calendar)
        XCTAssertEqual(parsed.ftsMatch, "(\"invoice\"*) NOT \"junk mail\"")
    }

    func testNegationOnlyQueryHasNoPositiveBlock() throws {
        let parsed = try QueryParser.parse("-draft", now: now, calendar: calendar)
        XCTAssertEqual(parsed.ftsMatch, "\"draft\"")
        XCTAssertTrue(parsed.terms.isEmpty)
    }

    func testLoneHyphenProducesNoToken() throws {
        let parsed = try QueryParser.parse("- invoice", now: now, calendar: calendar)
        XCTAssertEqual(parsed.terms, ["invoice"])
    }

    func testFiltersOnlyQueryHasNoFTSMatch() throws {
        let parsed = try QueryParser.parse("from:slack is:pinned", now: now, calendar: calendar)
        XCTAssertNil(parsed.ftsMatch)
        XCTAssertTrue(parsed.terms.isEmpty)
    }

    func testEmptyQueryProducesAnEmptyParsedQuery() throws {
        let parsed = try QueryParser.parse("   ", now: now, calendar: calendar)
        XCTAssertEqual(parsed, ParsedQuery())
    }

    // MARK: - The combined example from SEARCH.md

    func testCombinedExampleFromSearchDoc() throws {
        let parsed = try QueryParser.parse(
            "from:slack sender:\"Ayşe\" after:-7d is:missed -draft invoice over",
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(parsed.appNameContains, "slack")
        XCTAssertTrue(parsed.bundleIDs.isEmpty)
        XCTAssertEqual(parsed.sender, "Ayşe")
        XCTAssertEqual(parsed.after, dayStart(year: 2_026, month: 8, day: 13))
        XCTAssertEqual(parsed.flags, [.missed])
        XCTAssertEqual(parsed.terms, ["invoice", "over"])
        XCTAssertEqual(parsed.ftsMatch, "(\"invoice\" \"over\"*) NOT \"draft\"")
    }

    // MARK: Private

    /// UTC+3 year-round, no DST, so arithmetic across the test file is
    /// unambiguous. `en_GB` pins the calendar's first-weekday assumptions
    /// away from the test runner's own locale.
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Istanbul") ?? .gmt
        cal.locale = Locale(identifier: "en_GB")
        return cal
    }()

    /// 2026-08-20 15:30 local. Picked mid-afternoon, mid-month, so relative
    /// offsets (`-7d`, `-2w`, `-36h`) land on distinct, easily checked days.
    private var now: Date {
        dayStart(year: 2_026, month: 8, day: 20).addingTimeInterval(15.5 * 3_600)
    }

    private func dayStart(year: Int, month: Int, day: Int) -> Date {
        let components = DateComponents(year: year, month: month, day: day)
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }
}
