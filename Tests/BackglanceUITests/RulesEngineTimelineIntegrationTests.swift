@testable import BackglanceCore
import BackglanceTestSupport
@testable import BackglanceUI
import Foundation
import XCTest

// MARK: - RulesEngineTimelineIntegrationTests

/// An end-to-end-ish check that a rule reaches `TimelineStore`'s items as triage once
/// `RulesEngine` is installed — the same `triage: engine` wiring `AppDelegate.startInterface()`
/// does in production, exercised here with a real `Archive`, a real `RulesEngine`, and a real
/// `TimelineStore`, none of them faked.
///
/// **Why `install(rules:apps:)` is called directly rather than relying only on
/// `RulesEngine.start()`'s live subscription.** `TimelineStore` re-triages every row inside
/// `regroup()`, but it only calls `regroup()` when *its own* `ValueObservation` over
/// `notifications`/`apps` delivers a value — a bare `rules` table write touches neither table,
/// so nothing here would force a second `regroup()` if the rule landed *after* the store's
/// first render. Racing `RulesEngine`'s asynchronous `rules`/`apps` subscription against
/// `TimelineStore`'s own asynchronous `notifications`/`apps` subscription to see which fires
/// first is exactly the kind of test that is flaky by construction — sometimes the row would
/// already be triaged, sometimes it would need a `notifications`/`apps` write that never comes
/// to ever re-render. Installing the rule synchronously *before* constructing `TimelineStore`
/// sidesteps the race entirely: `engine.evaluate(_:)` always reads whatever is currently
/// installed, so by the time the store's first snapshot triggers its first `regroup()`, the
/// rule is already there to find. `engine.start()` is still called, so the live subscription
/// path is exercised too — just not depended on for the assertion.
@MainActor
final class RulesEngineTimelineIntegrationTests: XCTestCase {
    // MARK: Internal

    override func tearDownWithError() throws {
        store = nil
        defaultsSuiteName.map { UserDefaults.standard.removePersistentDomain(forName: $0) }
        try super.tearDownWithError()
    }

    func testARuleInstalledOnTheEngineReachesTheTimelineItemAsTriage() async throws {
        let archive = try Archive(inMemory: true)
        let app = try archive.upsertApp(bundleID: Stubs.BundleID.slack, now: Stubs.epoch)
        let appID = try XCTUnwrap(app.id)
        try await archive.pool.write { db in
            var rule = Rule(
                kind: .vip,
                pattern: "ayse",
                matchField: .sender,
                createdAt: UnixDate(Stubs.epoch)
            )
            try rule.insert(db)
        }
        try archive.insert(ArchivedNotification(
            uuid: "RULES-TIMELINE-1",
            appId: appID,
            title: "Deploy failed",
            sender: "Ayşe",
            deliveredAt: UnixDate(Stubs.epoch),
            capturedAt: UnixDate(Stubs.epoch)
        ))

        let engine = RulesEngine(archive: archive)
        // Deterministic: the rule and the app are already archived, so this installs the
        // exact snapshot `start()`'s first delivery would — just without waiting for it.
        let rules = try await archive.pool.read { db in try Rule.fetchAll(db) }
        engine.install(rules: rules, apps: [app])
        engine.start()

        let defaults = try makeDefaults()
        let store = TimelineStore(archive: archive, triage: engine, host: .popover, defaults: defaults)
        self.store = store

        try await waitUntil { store.visibleItems.first?.triage.pinned == true }

        let item = try XCTUnwrap(store.visibleItems.first)
        XCTAssertTrue(item.triage.pinned, "the vip rule installed on the engine must reach the timeline item")
        XCTAssertTrue(item.isPinned, "TimelineItem.isPinned folds in triage.pinned alongside the manual pin")
    }

    // MARK: Private

    private var store: TimelineStore?
    private var defaultsSuiteName: String?

    private func makeDefaults() throws -> UserDefaults {
        let name = "app.backglance.tests.\(UUID().uuidString)"
        defaultsSuiteName = name
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    /// The same bounded poll `TimelineStoreTests` already relies on for its own
    /// `ValueObservation` assertions — never a fixed `Task.sleep`, so this test either
    /// converges within the timeout or fails loudly instead of flaking quietly.
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
