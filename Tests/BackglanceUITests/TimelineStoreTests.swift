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
        if let defaultsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
            self.defaultsSuiteName = nil
        }
        try super.tearDownWithError()
    }

    // MARK: - The live subscription

    /// The store is useful the moment it exists: the subscription delivers the
    /// newest page without waiting for a write, which is what lets the popover
    /// open without running a query.
    func testTheFirstSnapshotArrivesWithoutAWrite() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 3)

        let store = makeStore(archive: archive)
        try await waitUntil { !store.sections.isEmpty }

        XCTAssertEqual(store.visibleItems.count, 3)
        XCTAssertNil(store.loadError)
    }

    /// A notification captured while the popover is open has to appear in it.
    func testAnInsertReachesTheOpenTimeline() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 1)
        let store = makeStore(archive: archive)
        try await waitUntil { store.visibleItems.count == 1 }

        try seed(archive, count: 1, startingAt: 99, secondsAgo: 0)

        try await waitUntil { store.visibleItems.count == 2 }
    }

    /// Muted apps never light the badge up — that is what muting an app means.
    func testTheBadgeCountsUnreadAndUnmutedOnly() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 2)
        try seed(archive, count: 3, startingAt: 50, bundleID: Stubs.BundleID.mail, muted: true)

        let store = makeStore(archive: archive)
        try await waitUntil { store.unreadBadgeCount > 0 }

        XCTAssertEqual(store.unreadBadgeCount, 2)
    }

    // MARK: - Merging and memory

    /// The subscription only ever carries the newest page. Rows the user paged
    /// back to must survive it, or scrolling down would undo itself every time
    /// capture inserted a row.
    func testMergingTheNewestPageKeepsThePagesBelowIt() throws {
        let archive = try XCTUnwrap(archive)
        let store = makeStore(archive: archive)

        store.mergeFirstPage(rows(ids: [10, 9, 8]))
        store.mergeFirstPage(rows(ids: [12, 11, 10, 9]))
        store.regroup()

        XCTAssertEqual(store.visibleItems.map(\.id), [12, 11, 10, 9, 8])
    }

    func testAnEmptyFirstPageEmptiesTheTimeline() throws {
        let archive = try XCTUnwrap(archive)
        let store = makeStore(archive: archive)
        store.mergeFirstPage(rows(ids: [3, 2, 1]))

        store.mergeFirstPage([])
        store.regroup()

        XCTAssertTrue(store.visibleItems.isEmpty)
        XCTAssertFalse(store.hasMorePages, "there is nothing left to page to")
    }

    /// A timeline that pages forever must not also grow forever.
    func testRowsAreCappedSoScrollbackCannotGrowWithoutBound() throws {
        let archive = try XCTUnwrap(archive)
        let store = makeStore(archive: archive)

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
        let store = makeStore(archive: archive)
        try await waitUntil { store.visibleItems.count == TimelineStore.pageSize }

        await store.loadNextPage()

        XCTAssertEqual(store.visibleItems.count, 250)
        XCTAssertEqual(Set(store.visibleItems.map(\.id)).count, 250)
        XCTAssertFalse(store.hasMorePages, "a short page is the end of the archive")
    }

    func testPagingPastTheEndIsANoOp() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 5)
        let store = makeStore(archive: archive)
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
        let store = makeStore(archive: archive)
        try await waitUntil { store.visibleItems.count == 5 }

        store.appFilter = [Stubs.BundleID.mail]

        XCTAssertEqual(store.visibleItems.count, 3)
        XCTAssertEqual(store.emptyStateKind, .allFiltered, "rows exist; the filter is why none are shown")
    }

    func testAnEmptyFilterMeansEverythingRatherThanNothing() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 4)
        let store = makeStore(archive: archive)
        try await waitUntil { store.visibleItems.count == 4 }

        store.appFilter = []

        XCTAssertEqual(store.visibleItems.count, 4)
    }

    // MARK: - Read state

    /// A row that sat on screen for a second has been read. Anything shorter
    /// would mark rows read that merely flew past under a flick scroll.
    func testARowVisibleForASecondIsMarkedRead() async throws {
        let archive = try XCTUnwrap(archive)
        let inserted = try seed(archive, count: 1)
        let id = try XCTUnwrap(inserted.first?.id)
        let store = makeStore(archive: archive)
        try await waitUntil { store.visibleItems.count == 1 }

        store.rowBecameVisible(id)

        try await waitUntil(timeout: 3) { store.visibleItems.first?.notification.isRead == true }
    }

    func testARowThatScrollsAwayEarlyStaysUnread() async throws {
        let archive = try XCTUnwrap(archive)
        let inserted = try seed(archive, count: 1)
        let id = try XCTUnwrap(inserted.first?.id)
        let store = makeStore(archive: archive)
        try await waitUntil { store.visibleItems.count == 1 }

        store.rowBecameVisible(id)
        store.rowBecameHidden(id)
        try await Task.sleep(for: .milliseconds(1_200))

        XCTAssertEqual(store.visibleItems.first?.notification.isRead, false)
    }

    /// Opening a row is unambiguous — no timer, no threshold.
    func testOpeningARowReadsItImmediately() async throws {
        let archive = try XCTUnwrap(archive)
        let inserted = try seed(archive, count: 1)
        let id = try XCTUnwrap(inserted.first?.id)
        let store = makeStore(archive: archive)
        try await waitUntil { store.visibleItems.count == 1 }

        store.open(id)

        XCTAssertEqual(store.selectedID, id)
        try await waitUntil { store.visibleItems.first?.notification.isRead == true }
    }

    func testMarkAllReadEmptiesTheBadge() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 4)
        let store = makeStore(archive: archive)
        try await waitUntil { store.unreadBadgeCount == 4 }

        store.markAllRead()

        try await waitUntil { store.unreadBadgeCount == 0 }
        XCTAssertNil(store.loadError)
    }

    // MARK: - The unread anchor

    /// Closing a surface is what makes "new" mean something: everything up to
    /// that moment has been seen, so the badge resets and the next open starts
    /// a fresh divider.
    func testClosingASurfaceAdvancesTheAnchorAndPersistsIt() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 3)
        let defaults = try XCTUnwrap(makeDefaults())
        let store = makeStore(archive: archive, defaults: defaults)
        try await waitUntil { store.unreadBadgeCount == 3 }

        store.surfaceDidClose()

        XCTAssertEqual(store.unreadBadgeCount, 0)
        XCTAssertEqual(
            defaults.double(forKey: TimelineStore.lastSeenKey),
            Date().timeIntervalSince1970,
            accuracy: 5,
            "the anchor has to survive a relaunch, so it is persisted rather than kept in memory"
        )
        // The badge query is defined by the anchor, so the fresh subscription
        // must not resurrect the old count.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.unreadBadgeCount, 0)
    }

    /// A stored anchor means a relaunch does not re-announce everything the
    /// user has already seen.
    func testAStoredAnchorSurvivesANewStore() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 3)
        let defaults = try XCTUnwrap(makeDefaults())
        defaults.set(Date().timeIntervalSince1970, forKey: TimelineStore.lastSeenKey)

        let store = makeStore(archive: archive, defaults: defaults)
        try await waitUntil { !store.sections.isEmpty }

        XCTAssertEqual(store.unreadBadgeCount, 0, "nothing arrived after the stored anchor")
    }

    func testOpeningASurfaceWithoutAwaySessionsLeavesTheAnchorAlone() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 2)
        let store = makeStore(archive: archive)
        try await waitUntil { store.unreadBadgeCount == 2 }

        store.surfaceWillOpen()

        XCTAssertEqual(store.unreadBadgeCount, 2, "looking at the timeline does not itself clear the badge")
    }

    // MARK: - Per-host preferences

    /// Glancing and reading are different jobs, so the two surfaces open
    /// differently until the user says otherwise.
    func testEachHostStartsInTheModeItsJobCallsFor() throws {
        let archive = try XCTUnwrap(archive)
        let defaults = try XCTUnwrap(makeDefaults())

        XCTAssertEqual(TimelineStore(archive: archive, host: .popover, defaults: defaults).viewMode, .compact)
        XCTAssertEqual(TimelineStore(archive: archive, host: .window, defaults: defaults).viewMode, .detailed)
    }

    func testTheViewModeIsRememberedPerHost() throws {
        let archive = try XCTUnwrap(archive)
        let defaults = try XCTUnwrap(makeDefaults())

        let popover = TimelineStore(archive: archive, host: .popover, defaults: defaults)
        popover.viewMode = .detailed

        XCTAssertEqual(TimelineStore(archive: archive, host: .popover, defaults: defaults).viewMode, .detailed)
        XCTAssertEqual(
            TimelineStore(archive: archive, host: .window, defaults: defaults).viewMode,
            .detailed,
            "the window's own default, untouched by the popover's change"
        )

        let window = TimelineStore(archive: archive, host: .window, defaults: defaults)
        window.viewMode = .compact

        XCTAssertEqual(
            TimelineStore(archive: archive, host: .popover, defaults: defaults).viewMode,
            .detailed,
            "the popover keeps what it was set to"
        )
    }

    func testGroupingIsRememberedPerHostAndRegroupsImmediately() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 2)
        try seed(archive, count: 1, startingAt: 50, bundleID: Stubs.BundleID.mail)
        let defaults = try XCTUnwrap(makeDefaults())
        let store = makeStore(archive: archive, defaults: defaults)
        try await waitUntil { store.visibleItems.count == 3 }

        store.groupByApp = true

        let headers = store.sections.flatMap(\.slots).filter { slot in
            if case .appHeader = slot {
                true
            } else {
                false
            }
        }
        XCTAssertEqual(headers.count, 2, "one header per app, without waiting for the next snapshot")
        XCTAssertTrue(TimelineStore(archive: archive, defaults: defaults).groupByApp)
        XCTAssertFalse(
            TimelineStore(archive: archive, host: .window, defaults: defaults).groupByApp,
            "the window groups the way the window was left"
        )
    }

    // MARK: - Empty states

    /// "Nothing here" means something different depending on why, and each
    /// meaning gets its own sentence and its own button.
    func testTheEmptyStateExplainsWhyTheTimelineIsEmpty() throws {
        let archive = try XCTUnwrap(archive)
        let store = makeStore(archive: archive)

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
    private var defaultsSuiteName: String?

    /// A store held by the test case, so the subscription is not cancelled by
    /// `deinit` the moment the local goes out of scope.
    @discardableResult
    private func makeStore(archive: Archive, defaults: UserDefaults? = nil) -> TimelineStore {
        let store = TimelineStore(archive: archive, defaults: defaults ?? makeDefaults() ?? .standard)
        self.store = store
        return store
    }

    /// A throwaway defaults suite per test: the real one is the user's, and a
    /// test that wrote the unread anchor into it would move their timeline.
    private func makeDefaults() -> UserDefaults? {
        let name = "app.backglance.tests.\(UUID().uuidString)"
        defaultsSuiteName = name
        return UserDefaults(suiteName: name)
    }

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
