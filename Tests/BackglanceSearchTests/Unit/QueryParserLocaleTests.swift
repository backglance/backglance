import BackglanceCore
@testable import BackglanceSearch
import Foundation
import XCTest

/// The Turkish locale rule, applied to the query grammar.
///
/// `QueryParser` lowercases the keys and the flag values it recognises, so `IS:UNREAD` and
/// `is:unread` are one query. That folding has to be locale-neutral, because every keyword
/// the grammar knows contains an `i` — `is`, `pinned`, `link`, `redacted`, `missed` — and
/// on a Turkish-locale Mac a locale-sensitive fold would turn a shouted `IS:PINNED` into
/// `ıs:pınned`, which the parser does not recognise. The query would silently stop being a
/// filter and become free text, so it would still return *results* — just the wrong ones,
/// with no error to notice.
///
/// `LocaleNeutralityTests` in `BackglanceCoreTests` covers the rule itself and the paths
/// `BackglanceCore` owns. This is the search half.
///
/// See docs/reference/INTERNATIONALIZATION.md#the-turkish-locale-rule.
final class QueryParserLocaleTests: XCTestCase {
    // MARK: Internal

    // MARK: - Keys and values fold neutrally

    /// Every `is:` value shouted. All five contain an `i` or an `I`, which is the whole
    /// point: this is not a sample, it is the complete set of words at risk.
    func testShoutedIsFlagsParseTheSameAsTypedOnes() throws {
        let expected: [String: ParsedQuery.Flag] = [
            "UNREAD": .unread, "READ": .read, "PINNED": .pinned, "MISSED": .missed, "VIP": .vip,
        ]

        for (value, flag) in expected {
            let parsed = try QueryParser.parse("IS:\(value)", now: now, calendar: calendar)
            XCTAssertEqual(parsed.flags, [flag], "IS:\(value)")
        }
    }

    func testShoutedHasFlagsParseTheSameAsTypedOnes() throws {
        let expected: [String: ParsedQuery.Flag] = ["LINK": .hasLink, "ATTACHMENT": .hasAttachment]

        for (value, flag) in expected {
            let parsed = try QueryParser.parse("HAS:\(value)", now: now, calendar: calendar)
            XCTAssertEqual(parsed.flags, [flag], "HAS:\(value)")
        }
    }

    func testShoutedRedactedYesParsesAsTheFlag() throws {
        let parsed = try QueryParser.parse("REDACTED:YES", now: now, calendar: calendar)

        XCTAssertEqual(parsed.flags, [.redacted])
    }

    /// `FROM:` and `APP:` are the two keys a user is most likely to shout, because they
    /// are followed by a name they are also shouting.
    func testShoutedFromKeyStillSetsTheAppFilter() throws {
        let parsed = try QueryParser.parse("FROM:slack", now: now, calendar: calendar)

        XCTAssertEqual(parsed.appNameContains, "slack")
        XCTAssertNil(parsed.ftsMatch, "a recognised key must not fall through to free text")
    }

    /// The *value* after `from:` is a name, not a keyword, so it is kept as typed and
    /// folded at the point of comparison instead. Asserted here so that a later change
    /// which starts lowercasing it has to be a deliberate one.
    func testTheAppNameAfterFromIsKeptAsTyped() throws {
        let parsed = try QueryParser.parse("from:İşbank", now: now, calendar: calendar)

        XCTAssertEqual(parsed.appNameContains, "İşbank")
    }

    // MARK: - What an unrecognised key does

    /// The reason the tests above matter. A key the parser does not recognise is not an
    /// error — it falls back to free text, which is the right behaviour for a search box
    /// and the reason a locale bug here would never announce itself.
    func testAnUnrecognisedKeyBecomesFreeTextRatherThanAnError() throws {
        let parsed = try QueryParser.parse("ıs:unread", now: now, calendar: calendar)

        XCTAssertTrue(parsed.flags.isEmpty)
        XCTAssertNotNil(parsed.ftsMatch, "the dotless spelling should have fallen through to free text")
    }

    // MARK: Private

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Istanbul") ?? .gmt
        cal.locale = Locale(identifier: "en_GB")
        return cal
    }()

    private var now: Date {
        Date(timeIntervalSince1970: 1_787_236_200)
    }
}
