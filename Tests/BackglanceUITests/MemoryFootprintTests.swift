import AppKit
import BackglanceCore
import BackglanceTestSupport
@testable import BackglanceUI
import Foundation
import SwiftUI
import XCTest

/// The memory budgets from docs/deployment/PERFORMANCE_GUIDE.md#memory-footprint:
/// **under 150 MB with the timeline open at a hundred thousand notifications**.
///
/// Measured as this process's resident size while the 100k archive is open and
/// the timeline is hosted offscreen and paged through — the same shape the
/// document describes, minus the app's own AppKit and SwiftUI runtime, which a
/// test process carries too but a test cannot separate. So the number here is
/// close to the app's and is compared against the same ceiling; the app-level
/// idle figure is an Instruments measurement on a running build.
///
/// What this genuinely catches is the failure it exists for: a timeline that
/// stops being paginated. Holding a hundred thousand rows instead of a thousand
/// is tens of megabytes of Swift structs, and this fails long before a user
/// would notice their fan.
@MainActor
final class MemoryFootprintTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            TestScope.includesSlowTests,
            "memory footprint runs in the Full test configuration"
        )
    }

    override func tearDownWithError() throws {
        store = nil
        try super.tearDownWithError()
    }

    func testTheTimelineAtAHundredThousandStaysUnderTheBudget() async throws {
        let archive = try LargeArchive.shared()
        let store = TimelineStore(
            archive: archive,
            defaults: UserDefaults(suiteName: "app.backglance.tests.\(UUID().uuidString)") ?? .standard
        )
        self.store = store
        try await waitUntil { !store.visibleItems.isEmpty }

        let hosting = NSHostingController(rootView: TimelineView().environment(store))
        hosting.sizingOptions = []
        hosting.view.frame = NSRect(x: 0, y: 0, width: 720, height: 640)
        hosting.view.layoutSubtreeIfNeeded()

        // Five pages deep is the document's scroll test: the point is that the
        // sixth page does not cost what the first five did.
        for _ in 0 ..< 5 {
            await store.loadNextPage()
            hosting.view.layoutSubtreeIfNeeded()
        }

        let resident = Self.residentBytes()
        XCTAssertLessThan(resident, Self.windowBudget, "resident \(Self.mb(resident))")
    }

    /// The property the budget rests on: paging never grows the row array past
    /// the cap, however far the user scrolls.
    func testPagingNeverGrowsPastTheRowCap() async throws {
        let archive = try LargeArchive.shared()
        let store = TimelineStore(
            archive: archive,
            defaults: UserDefaults(suiteName: "app.backglance.tests.\(UUID().uuidString)") ?? .standard
        )
        self.store = store
        try await waitUntil { !store.visibleItems.isEmpty }

        for _ in 0 ..< 10 {
            await store.loadNextPage()
        }

        XCTAssertLessThanOrEqual(store.visibleItems.count, TimelineStore.maxRows)
    }

    // MARK: Private

    /// 150 MB, the documented ceiling with the window open at 100k.
    private static let windowBudget: UInt64 = 150 * 1_024 * 1_024

    private var store: TimelineStore?

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    private static func mb(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private func waitUntil(
        timeout: TimeInterval = 20,
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
    }
}
