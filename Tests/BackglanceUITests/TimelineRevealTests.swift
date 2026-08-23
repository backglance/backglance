import BackglanceCore
import BackglanceTestSupport
@testable import BackglanceUI
import Foundation
import XCTest

/// `reveal(_:)` and the message toast — what `backglance://open?id=` needs once
/// `AppDelegate+URLScheme.swift` has resolved a uuid to a row.
///
/// A second suite rather than more of `TimelineStoreTests`: these tests are all about
/// putting one already-known row on screen, or reporting that it cannot be, which is a
/// different question from the live subscription and pagination tests already there —
/// the same split `TimelineReadStateTests` and `TimelineSelectionTests` already make
/// for their own topics.
@MainActor
final class TimelineRevealTests: XCTestCase {
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

    // MARK: - Reveal

    /// The common case: the row `Archive.notification(uuid:)` resolved is already
    /// sitting in the first page the subscription delivered.
    func testRevealSelectsAnAlreadyLoadedRowAndPublishesAScrollRequest() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 3)
        let store = makeStore(archive: archive, host: .window)
        try await waitUntil { store.visibleItems.count == 3 }
        let target = try XCTUnwrap(store.visibleItems.last?.notification)

        let outcome = await store.reveal(target)

        XCTAssertEqual(outcome, .revealed)
        XCTAssertEqual(store.selectedID, target.id)
        XCTAssertEqual(store.scrollRequest?.rowID, target.id)
    }

    /// A row older than what is currently loaded has to page older rows in first —
    /// the whole reason `backglance://open?id=` cannot just check `visibleItems`.
    func testRevealPagesOlderRowsInUntilTheRowIsFound() async throws {
        let archive = try XCTUnwrap(archive)
        let seeded = try seed(archive, count: 250)
        let store = makeStore(archive: archive, host: .window)
        try await waitUntil { store.visibleItems.count == TimelineStore.pageSize }
        // `seed` delivers oldest last, so this row is not in the first page.
        let target = try XCTUnwrap(seeded.last)

        let outcome = await store.reveal(target)

        XCTAssertEqual(outcome, .revealed)
        XCTAssertEqual(store.selectedID, target.id)
        XCTAssertEqual(store.visibleItems.count, 250, "paging in the target loaded everything behind it too")
    }

    /// Revealing the same row twice has to produce two distinct scroll requests —
    /// `selectedID` alone would not change the second time, and `TimelineView`'s
    /// `.onChange` needs a change to fire in order to re-scroll to it.
    func testRevealingTheSameRowTwiceProducesTwoDistinctScrollRequests() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 2)
        let store = makeStore(archive: archive, host: .window)
        try await waitUntil { store.visibleItems.count == 2 }
        let target = try XCTUnwrap(store.visibleItems.first?.notification)

        _ = await store.reveal(target)
        let first = try XCTUnwrap(store.scrollRequest)
        _ = await store.reveal(target)
        let second = try XCTUnwrap(store.scrollRequest)

        XCTAssertEqual(first.rowID, second.rowID)
        XCTAssertNotEqual(first, second, "a fresh request even though the row and selection did not change")
    }

    /// Hidden behind the app filter: in the archive, loaded in memory, but not
    /// something this store can currently point at.
    func testRevealIsUnreachableWhenTheAppFilterHidesTheRow() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 2)
        let mailRows = try seed(archive, count: 1, startingAt: 50, bundleID: Stubs.BundleID.mail)
        let store = makeStore(archive: archive, host: .window)
        try await waitUntil { store.visibleItems.count == 3 }
        store.appFilter = [Stubs.BundleID.slack]
        let target = try XCTUnwrap(mailRows.first)

        let outcome = await store.reveal(target)

        XCTAssertEqual(outcome, .unreachable)
        XCTAssertNil(store.scrollRequest, "no scroll to request when there is nothing reachable to scroll to")
    }

    /// Soft-deleted since the uuid was resolved: paging runs out of pages rather
    /// than hanging, and reports the same outcome a filtered-out row does.
    func testRevealIsUnreachableForARowDeletedSinceItWasResolved() async throws {
        let archive = try XCTUnwrap(archive)
        let seeded = try seed(archive, count: 3)
        let target = try XCTUnwrap(seeded.last)
        let id = try XCTUnwrap(target.id)
        try archive.softDelete([id])
        let store = makeStore(archive: archive, host: .window)
        try await waitUntil { store.visibleItems.count == 2 }

        let outcome = await store.reveal(target)

        XCTAssertEqual(outcome, .unreachable)
    }

    /// A row that was never inserted has no id, and therefore nothing to page
    /// toward — this has to fail fast rather than loop forever.
    func testRevealOfAnUnsavedRowIsUnreachable() async throws {
        let archive = try XCTUnwrap(archive)
        let store = makeStore(archive: archive, host: .window)
        let unsaved = ArchivedNotification(
            uuid: "FIXTURE-unsaved",
            appId: 1,
            deliveredAt: UnixDate(Stubs.epoch),
            capturedAt: UnixDate(Stubs.epoch)
        )

        let outcome = await store.reveal(unsaved)

        XCTAssertEqual(outcome, .unreachable)
    }

    // MARK: - Messages

    func testShowMessagePublishesTheTextAndClearMessageRemovesIt() throws {
        let archive = try XCTUnwrap(archive)
        let store = makeStore(archive: archive)

        store.showMessage("Not in the archive")

        XCTAssertEqual(store.message?.text, "Not in the archive")

        store.clearMessage()

        XCTAssertNil(store.message)
    }

    /// Two toasts with identical text still have to be distinguishable, the same
    /// reason ``TimelineStore/ScrollRequest`` carries a nonce: `TimelineView`'s
    /// auto-dismiss `.task(id:)` needs a fresh id to restart its clock for the second
    /// one.
    func testShowingTheSameMessageTwiceProducesDistinctIdentities() throws {
        let archive = try XCTUnwrap(archive)
        let store = makeStore(archive: archive)

        store.showMessage("Not in the archive")
        let first = try XCTUnwrap(store.message)
        store.showMessage("Not in the archive")
        let second = try XCTUnwrap(store.message)

        XCTAssertEqual(first.text, second.text)
        XCTAssertNotEqual(first.id, second.id)
    }

    // MARK: Private

    private var archive: Archive?
    private var store: TimelineStore?

    /// A store held by the test case, so the subscription is not cancelled by
    /// `deinit` the moment the local goes out of scope.
    @discardableResult
    private func makeStore(archive: Archive, host: TimelineStore.Host = .popover) -> TimelineStore {
        let name = "app.backglance.tests.\(UUID().uuidString)"
        let store = TimelineStore(archive: archive, host: host, defaults: UserDefaults(suiteName: name) ?? .standard)
        self.store = store
        return store
    }

    @discardableResult
    private func seed(
        _ archive: Archive,
        count: Int,
        startingAt offset: Int = 0,
        bundleID: String = Stubs.BundleID.slack
    ) throws -> [ArchivedNotification] {
        let app = try archive.upsertApp(bundleID: bundleID, now: Stubs.epoch)
        guard let appID = app.id else {
            throw XCTSkip("app row was not inserted")
        }

        return try (0 ..< count).map { index in
            let delivered = Stubs.epoch.addingTimeInterval(-Double(offset + index))
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
