import AppKit
import BackglanceCore
import BackglanceTestSupport
@testable import BackglanceUI
import Foundation
import SwiftUI
import XCTest

/// The menu bar budget: **under 100 ms from click to first painted row**
/// (docs/deployment/PERFORMANCE_GUIDE.md#menu-bar-responsiveness).
///
/// What is measured here is the part that is ours: hosting the popover's view
/// and laying it out with a warm store, which is everything between the click
/// and the first frame except AppKit's own window work. It runs offscreen, in
/// process, so it needs no UI automation and no permissions — and it fails for
/// exactly the reasons the budget exists to catch: a query on the click path, a
/// resize loop, or rows that cannot be diffed.
///
/// The remaining slice — `NSPopover.show` to the frame actually on screen — is
/// an Instruments measurement against the signposts in `StatusItemController`,
/// and belongs to a human with a trace open.
@MainActor
final class PopoverLaunchTests: XCTestCase {
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

    /// A full page in memory, laid out from scratch, well inside the budget.
    func testHostingAFullPageIsInsideTheFirstPaintBudget() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: TimelineStore.pageSize)
        let store = TimelineStore(archive: archive, defaults: throwawayDefaults())
        self.store = store
        try await waitUntil { store.visibleItems.count == TimelineStore.pageSize }

        // Median of five, not one sample: a single cold layout on a machine
        // that happens to be compiling something else measures the machine,
        // and a performance test that fails for that reason teaches everyone
        // to ignore performance tests.
        let samples = (0 ..< 5).map { _ in measureLayout(store: store) }
        let median = samples.sorted()[samples.count / 2]

        XCTAssertLessThan(median, Self.budget, "median first layout \(Self.ms(median)) of \(samples.map(Self.ms))")
    }

    /// The store holds the newest page already, so opening performs no query.
    /// This is the property the budget actually rests on.
    func testOpeningPerformsNoQuery() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 50)
        let store = TimelineStore(archive: archive, defaults: throwawayDefaults())
        self.store = store
        try await waitUntil { store.visibleItems.count == 50 }

        // Everything the surface needs on the click path is already in memory:
        // sections are built, not fetched.
        let started = Date()
        store.surfaceWillOpen()
        let sections = store.sections
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(sections.isEmpty)
        XCTAssertLessThan(elapsed, 0.010, "the click path took \(Self.ms(elapsed))")
    }

    /// Grouping is what the click path recomputes, and it is pure and bounded —
    /// a thousand rows is the ceiling the store keeps.
    func testGroupingAThousandRowsStaysWellInsideTheBudget() {
        let items = (0 ..< TimelineStore.maxRows).map { index in
            TimelineFixtures.item(id: Int64(index + 1), secondsAgo: TimeInterval(index) * 60)
        }

        let started = Date()
        let sections = TimelineStore.buildSections(
            items: items,
            groupByApp: false,
            anchor: UnixDate(.distantPast),
            calendar: TimelineFixtures.istanbul,
            now: Stubs.epoch
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(sections.isEmpty)
        XCTAssertLessThan(elapsed, 0.050, "grouping took \(Self.ms(elapsed))")
    }

    // MARK: Private

    private static let budget: TimeInterval = 0.100

    private var archive: Archive?
    private var store: TimelineStore?

    private static func ms(_ interval: TimeInterval) -> String {
        String(format: "%.1f ms", interval * 1_000)
    }

    /// Hosts the popover's timeline offscreen and forces a layout pass, the way
    /// `StatusItemController` hosts it for real.
    private func measureLayout(store: TimelineStore) -> TimeInterval {
        let started = Date()
        let hosting = NSHostingController(rootView: TimelineView().environment(store))
        // `sizingOptions = []` is the shipped configuration: SwiftUI must not
        // push intrinsic-size changes back into AppKit on every frame.
        hosting.sizingOptions = []
        let view = hosting.view
        view.frame = NSRect(origin: .zero, size: BackglanceUI.popoverSize)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        return Date().timeIntervalSince(started)
    }

    private func throwawayDefaults() -> UserDefaults {
        UserDefaults(suiteName: "app.backglance.tests.\(UUID().uuidString)") ?? .standard
    }

    private func seed(_ archive: Archive, count: Int) throws {
        let app = try archive.upsertApp(bundleID: Stubs.BundleID.slack, now: Stubs.epoch)
        let appID = try XCTUnwrap(app.id)
        try archive.pool.write { db in
            for index in 0 ..< count {
                var row = ArchivedNotification(
                    uuid: "LAUNCH-\(index)",
                    appId: appID,
                    title: "Fixture message \(String(format: "%06d", index))",
                    deliveredAt: UnixDate(Stubs.epoch.addingTimeInterval(-Double(index) * 60)),
                    capturedAt: UnixDate(Stubs.epoch)
                )
                try row.insert(db)
            }
        }
    }

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
