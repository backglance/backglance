@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

final class TimelinePaginationTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - Page joins

    /// The whole point of keyset pagination: walking every page of a large archive
    /// returns each row exactly once, in one continuous order, with no row falling
    /// into the seam between two pages.
    func testPagesJoinWithoutGapsOrDuplicates() throws {
        let archive = try XCTUnwrap(archive)
        let expected = try TimelineSeed.fill(archive, count: 10_000)

        let walked = try walkAllPages(of: archive)

        XCTAssertEqual(walked.count, 10_000)
        XCTAssertEqual(Set(walked).count, 10_000, "no row may appear on two pages")
        XCTAssertEqual(walked, expected, "pages joined out of timeline order")
    }

    func testPageSizeIsTwoHundredByDefault() throws {
        let archive = try XCTUnwrap(archive)
        try TimelineSeed.fill(archive, count: 250)

        XCTAssertEqual(Archive.timelinePageSize, 200)
        XCTAssertEqual(try archive.timelinePage().count, 200)
    }

    /// A burst — many notifications sharing one `delivered_at` — is exactly where
    /// an `OFFSET` or a date-only cursor loses rows. The page boundary is forced
    /// into the middle of the burst here (200 of 500 shared-timestamp rows).
    func testBurstSharingOneTimestampSplitsAcrossPagesByID() throws {
        let archive = try XCTUnwrap(archive)
        let expected = try TimelineSeed.fill(archive, count: 600, burst: 500)

        let walked = try walkAllPages(of: archive)

        XCTAssertEqual(walked, expected)
        let firstPage = try archive.timelinePage()
        let secondPage = try archive.timelinePage(after: XCTUnwrap(TimelineCursor(row: XCTUnwrap(firstPage.last))))
        XCTAssertTrue(
            Set(firstPage.compactMap(\.id)).isDisjoint(with: Set(secondPage.compactMap(\.id))),
            "the id tiebreaker has to separate rows that share a second"
        )
    }

    /// The store stops paginating on a short page, so "no more rows" must be an
    /// empty page rather than the last page repeating forever.
    func testPastTheOldestRowThePageIsEmpty() throws {
        let archive = try XCTUnwrap(archive)
        let expected = try TimelineSeed.fill(archive, count: 10)

        let all = try archive.timelinePage(limit: 50)
        XCTAssertEqual(all.compactMap(\.id), expected)

        let cursor = try XCTUnwrap(TimelineCursor(row: XCTUnwrap(all.last)))
        XCTAssertTrue(try archive.timelinePage(after: cursor).isEmpty)
    }

    func testEmptyArchivePagesAsEmpty() throws {
        let archive = try XCTUnwrap(archive)

        XCTAssertTrue(try archive.timelinePage().isEmpty)
    }

    // MARK: - Filtering

    /// Filtering soft-deleted rows belongs to the query, not to every caller: a
    /// deleted row that reappeared on one page would look like a resurrection bug.
    func testSoftDeletedRowsNeverAppearOnAPage() throws {
        let archive = try XCTUnwrap(archive)
        let expected = try TimelineSeed.fill(archive, count: 300, deleted: [0, 199, 200, 299])

        let walked = try walkAllPages(of: archive)

        XCTAssertEqual(walked.count, 296)
        XCTAssertEqual(walked, expected)
    }

    // MARK: - TimelineCursor

    func testCursorFromAnUnsavedRowIsNil() {
        let row = ArchivedNotification(
            uuid: "0BADC0DE-0000-4000-8000-000000000001",
            appId: 1,
            deliveredAt: UnixDate(Date(timeIntervalSince1970: 1_755_400_000)),
            capturedAt: UnixDate(Date(timeIntervalSince1970: 1_755_400_000))
        )

        XCTAssertNil(TimelineCursor(row: row), "a row with no id has no tiebreaker to page on")
    }

    func testCursorFromASavedRowCarriesBothHalvesOfTheKey() throws {
        let archive = try XCTUnwrap(archive)
        try TimelineSeed.fill(archive, count: 1)
        let row = try XCTUnwrap(archive.timelinePage().first)

        let cursor = try XCTUnwrap(TimelineCursor(row: row))

        XCTAssertEqual(cursor.id, row.id)
        XCTAssertEqual(cursor.deliveredAt, row.deliveredAt)
    }

    // MARK: - Apps

    func testAppsByIDKeysEveryStoredApp() throws {
        let archive = try XCTUnwrap(archive)
        try TimelineSeed.fill(archive, count: 3)
        let row = try XCTUnwrap(archive.timelinePage().first)

        let apps = try archive.appsByID()

        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[row.appId]?.displayName, "Slack")
    }

    // MARK: Private

    private var archive: Archive?

    /// Walks every page the way `TimelineStore.loadNextPage()` does, returning the
    /// ids in the order they arrived.
    private func walkAllPages(of archive: Archive, pageSize: Int = Archive.timelinePageSize) throws -> [Int64] {
        var ids: [Int64] = []
        var cursor: TimelineCursor?

        while true {
            let page = try archive.timelinePage(after: cursor, limit: pageSize)
            guard !page.isEmpty else {
                break
            }
            ids.append(contentsOf: page.compactMap(\.id))
            cursor = try XCTUnwrap(TimelineCursor(row: XCTUnwrap(page.last)))
            guard page.count == pageSize else {
                break
            }
        }
        return ids
    }
}
