import BackglanceCore
import BackglanceTestSupport
@testable import BackglanceUI
import Foundation
import XCTest

/// What ``TimelineStore/Host`` actually decides.
///
/// These exist because BACKGLANCE-243 was not a bug in any of the code below — every
/// assertion here already passed. It was a bug in *composition*: the app built one
/// `host: .popover` store and handed it to both surfaces, so the window ran with the
/// popover's answers to all of it. The app target has no test host to catch that
/// (BACKGLANCE-238), so what is pinned down here instead is the invariant the fix
/// depends on — that `host` is behaviour, not chrome, and therefore that the two
/// surfaces cannot share one store.
@MainActor
final class TimelineHostTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        stores.removeAll()
        archive = nil
        for name in defaultsSuiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        defaultsSuiteNames.removeAll()
        try super.tearDownWithError()
    }

    // MARK: - Multi-select belongs to the window

    /// The whole of `TimelineStore+Selection` is gated on `host == .window`. A window
    /// running on a popover store is a window with no selection model at all — no
    /// ⌘-click, no ⇧-click, no ⌘A — which is exactly what shipped until BACKGLANCE-243.
    func testAPopoverStoreRefusesEveryMultiSelectMutator() async throws {
        let store = try await seededStore(host: .popover, count: 3)
        let ids = store.visibleItems.map(\.id)

        store.selectOnly(ids[0])
        XCTAssertEqual(store.selection.count, 0, "a plain click must not start a selection in the popover")

        store.toggleSelection(ids[1])
        XCTAssertEqual(store.selection.count, 0, "⌘-click must not select in the popover")

        store.extendSelection(to: ids[2])
        XCTAssertEqual(store.selection.count, 0, "⇧-click must not select in the popover")

        store.selectAllVisible()
        XCTAssertEqual(store.selection.count, 0, "⌘A must not select in the popover")
    }

    /// The same four calls on the surface they were written for.
    func testAWindowStorePerformsEveryMultiSelectMutator() async throws {
        let store = try await seededStore(host: .window, count: 3)
        let ids = store.visibleItems.map(\.id)

        store.selectOnly(ids[0])
        XCTAssertEqual(store.selection.count, 1)
        XCTAssertEqual(store.selectedID, ids[0])

        store.toggleSelection(ids[1])
        XCTAssertEqual(store.selection.count, 2)

        store.extendSelection(to: ids[2])
        XCTAssertTrue(store.selection.contains(ids[2]))

        store.selectAllVisible()
        XCTAssertEqual(store.selection.count, 3)
    }

    // MARK: - The hosts remember separately

    /// `viewModeKey(_:)` and `groupByAppKey(_:)` are per host, so the popover's compact
    /// glance and the window's detailed read do not overwrite each other. Two stores on
    /// one defaults suite is the case that matters: it is what the app now builds.
    func testEachHostReadsAndWritesItsOwnViewModeKey() async throws {
        let defaults = try XCTUnwrap(makeDefaults())
        let popover = try await seededStore(host: .popover, count: 1, defaults: defaults)
        let window = try await seededStore(host: .window, count: 0, defaults: defaults)

        popover.viewMode = .detailed
        window.viewMode = .compact

        XCTAssertEqual(popover.viewMode, .detailed)
        XCTAssertEqual(window.viewMode, .compact, "the window must not inherit the popover's view mode")

        // And the two survive a relaunch on the same suite, still apart.
        let reopenedPopover = try await seededStore(host: .popover, count: 0, defaults: defaults)
        let reopenedWindow = try await seededStore(host: .window, count: 0, defaults: defaults)
        XCTAssertEqual(reopenedPopover.viewMode, .detailed)
        XCTAssertEqual(reopenedWindow.viewMode, .compact)
    }

    /// The defaults each host starts from before the user has said anything: the popover
    /// is for glancing, the window is for reading. Sharing one store collapsed both onto
    /// whichever host built it.
    func testTheTwoHostsStartFromDifferentViewModes() {
        XCTAssertEqual(TimelineStore.Host.popover.defaultViewMode, .compact)
        XCTAssertEqual(TimelineStore.Host.window.defaultViewMode, .detailed)
    }

    // MARK: Private

    private var archive: Archive?
    /// Held for the lifetime of the test: a store that deallocates cancels its
    /// observation, and these tests keep two alive at once on purpose.
    private var stores: [TimelineStore] = []
    private var defaultsSuiteNames: [String] = []

    private func seededStore(
        host: TimelineStore.Host,
        count: Int,
        defaults: UserDefaults? = nil
    ) async throws -> TimelineStore {
        let archive = try XCTUnwrap(archive)
        if count > 0 {
            try seed(archive, count: count)
        }
        let suite = try defaults ?? XCTUnwrap(makeDefaults())
        let store = TimelineStore(archive: archive, host: host, defaults: suite)
        stores.append(store)
        if count > 0 {
            try await waitUntil { store.visibleItems.count == count }
        }
        return store
    }

    /// A throwaway defaults suite: the real one is the user's, and a test that wrote a
    /// view mode into it would change their timeline.
    private func makeDefaults() -> UserDefaults? {
        let name = "app.backglance.tests.\(UUID().uuidString)"
        defaultsSuiteNames.append(name)
        return UserDefaults(suiteName: name)
    }

    private func seed(_ archive: Archive, count: Int) throws {
        let app = try archive.upsertApp(bundleID: Stubs.BundleID.slack, now: Stubs.epoch)
        let appID = try XCTUnwrap(app.id)
        for index in 0 ..< count {
            try archive.insert(ArchivedNotification(
                uuid: "HOST-\(index)",
                appId: appID,
                title: "Notification \(index)",
                deliveredAt: UnixDate(Stubs.epoch.addingTimeInterval(TimeInterval(index))),
                capturedAt: UnixDate(Stubs.epoch.addingTimeInterval(TimeInterval(index)))
            ))
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met within \(timeout)s")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
