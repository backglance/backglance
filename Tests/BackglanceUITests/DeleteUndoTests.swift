import BackglanceCore
import BackglanceTestSupport
@testable import BackglanceUI
import Foundation
import XCTest

// MARK: - DeleteUndoTests

/// Covers `NotificationActionHandler.delete(ids:)` / `undoDelete()` and the 5-second
/// undo window in docs/features/ACTIONS.md#delete-and-undo /
/// docs/features/ACTIONS.md#undo-toast.
///
/// Every expiry test drives ``ManualUndoClock`` instead of waiting out five real
/// seconds — the same technique `AwaySessionTrackerTests`' `ScriptedAwayClock` uses in
/// `BackglanceCoreTests` for the away-session merge gap, adapted to a duration-based
/// `sleep(seconds:)` rather than a deadline-based one.
@MainActor
final class DeleteUndoTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        handler = nil
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - delete(ids:)

    func testDeleteStoresThePendingUndo() throws {
        let id = try insertNotification(title: "Build finished")

        try makeHandler().delete(ids: [id])

        XCTAssertEqual(handler?.pendingUndo, [id])
    }

    func testDeleteActuallySoftDeletesTheRow() throws {
        let id = try insertNotification(title: "Build finished")

        try makeHandler().delete(ids: [id])

        XCTAssertTrue(try isDeleted(id))
    }

    /// Nothing was actually live, so there is nothing new to undo — no toast for a
    /// delete that changed no rows.
    func testDeletingAnAlreadyDeletedRowShowsNoToast() throws {
        let archive = try XCTUnwrap(archive)
        let id = try insertNotification(title: "Build finished")
        _ = try archive.softDelete([id])

        try makeHandler().delete(ids: [id])

        XCTAssertEqual(handler?.pendingUndo, [])
    }

    func testDeleteOfMultipleIdsStoresAllOfThem() throws {
        let first = try insertNotification(title: "First")
        let second = try insertNotification(title: "Second")

        try makeHandler().delete(ids: [first, second])

        XCTAssertEqual(Set(handler?.pendingUndo ?? []), Set([first, second]))
    }

    // MARK: - undoDelete()

    func testUndoDeleteRestoresTheRowAndClearsTheToast() throws {
        let id = try insertNotification(title: "Build finished")
        let handler = try makeHandler()
        try handler.delete(ids: [id])

        try handler.undoDelete()

        XCTAssertEqual(handler.pendingUndo, [])
        XCTAssertFalse(try isDeleted(id))
    }

    /// ⌘Z with no toast on screen is a keyboard miss, not a mistake — silently does
    /// nothing rather than beeping or throwing.
    func testUndoWithNothingPendingIsASilentNoOp() throws {
        let handler = try makeHandler()

        XCTAssertNoThrow(try handler.undoDelete())
        XCTAssertEqual(handler.pendingUndo, [])
    }

    // MARK: - Expiry

    /// The toast going away on its own must never restore anything: the rows stay
    /// soft-deleted for `RetentionJob` to hard-prune later, exactly as
    /// docs/features/ACTIONS.md#undo-toast says expiry does nothing else.
    func testExpiryClearsTheToastWithoutRestoringTheRow() async throws {
        let id = try insertNotification(title: "Build finished")
        let clock = ManualUndoClock()
        let handler = try makeHandler(clock: clock)
        try handler.delete(ids: [id])

        try await waitUntil { clock.sleepCallCount == 1 }
        clock.fire()
        try await waitUntil { handler.pendingUndo.isEmpty }

        XCTAssertTrue(try isDeleted(id), "expiry must not undo the delete")
    }

    /// A second delete before the first toast expires replaces the pending set and
    /// restarts the timer — the first timer's own expiry (simulated by firing what it
    /// left behind) must not affect the second delete's toast.
    func testASecondDeleteReplacesThePendingSetAndRestartsTheTimer() async throws {
        let first = try insertNotification(title: "First")
        let second = try insertNotification(title: "Second")
        let clock = ManualUndoClock()
        let handler = try makeHandler(clock: clock)

        try handler.delete(ids: [first])
        try await waitUntil { clock.sleepCallCount == 1 }

        try handler.delete(ids: [second])
        XCTAssertEqual(handler.pendingUndo, [second], "the toast now describes only the second delete")

        // The first delete's timer was cancelled, not merely superseded: only the
        // second delete's `sleep` call is still waiting to be fired.
        try await waitUntil { clock.sleepCallCount == 2 }
        clock.fire()
        try await waitUntil { handler.pendingUndo.isEmpty }

        XCTAssertTrue(try isDeleted(first), "the first delete's row is untouched by the second delete's toast")
        XCTAssertTrue(try isDeleted(second))
    }

    // MARK: Private

    private var archive: Archive?
    private var handler: NotificationActionHandler?

    private func makeHandler(clock: any UndoClock = ManualUndoClock()) throws -> NotificationActionHandler {
        let handler = try NotificationActionHandler(archive: XCTUnwrap(archive), undoClock: clock)
        self.handler = handler
        return handler
    }

    private func insertNotification(title: String) throws -> Int64 {
        let archive = try XCTUnwrap(archive)
        let app = try archive.upsertApp(bundleID: Stubs.BundleID.slack, now: Stubs.epoch)
        let appID = try XCTUnwrap(app.id)
        let inserted = try archive.insert(ArchivedNotification(
            uuid: UUID().uuidString,
            appId: appID,
            title: title,
            deliveredAt: UnixDate(Stubs.epoch),
            capturedAt: UnixDate(Stubs.epoch)
        ))
        return try XCTUnwrap(inserted.id)
    }

    private func isDeleted(_ id: Int64) throws -> Bool {
        let archive = try XCTUnwrap(archive)
        return try archive.pool.read { db in
            try XCTUnwrap(ArchivedNotification.fetchOne(db, key: id)).isDeleted
        }
    }

    /// Polls rather than sleeping a fixed amount, matching
    /// `TimelineReadStateTests.waitUntil` — the condition here is "has the just-spawned
    /// undo-expiry task reached `clock.sleep`, or has it finished", never a fixed delay.
    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
    }
}

// MARK: - ManualUndoClock

/// An ``UndoClock`` the test fires by hand instead of waiting out a real 5 seconds —
/// mirrors `AwaySessionTrackerTests`' `ScriptedAwayClock`, adapted to
/// `UndoClock.sleep(seconds:)`'s duration shape rather than `AwayClock.sleep(until:)`'s
/// deadline shape: there is no absolute instant to poll against here, so this holds
/// one continuation per in-flight `sleep(seconds:)` call and resolves it on demand.
///
/// Cancellation is handled by `withTaskCancellationHandler`, not by this class picking
/// it up after the fact: the moment `NotificationActionHandler.delete(ids:)` cancels a
/// previous undo-expiry task, that task's `sleep(seconds:)` call throws
/// `CancellationError` immediately, without needing ``fire()`` — which is exactly what
/// lets ``DeleteUndoTests/testASecondDeleteReplacesThePendingSetAndRestartsTheTimer()``
/// prove the first timer is well and truly gone rather than merely ignored.
private final class ManualUndoClock: UndoClock, @unchecked Sendable {
    // MARK: Internal

    var sleepCallCount: Int {
        lock.withLock { count }
    }

    func sleep(seconds _: TimeInterval) async throws {
        lock.withLock { count += 1 }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { pending.append(continuation) }
            }
        } onCancel: {
            let cancelled: [CheckedContinuation<Void, Error>] = lock.withLock {
                let all = pending
                pending.removeAll()
                return all
            }
            for continuation in cancelled {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// Resolves every `sleep(seconds:)` call currently waiting, as if its full
    /// duration had elapsed.
    func fire() {
        let waiting: [CheckedContinuation<Void, Error>] = lock.withLock {
            let all = pending
            pending.removeAll()
            return all
        }
        for continuation in waiting {
            continuation.resume()
        }
    }

    // MARK: Private

    private let lock = NSLock()
    private var count = 0
    private var pending: [CheckedContinuation<Void, Error>] = []
}
