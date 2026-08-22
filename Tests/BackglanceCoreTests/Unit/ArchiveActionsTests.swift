@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

/// Covers `Archive+Actions.swift`: soft delete and its undo, per
/// docs/features/ACTIONS.md#delete-and-undo. `RetentionJob`'s hard-prune of
/// `is_deleted = 1` rows is exercised separately in `RetentionJobTests`; the one thing
/// borrowed from it here is the shape of "restore after a hard prune", simulated with
/// a direct `DELETE` the same way `RetentionJobTests` would.
final class ArchiveActionsTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archiveStorage = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archiveStorage = nil
        try super.tearDownWithError()
    }

    // MARK: - softDelete(_:)

    func testSoftDeleteFlipsLiveRowsAndReturnsExactlyThoseIds() throws {
        let ids = try TimelineSeed.fill(archive(), count: 3)

        let flipped = try archive().softDelete(ids)

        XCTAssertEqual(Set(flipped), Set(ids))
        XCTAssertTrue(try ids.allSatisfy(isDeleted))
    }

    /// A row another window already soft-deleted (or that never existed) must not be
    /// reported as "flipped by this call" — undo would otherwise restore something
    /// this call never touched.
    func testSoftDeleteReturnsOnlyTheIdsThatWereActuallyLive() throws {
        let ids = try TimelineSeed.fill(archive(), count: 3)
        let alreadyDeleted = try XCTUnwrap(ids.first)
        try archive().pool.write { db in
            try db.execute(sql: "UPDATE notifications SET is_deleted = 1 WHERE id = ?", arguments: [alreadyDeleted])
        }
        let neverExisted: Int64 = 999_999

        let flipped = try archive().softDelete(ids + [neverExisted])

        XCTAssertEqual(Set(flipped), Set(ids.dropFirst()))
    }

    /// Deleting an already-deleted set a second time flips nothing — there is nothing
    /// left that was live, so the return value is empty and undo of this second call
    /// must not resurrect anything.
    func testASecondSoftDeleteOfTheSameIdsReturnsEmpty() throws {
        let ids = try TimelineSeed.fill(archive(), count: 2)
        _ = try archive().softDelete(ids)

        let second = try archive().softDelete(ids)

        XCTAssertTrue(second.isEmpty)
    }

    func testSoftDeleteOfAnEmptyArrayIsANoOpAndTouchesNoRows() throws {
        let ids = try TimelineSeed.fill(archive(), count: 2)

        XCTAssertEqual(try archive().softDelete([]), [])
        XCTAssertFalse(try ids.contains(where: isDeleted))
    }

    /// `Archive.timelinePage` filters `is_deleted = 0` itself; this proves the two
    /// meet correctly rather than assuming the column flip is enough.
    func testSoftDeletedRowsDisappearFromTheTimelinePage() throws {
        let ids = try TimelineSeed.fill(archive(), count: 3)
        let deleted = try XCTUnwrap(ids.first)

        _ = try archive().softDelete([deleted])

        let page = try archive().timelinePage()
        XCTAssertFalse(page.contains { $0.id == deleted })
        XCTAssertEqual(page.count, ids.count - 1)
    }

    // MARK: - restore(_:)

    func testRestoreFlipsBackAndReturnsTheChangedCount() throws {
        let ids = try TimelineSeed.fill(archive(), count: 3)
        _ = try archive().softDelete(ids)

        let changed = try archive().restore(ids)

        XCTAssertEqual(changed, ids.count)
        XCTAssertFalse(try ids.contains(where: isDeleted))
    }

    /// Restoring rows that were never soft-deleted (or already restored) changes
    /// nothing — the `is_deleted = 1` guard is what keeps a repeat call from wasting a
    /// write on rows already at rest.
    func testRestoringLiveRowsChangesNothing() throws {
        let ids = try TimelineSeed.fill(archive(), count: 2)

        XCTAssertEqual(try archive().restore(ids), 0)
    }

    /// The retention job hard-prunes `is_deleted = 1` rows on its own schedule,
    /// independent of any undo window. A restore that loses that race finds nothing
    /// left to flip — this must report `0`, not throw, per
    /// docs/features/ACTIONS.md's edge case table ("Undo after the retention job
    /// already hard-pruned").
    func testRestoringHardPrunedIdsReturnsZeroWithoutThrowing() throws {
        let ids = try TimelineSeed.fill(archive(), count: 2)
        let pruned = try XCTUnwrap(ids.first)
        _ = try archive().softDelete([pruned])
        try archive().pool.write { db in
            try db.execute(sql: "DELETE FROM notifications WHERE id = ?", arguments: [pruned])
        }

        // A throw here would fail the test on its own, since this method is `throws`;
        // the real assertion is that it does not, and that the count is `0`.
        XCTAssertEqual(try archive().restore([pruned]), 0)
    }

    func testRestoreOfAnEmptyArrayIsANoOp() throws {
        XCTAssertEqual(try archive().restore([]), 0)
    }

    // MARK: - setPinned(_:_:) / setRead(_:_:)

    /// The ordinary path: a live, unpinned row flips to pinned and the count
    /// reflects exactly the one row that changed.
    func testSetPinnedTrueFlipsAnUnpinnedRowAndReturnsTheChangedCount() throws {
        let ids = try TimelineSeed.fill(archive(), count: 2)

        let changed = try archive().setPinned(ids, true)

        XCTAssertEqual(changed, ids.count)
        XCTAssertTrue(try ids.allSatisfy(isPinned))
    }

    /// The `is_pinned = ? (old value)` guard is what keeps a redundant pin from
    /// touching the row (and, in the running app, waking the timeline's
    /// observation for nothing): pinning an already-pinned row changes zero rows.
    func testSetPinnedTrueOnAnAlreadyPinnedRowChangesNothing() throws {
        let ids = try TimelineSeed.fill(archive(), count: 2)
        _ = try archive().setPinned(ids, true)

        let second = try archive().setPinned(ids, true)

        XCTAssertEqual(second, 0)
        XCTAssertTrue(try ids.allSatisfy(isPinned))
    }

    /// Unpinning flips the same column back, proving the toggle is symmetric
    /// rather than a one-way "pin" method with no reverse.
    func testSetPinnedFalseFlipsAPinnedRowBack() throws {
        let ids = try TimelineSeed.fill(archive(), count: 2)
        _ = try archive().setPinned(ids, true)

        let changed = try archive().setPinned(ids, false)

        XCTAssertEqual(changed, ids.count)
        XCTAssertFalse(try ids.contains(where: isPinned))
    }

    /// A soft-deleted row is not in front of the user, so a pin toggle must not
    /// touch it — the same reasoning `markRead(ids:)` already applies to its own
    /// `is_deleted = 0` guard.
    func testSetPinnedDoesNotTouchASoftDeletedRow() throws {
        let ids = try TimelineSeed.fill(archive(), count: 2)
        let deleted = try XCTUnwrap(ids.first)
        _ = try archive().softDelete([deleted])

        let changed = try archive().setPinned([deleted], true)

        XCTAssertEqual(changed, 0)
        XCTAssertFalse(try isPinned(deleted))
    }

    func testSetPinnedOfAnEmptyArrayIsANoOp() throws {
        XCTAssertEqual(try archive().setPinned([], true), 0)
    }

    /// Marking an already-read row unread must genuinely flip it back — unread is
    /// not a lesser-used mirror of read, per docs/features/ACTIONS.md.
    func testSetReadFalseGenuinelyMarksAnAlreadyReadRowUnread() throws {
        let ids = try TimelineSeed.fill(archive(), count: 2)
        _ = try archive().setRead(ids, true)
        XCTAssertTrue(try ids.allSatisfy(isRead))

        let changed = try archive().setRead(ids, false)

        XCTAssertEqual(changed, ids.count)
        XCTAssertFalse(try ids.contains(where: isRead))
    }

    /// `markRead(ids:)` now delegates to `setRead(_:_:)`; this proves the
    /// delegation preserves the method's original behaviour (flip, and only what
    /// was actually unread).
    func testMarkReadStillFlipsOnlyUnreadRowsAndReturnsTheChangedCount() throws {
        let ids = try TimelineSeed.fill(archive(), count: 3)
        let alreadyRead = try XCTUnwrap(ids.first)
        _ = try archive().setRead([alreadyRead], true)

        let changed = try archive().markRead(ids: ids)

        XCTAssertEqual(changed, ids.count - 1)
        XCTAssertTrue(try ids.allSatisfy(isRead))
    }

    // MARK: Private

    private var archiveStorage: Archive?

    private func archive() throws -> Archive {
        try XCTUnwrap(archiveStorage)
    }

    private func isDeleted(_ id: Int64) throws -> Bool {
        try archive().pool.read { db in
            try XCTUnwrap(ArchivedNotification.fetchOne(db, key: id)).isDeleted
        }
    }

    private func isPinned(_ id: Int64) throws -> Bool {
        try archive().pool.read { db in
            try XCTUnwrap(ArchivedNotification.fetchOne(db, key: id)).isPinned
        }
    }

    private func isRead(_ id: Int64) throws -> Bool {
        try archive().pool.read { db in
            try XCTUnwrap(ArchivedNotification.fetchOne(db, key: id)).isRead
        }
    }
}
