import BackglanceCore
import BackglanceTestSupport
@testable import BackglanceUI
import Foundation
import XCTest

@MainActor
final class TimelineGroupingTests: XCTestCase {
    // MARK: Internal

    // MARK: - The unread divider

    /// The divider marks the boundary the user cares about: everything above it
    /// arrived while they were away.
    func testDividerLandsAtTheFirstRowOlderThanTheAnchor() {
        let anchor = UnixDate(Stubs.epoch)
        let items = TimelineFixtures.items(around: anchor, newer: 3, older: 2)

        let slots = sections(items, anchor: anchor).flatMap(\.slots)

        XCTAssertEqual(slots.firstIndex(of: .divider), 3, "three new rows belong above the divider")
        XCTAssertEqual(slots.filter { $0 == .divider }.count, 1, "never more than one divider")
    }

    /// A divider under everything would say "nothing is new", which the absence
    /// of a divider already says — with less ink.
    func testNoDividerWhenNothingIsNew() {
        let anchor = UnixDate(Stubs.epoch)
        let items = TimelineFixtures.items(around: anchor, newer: 0, older: 5)

        XCTAssertFalse(sections(items, anchor: anchor).flatMap(\.slots).contains(.divider))
    }

    /// A divider at the very top is noise for the same reason.
    func testNoDividerWhenEverythingIsNew() {
        let anchor = UnixDate(Stubs.epoch)
        let items = TimelineFixtures.items(around: anchor, newer: 4, older: 0)

        XCTAssertFalse(sections(items, anchor: anchor).flatMap(\.slots).contains(.divider))
    }

    // MARK: - Day bucketing

    /// Two notifications ten minutes apart can still belong to different days.
    /// The boundary is the user's midnight, not UTC's.
    func testRowsSplitAcrossMidnightInTheUsersTimeZone() {
        let calendar = TimelineFixtures.istanbul
        // 2026-01-01 00:05 Istanbul, and 23:55 the evening before.
        let justAfterMidnight = Date(timeIntervalSince1970: 1_767_215_100)
        let items = [
            TimelineFixtures.item(id: 1, secondsAgo: 0, reference: justAfterMidnight),
            TimelineFixtures.item(id: 2, secondsAgo: 600, reference: justAfterMidnight),
        ]

        let built = TimelineStore.buildSections(
            items: items,
            groupByApp: false,
            anchor: UnixDate(.distantPast),
            calendar: calendar,
            now: justAfterMidnight
        )

        XCTAssertEqual(built.count, 2, "midnight ends a day even when the rows are ten minutes apart")
        XCTAssertEqual(built.first?.items.map(\.id), [1])
        XCTAssertEqual(built.last?.items.map(\.id), [2])
    }

    func testDaysComeBackNewestFirst() {
        let items = [
            TimelineFixtures.item(id: 1, secondsAgo: 0),
            TimelineFixtures.item(id: 2, secondsAgo: 60 * 60 * 24),
            TimelineFixtures.item(id: 3, secondsAgo: 60 * 60 * 24 * 3),
        ]

        let built = sections(items)

        XCTAssertEqual(built.map { $0.items.map(\.id) }, [[1], [2], [3]])
    }

    // MARK: - Pinning

    /// Pinned rows float within their own day, not to the top of the timeline —
    /// a pin is emphasis, not a change of date.
    func testPinnedRowsFloatToTheTopOfTheirOwnDay() {
        let items = [
            TimelineFixtures.item(id: 1, secondsAgo: 0),
            TimelineFixtures.item(id: 2, secondsAgo: 120, isPinned: true),
            TimelineFixtures.item(id: 3, secondsAgo: 60 * 60 * 24, isPinned: true),
            TimelineFixtures.item(id: 4, secondsAgo: 60 * 60 * 24 + 120),
        ]

        let built = sections(items)

        XCTAssertEqual(built.first?.items.map(\.id), [2, 1])
        XCTAssertEqual(built.last?.items.map(\.id), [3, 4])
    }

    /// A VIP rule pins exactly like the manual toggle does — one code path.
    func testVIPTriagePinsLikeTheManualToggle() {
        let items = [
            TimelineFixtures.item(id: 1, secondsAgo: 0),
            TimelineFixtures.item(id: 2, secondsAgo: 120, triage: Triage(pinned: true)),
        ]

        XCTAssertEqual(sections(items).first?.items.map(\.id), [2, 1])
    }

    /// docs/features/ACTIONS.md#pin-unpin-read-unread: "the manual pin wins ties" —
    /// a manual pin sorts before a VIP-triage pin within the same day even when the
    /// VIP row is the newer of the two, which a plain newest-first sort would get
    /// backwards.
    func testAManualPinSortsBeforeAVIPPinEvenWhenTheVIPRowIsNewer() {
        let items = [
            TimelineFixtures.item(id: 1, secondsAgo: 120, isPinned: true),
            TimelineFixtures.item(id: 2, secondsAgo: 0, triage: Triage(pinned: true)),
        ]

        XCTAssertEqual(sections(items).first?.items.map(\.id), [1, 2])
    }

    /// Within the manual-pin bucket, two manual pins still sort newest-first —
    /// the tiebreaker docs/features/ACTIONS.md names after "manual before VIP".
    func testTwoManualPinsStayNewestFirst() {
        let items = [
            TimelineFixtures.item(id: 1, secondsAgo: 120, isPinned: true),
            TimelineFixtures.item(id: 2, secondsAgo: 0, isPinned: true),
        ]

        XCTAssertEqual(sections(items).first?.items.map(\.id), [2, 1])
    }

    // MARK: - Muting

    /// Muted rows collapse into one trailing header per day. They stay in the
    /// archive and in search — this is presentation, not deletion.
    func testMutedRowsCollapseIntoATrailingGroup() {
        let items = [
            TimelineFixtures.item(id: 1, secondsAgo: 0),
            TimelineFixtures.item(id: 2, secondsAgo: 60, triage: Triage(muted: true)),
            TimelineFixtures.item(id: 3, secondsAgo: 120, triage: Triage(muted: true)),
        ]

        let day = sections(items).first

        XCTAssertEqual(day?.items.map(\.id), [1], "muted rows are not drawn until the group is expanded")
        XCTAssertEqual(day?.mutedCount, 2)
        guard case let .appHeader(group)? = day?.slots.last else {
            return XCTFail("expected a trailing muted header")
        }
        XCTAssertTrue(group.isMuted)
        XCTAssertEqual(group.count, 2)
        XCTAssertEqual(group.name, "Muted", "the count belongs to the header's own formatting, not to the name")
    }

    /// VIP beats mute unconditionally, so a pinned row must not disappear into
    /// the muted group.
    func testAPinnedRowIsNeverCollapsedAsMuted() {
        let items = [
            TimelineFixtures.item(id: 1, secondsAgo: 0, isPinned: true, triage: Triage(muted: true)),
        ]

        let day = sections(items).first

        XCTAssertEqual(day?.items.map(\.id), [1])
        XCTAssertEqual(day?.mutedCount, 0)
    }

    // MARK: - Grouping by app

    func testByAppGroupingEmitsOneHeaderPerAppInNameOrder() {
        let items = [
            TimelineFixtures.item(id: 1, secondsAgo: 0, appName: "Slack", bundleID: Stubs.BundleID.slack),
            TimelineFixtures.item(id: 2, secondsAgo: 60, appName: "Mail", bundleID: Stubs.BundleID.mail),
            TimelineFixtures.item(id: 3, secondsAgo: 120, appName: "Slack", bundleID: Stubs.BundleID.slack),
        ]

        let slots = sections(items, groupByApp: true).flatMap(\.slots)
        let headers = slots.compactMap { slot -> TimelineSection.AppGroup? in
            if case let .appHeader(group) = slot {
                group
            } else {
                nil
            }
        }

        XCTAssertEqual(headers.map(\.name), ["Mail", "Slack"])
        XCTAssertEqual(headers.map(\.count), [1, 2])
    }

    func testFlatGroupingEmitsNoAppHeaders() {
        let items = [TimelineFixtures.item(id: 1, secondsAgo: 0)]

        let slots = sections(items).flatMap(\.slots)

        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots.first, .row(items[0]))
    }

    func testNoItemsMeansNoSections() {
        XCTAssertTrue(sections([]).isEmpty)
    }

    // MARK: Private

    private func sections(
        _ items: [TimelineItem],
        groupByApp: Bool = false,
        anchor: UnixDate = UnixDate(.distantPast)
    ) -> [TimelineSection.Model] {
        TimelineStore.buildSections(
            items: items,
            groupByApp: groupByApp,
            anchor: anchor,
            calendar: TimelineFixtures.istanbul,
            now: Stubs.epoch
        )
    }
}
