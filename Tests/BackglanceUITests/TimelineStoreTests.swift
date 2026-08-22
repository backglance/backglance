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

    // MARK: - Selection

    /// The popover has a single focused row and no multi-select —
    /// docs/features/ACTIONS.md#selection-model.
    func testAPopoverStoreIgnoresEverySelectionOperation() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 3)
        let store = makeStore(archive: archive, host: .popover)
        try await waitUntil { store.visibleItems.count == 3 }
        let id = try XCTUnwrap(store.visibleItems.first?.id)

        store.selectOnly(id)
        store.toggleSelection(id)
        store.extendSelection(to: id)
        store.selectAllVisible()

        XCTAssertEqual(store.selection.count, 0, "the popover never accumulates a multi-selection")
        store.clearSelection() // must not crash on an already-empty selection
    }

    func testAWindowStoreHonoursSelectionOperations() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 3)
        let store = makeStore(archive: archive, host: .window)
        try await waitUntil { store.visibleItems.count == 3 }
        let ids = store.visibleItems.map(\.id)

        store.selectOnly(ids[0])
        XCTAssertEqual(store.selection.ids, [ids[0]])
        XCTAssertEqual(store.selectedID, ids[0], "a plain click also moves the keyboard focus")

        store.toggleSelection(ids[1])
        XCTAssertEqual(store.selection.ids, [ids[0], ids[1]])
        XCTAssertEqual(store.selectedID, ids[1])

        store.selectAllVisible()
        XCTAssertEqual(store.selection.ids, Set(ids))

        store.clearSelection()
        XCTAssertEqual(store.selection.count, 0)
    }

    /// Ranges resolve over `visibleItems` — "after filters, muted groups
    /// collapsed" — not over every row the store happens to hold in memory.
    func testExtendSelectionResolvesOverVisibleItemsOnly() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 2)
        try seed(archive, count: 3, startingAt: 50, bundleID: Stubs.BundleID.mail)
        let store = makeStore(archive: archive, host: .window)
        try await waitUntil { store.visibleItems.count == 5 }
        store.appFilter = [Stubs.BundleID.mail]
        let ids = store.visibleItems.map(\.id)
        XCTAssertEqual(ids.count, 3, "the mail-only filter is the visible ordering the range must respect")

        store.selectOnly(ids[0])
        store.extendSelection(to: ids[2])

        XCTAssertEqual(store.selection.ids, Set(ids), "the range covers exactly the filtered, visible rows")
    }

    /// A selection that survived a filter change would let ⌫ delete rows the
    /// user can no longer see.
    func testChangingTheAppFilterClearsTheSelection() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 2)
        try seed(archive, count: 3, startingAt: 50, bundleID: Stubs.BundleID.mail)
        let store = makeStore(archive: archive, host: .window)
        try await waitUntil { store.visibleItems.count == 5 }
        store.selectAllVisible()
        XCTAssertEqual(store.selection.count, 5)

        store.appFilter = [Stubs.BundleID.mail]

        XCTAssertEqual(store.selection.count, 0)
        XCTAssertNil(store.selection.anchor)
    }

    /// The action layer calls one property for both hosts: with nothing
    /// multi-selected, the focused row is the target of ⌘C or ⌫.
    func testSelectedIDsInVisibleOrderFallsBackToSelectedIDWhenTheMultiSelectionIsEmpty() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 3)
        let store = makeStore(archive: archive, host: .window)
        try await waitUntil { store.visibleItems.count == 3 }
        let id = try XCTUnwrap(store.visibleItems.first?.id)

        XCTAssertEqual(store.selectedIDsInVisibleOrder, [], "nothing focused and nothing selected")

        store.selectedID = id
        XCTAssertEqual(store.selectedIDsInVisibleOrder, [id])

        store.selectAllVisible()
        XCTAssertEqual(
            Set(store.selectedIDsInVisibleOrder),
            Set(store.visibleItems.map(\.id)),
            "once there is a real multi-selection it wins over the single focused row"
        )
    }

    // MARK: Private

    private var archive: Archive?
    private var store: TimelineStore?
    private var defaultsSuiteName: String?

    /// A store held by the test case, so the subscription is not cancelled by
    /// `deinit` the moment the local goes out of scope.
    @discardableResult
    private func makeStore(
        archive: Archive,
        host: TimelineStore.Host = .popover,
        defaults: UserDefaults? = nil
    ) -> TimelineStore {
        let store = TimelineStore(archive: archive, host: host, defaults: defaults ?? makeDefaults() ?? .standard)
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
