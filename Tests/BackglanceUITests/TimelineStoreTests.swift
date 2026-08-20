import BackglanceCore
import BackglanceTestSupport
@testable import BackglanceUI
import Foundation
import XCTest

@MainActor
final class TimelineStoreTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        store = nil
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - The live subscription

    /// The store is useful the moment it exists: the subscription delivers the
    /// newest page without waiting for a write, which is what lets the popover
    /// open without running a query.
    func testTheFirstSnapshotArrivesWithoutAWrite() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 3)

        let store = TimelineStore(archive: archive)
        self.store = store
        try await waitUntil { !store.sections.isEmpty }

        XCTAssertEqual(store.visibleItems.count, 3)
        XCTAssertNil(store.loadError)
    }

    /// A notification captured while the popover is open has to appear in it.
    func testAnInsertReachesTheOpenTimeline() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 1)
        let store = TimelineStore(archive: archive)
        self.store = store
        try await waitUntil { store.visibleItems.count == 1 }

        try seed(archive, count: 1, startingAt: 99, secondsAgo: 0)

        try await waitUntil { store.visibleItems.count == 2 }
    }

    /// Muted apps never light the badge up — that is what muting an app means.
    func testTheBadgeCountsUnreadAndUnmutedOnly() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 2)
        try seed(archive, count: 3, startingAt: 50, bundleID: Stubs.BundleID.mail, muted: true)

        let store = TimelineStore(archive: archive)
        self.store = store
        try await waitUntil { store.unreadBadgeCount > 0 }

        XCTAssertEqual(store.unreadBadgeCount, 2)
    }

    // MARK: - Merging and memory

    /// The subscription only ever carries the newest page. Rows the user paged
    /// back to must survive it, or scrolling down would undo itself every time
    /// capture inserted a row.
    func testMergingTheNewestPageKeepsThePagesBelowIt() throws {
        let archive = try XCTUnwrap(archive)
        let store = TimelineStore(archive: archive)
        self.store = store

        store.mergeFirstPage(rows(ids: [10, 9, 8]))
        store.mergeFirstPage(rows(ids: [12, 11, 10, 9]))
        store.regroup()

        XCTAssertEqual(store.visibleItems.map(\.id), [12, 11, 10, 9, 8])
    }

    func testAnEmptyFirstPageEmptiesTheTimeline() throws {
        let archive = try XCTUnwrap(archive)
        let store = TimelineStore(archive: archive)
        self.store = store
        store.mergeFirstPage(rows(ids: [3, 2, 1]))

        store.mergeFirstPage([])
        store.regroup()

        XCTAssertTrue(store.visibleItems.isEmpty)
        XCTAssertFalse(store.hasMorePages, "there is nothing left to page to")
    }

    /// A timeline that pages forever must not also grow forever.
    func testRowsAreCappedSoScrollbackCannotGrowWithoutBound() throws {
        let archive = try XCTUnwrap(archive)
        let store = TimelineStore(archive: archive)
        self.store = store

        store.mergeFirstPage(rows(ids: Array((1 ... 1_200).reversed())))
        store.regroup()

        XCTAssertEqual(store.visibleItems.count, TimelineStore.maxRows)
        XCTAssertEqual(store.visibleItems.first?.id, 1_200, "the newest rows are the ones worth keeping")
        XCTAssertTrue(store.hasMorePages, "dropping the tail means there is more to page back to")
    }

    // MARK: - Pagination

    func testPagingAppendsOlderRowsWithoutDuplicating() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 250)
        let store = TimelineStore(archive: archive)
        self.store = store
        try await waitUntil { store.visibleItems.count == TimelineStore.pageSize }

        await store.loadNextPage()

        XCTAssertEqual(store.visibleItems.count, 250)
        XCTAssertEqual(Set(store.visibleItems.map(\.id)).count, 250)
        XCTAssertFalse(store.hasMorePages, "a short page is the end of the archive")
    }

    func testPagingPastTheEndIsANoOp() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 5)
        let store = TimelineStore(archive: archive)
        self.store = store
        try await waitUntil { store.visibleItems.count == 5 }

        await store.loadNextPage()
        await store.loadNextPage()

        XCTAssertEqual(store.visibleItems.count, 5)
        XCTAssertFalse(store.hasMorePages)
    }

    // MARK: - Filtering

    func testAnAppFilterHidesEveryOtherApp() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 2)
        try seed(archive, count: 3, startingAt: 50, bundleID: Stubs.BundleID.mail)
        let store = TimelineStore(archive: archive)
        self.store = store
        try await waitUntil { store.visibleItems.count == 5 }

        store.appFilter = [Stubs.BundleID.mail]

        XCTAssertEqual(store.visibleItems.count, 3)
        XCTAssertEqual(store.emptyStateKind, .allFiltered, "rows exist; the filter is why none are shown")
    }

    func testAnEmptyFilterMeansEverythingRatherThanNothing() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 4)
        let store = TimelineStore(archive: archive)
        self.store = store
        try await waitUntil { store.visibleItems.count == 4 }

        store.appFilter = []

        XCTAssertEqual(store.visibleItems.count, 4)
    }

    // MARK: - Empty states

    /// "Nothing here" means something different depending on why, and each
    /// meaning gets its own sentence and its own button.
    func testTheEmptyStateExplainsWhyTheTimelineIsEmpty() throws {
        let archive = try XCTUnwrap(archive)
        let store = TimelineStore(archive: archive)
        self.store = store

        store.captureState = .running
        XCTAssertEqual(store.emptyStateKind, .nothingYet)

        store.captureState = .noFullDiskAccess
        XCTAssertEqual(store.emptyStateKind, .noFullDiskAccess)

        store.captureState = .paused(until: nil)
        XCTAssertEqual(store.emptyStateKind, .paused)

        store.captureState = .degraded(message: "The notification store changed shape.")
        XCTAssertEqual(
            store.emptyStateKind,
            .nothingYet,
            "a degraded reason the user cannot act on is not its own empty state"
        )
    }

    // MARK: Private

    private var archive: Archive?
    private var store: TimelineStore?

    /// Notifications that were never inserted — enough for the pure merge and
    /// cap paths, which never touch the archive.
    private func rows(ids: [Int64]) -> [ArchivedNotification] {
        ids.map { id in
            ArchivedNotification(
                id: id,
                uuid: "FIXTURE-\(id)",
                appId: 1,
                title: "Fixture message \(id)",
                deliveredAt: UnixDate(Stubs.epoch.addingTimeInterval(Double(id))),
                capturedAt: UnixDate(Stubs.epoch)
            )
        }
    }

    @discardableResult
    private func seed(
        _ archive: Archive,
        count: Int,
        startingAt offset: Int = 0,
        bundleID: String = Stubs.BundleID.slack,
        secondsAgo: TimeInterval? = nil,
        muted: Bool = false
    ) throws -> [ArchivedNotification] {
        var app = try archive.upsertApp(bundleID: bundleID, now: Stubs.epoch)
        if muted {
            app.isMuted = true
            try archive.pool.write { db in try app.update(db) }
        }
        guard let appID = app.id else {
            throw XCTSkip("app row was not inserted")
        }

        return try (0 ..< count).map { index in
            let delivered = Stubs.epoch.addingTimeInterval(-(secondsAgo ?? Double(offset + index)))
            return try archive.insert(ArchivedNotification(
                uuid: "FIXTURE-\(offset + index)-\(bundleID)",
                appId: appID,
                title: "Fixture message \(String(format: "%06d", offset + index))",
                deliveredAt: UnixDate(delivered),
                capturedAt: UnixDate(Stubs.epoch)
            ))
        }
    }

    /// Waits for the subscription to deliver, without a fixed sleep that would
    /// be either flaky or slow.
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
    }
}
