import BackglanceCore
import BackglanceTestSupport
@testable import BackglanceUI
import Foundation
import SwiftUI
import XCTest

/// Unit coverage for `TimelineKeyboard` — the pure, SwiftUI-free decisions
/// behind `TimelineView`'s keyboard shortcuts (BACKGLANCE-203 part 2). An
/// `.onKeyPress` closure cannot be driven from XCTest, so what is asserted
/// here is exactly what each handler in `TimelineView+Keyboard.swift`
/// delegates to before ever touching a dispatcher — the same split
/// `NotificationRowMenuTests` uses for `NotificationRowMenu.items(...)`.
final class TimelineKeyboardTests: XCTestCase {
    // MARK: Internal

    // MARK: - ⌫ / ⌦: nextSelectedID(afterDeleting:in:)

    /// The ordinary case: one focused row deleted, focus moves to whatever
    /// was right after it.
    func testNextSelectedIDMovesToTheRowAfterTheDeletedOne() {
        let items = makeItems(ids: [1, 2, 3])
        XCTAssertEqual(TimelineKeyboard.nextSelectedID(afterDeleting: [2], in: items), 3)
    }

    /// Deleting the last visible row leaves nothing to move focus to — `nil`
    /// is the correct answer, not a fallback to the row before it.
    func testNextSelectedIDIsNilWhenTheLastVisibleRowIsDeleted() {
        let items = makeItems(ids: [1, 2, 3])
        XCTAssertNil(TimelineKeyboard.nextSelectedID(afterDeleting: [3], in: items))
    }

    /// A contiguous multi-selection: focus lands on whatever follows the
    /// whole block, not on a row inside it.
    func testNextSelectedIDSkipsOverAContiguousMultiSelection() {
        let items = makeItems(ids: [1, 2, 3, 4])
        XCTAssertEqual(TimelineKeyboard.nextSelectedID(afterDeleting: [2, 3], in: items), 4)
    }

    /// A multi-selection that runs all the way to the end of the visible
    /// list is the same "nothing left" case as deleting a single last row.
    func testNextSelectedIDIsNilWhenTheDeletedBlockRunsToTheEnd() {
        let items = makeItems(ids: [1, 2, 3, 4])
        XCTAssertNil(TimelineKeyboard.nextSelectedID(afterDeleting: [3, 4], in: items))
    }

    /// A scattered (non-contiguous) selection resolves from the *last*
    /// deleted id in visible order, not the first.
    func testNextSelectedIDResolvesFromTheLastDeletedIDInVisibleOrder() {
        let items = makeItems(ids: [1, 2, 3, 4, 5])
        XCTAssertEqual(TimelineKeyboard.nextSelectedID(afterDeleting: [2, 4], in: items), 5)
    }

    /// None of the deleted ids are even in `items` — a stale call, or a
    /// selection that had already scrolled out of memory. Nothing to move
    /// focus relative to, so `nil`, not a guess.
    func testNextSelectedIDIsNilWhenNoneOfTheDeletedIDsAreVisible() {
        let items = makeItems(ids: [1, 2, 3])
        XCTAssertNil(TimelineKeyboard.nextSelectedID(afterDeleting: [99], in: items))
    }

    // MARK: - ⇧⌘P / ⇧⌘U: toggledValue(targetIDs:focusedID:items:current:)

    /// A mixed selection — one row already pinned, one not — must not vote by
    /// majority: the derivation reads only the *focused* row, per
    /// docs/features/ACTIONS.md's instruction to apply one consistent value
    /// to the whole target set.
    func testToggledValueTurnsOnWhenTheFocusedRowIsNotPinned() {
        let pinned = makeItem(id: 1, isPinned: true)
        let unpinned = makeItem(id: 2, isPinned: false)
        let items = [pinned, unpinned]

        let value = TimelineKeyboard.toggledValue(
            targetIDs: [1, 2],
            focusedID: 2,
            items: items,
            current: \.isPinned
        )

        XCTAssertTrue(value, "the focused row (2) is unpinned, so the toggle turns pinning on")
    }

    /// Same mixed selection, focus on the other row: the derived value flips
    /// the other way even though the *target set* did not change at all —
    /// only which row is focused decides the outcome.
    func testToggledValueTurnsOffWhenTheFocusedRowIsPinned() {
        let pinned = makeItem(id: 1, isPinned: true)
        let unpinned = makeItem(id: 2, isPinned: false)
        let items = [pinned, unpinned]

        let value = TimelineKeyboard.toggledValue(
            targetIDs: [1, 2],
            focusedID: 1,
            items: items,
            current: \.isPinned
        )

        XCTAssertFalse(value, "the focused row (1) is pinned, so the toggle turns pinning off")
    }

    /// `focusedID` is `nil` after `selectAllVisible()`, which builds a
    /// multi-selection without moving the keyboard focus onto any one row of
    /// it. The derivation still has to answer *something* — it falls back to
    /// the first target id.
    func testToggledValueFallsBackToTheFirstTargetWhenNothingIsFocused() {
        let read = makeItem(id: 1, isRead: true)
        let unread = makeItem(id: 2, isRead: false)
        let items = [read, unread]

        let value = TimelineKeyboard.toggledValue(
            targetIDs: [1, 2],
            focusedID: nil,
            items: items,
            current: \.isRead
        )

        XCTAssertFalse(value, "falls back to id 1 (already read), so the toggle turns read off")
    }

    // MARK: - ⇧⌘M: muteTarget(focusedID:items:)

    /// The ordinary case: the focused row's app is not muted, so the target
    /// flips it on.
    func testMuteTargetTurnsMutingOnWhenTheFocusedAppIsNotMuted() {
        let item = makeItem(id: 1, bundleID: "app.backglance.fixture.chat", isAppMuted: false)

        let target = TimelineKeyboard.muteTarget(focusedID: 1, items: [item])

        XCTAssertEqual(target?.bundleID, "app.backglance.fixture.chat")
        XCTAssertEqual(target?.muted, true)
    }

    /// The reverse: an already-muted app's focused row flips muting off.
    func testMuteTargetTurnsMutingOffWhenTheFocusedAppIsAlreadyMuted() {
        let item = makeItem(id: 1, bundleID: "app.backglance.fixture.chat", isAppMuted: true)

        let target = TimelineKeyboard.muteTarget(focusedID: 1, items: [item])

        XCTAssertEqual(target?.bundleID, "app.backglance.fixture.chat")
        XCTAssertEqual(target?.muted, false)
    }

    /// No focused row — the same "nothing to act on" answer
    /// `NotificationRowMenu`'s item 8 gives by hiding itself.
    func testMuteTargetIsNilWhenNothingIsFocused() {
        let item = makeItem(id: 1, bundleID: "app.backglance.fixture.chat")

        XCTAssertNil(TimelineKeyboard.muteTarget(focusedID: nil, items: [item]))
    }

    /// The focused row's app has no bundle id to mute — the keyboard shortcut
    /// must agree with the menu's item 8, which hides itself for exactly this
    /// row rather than ever offering something ``ActionDispatching/setAppMuted(bundleID:_:)``
    /// could not act on.
    func testMuteTargetIsNilWhenTheFocusedRowsBundleIDDoesNotResolve() {
        let item = makeItem(id: 1, bundleID: nil)

        XCTAssertNil(TimelineKeyboard.muteTarget(focusedID: 1, items: [item]))
    }

    /// A stale or off-screen focused id resolves to nothing, the same "no row
    /// to read from" outcome ``TimelineKeyboard/nextSelectedID(afterDeleting:in:)``
    /// gives for an id that is not in `items`.
    func testMuteTargetIsNilWhenTheFocusedIDIsNotInItems() {
        let item = makeItem(id: 1, bundleID: "app.backglance.fixture.chat")

        XCTAssertNil(TimelineKeyboard.muteTarget(focusedID: 99, items: [item]))
    }

    // MARK: - Esc: escapeOutcome(hasSelection:canDismiss:)

    /// With a multi-selection present, Esc clears it and stops there — it
    /// does not also close the surface on the same keypress.
    func testEscapeClearsTheSelectionWhenThereIsOneAndDoesNotDismiss() {
        XCTAssertEqual(
            TimelineKeyboard.escapeOutcome(hasSelection: true, canDismiss: true),
            .clearSelection
        )
    }

    /// With nothing selected, Esc dismisses the surface.
    func testEscapeDismissesWhenNothingIsSelected() {
        XCTAssertEqual(
            TimelineKeyboard.escapeOutcome(hasSelection: false, canDismiss: true),
            .dismiss
        )
    }

    /// Nothing selected and nothing to dismiss (a preview, or a host that
    /// never wired `timelineActions.dismiss`): the keypress falls through
    /// rather than being swallowed for no effect.
    func testEscapeIsIgnoredWhenThereIsNothingToClearOrDismiss() {
        XCTAssertEqual(
            TimelineKeyboard.escapeOutcome(hasSelection: false, canDismiss: false),
            .ignored
        )
    }

    // MARK: - ⌫: the two spellings TimelineView+Keyboard registers

    /// `KeyEquivalent.delete` is not the character the physical ⌫ delivers.
    ///
    /// This is the platform fact behind the second `.onKeyPress` registration
    /// in `TimelineView+Keyboard.swift` (BACKGLANCE-253). Measured off real
    /// keypresses in the running app: ⌫ arrives as U+007F, and with only the
    /// `.delete` registration attached it deleted nothing at all. The
    /// assertion is written as a *difference* on purpose — the day a Swift
    /// release makes `.delete` carry U+007F, this test fails, and the extra
    /// registration can be deleted rather than living on as cargo.
    func testDeleteKeyEquivalentDoesNotCarryTheCharacterBackspaceSends() {
        XCTAssertNotEqual(
            KeyEquivalent.delete.character,
            "\u{7F}",
            "if these are equal, TimelineKeyboardShortcuts' second ⌫ registration is now redundant"
        )
    }

    // MARK: Private

    /// Synthetic rows built directly, mirroring `NotificationRowMenuTests.makeItem`.
    /// All text is fabricated fixture content, per CLAUDE.md's Privacy Invariant #5.
    private func makeItem(
        id: Int64,
        isPinned: Bool = false,
        isRead: Bool = false,
        bundleID: String? = nil,
        isAppMuted: Bool = false
    ) -> TimelineItem {
        let deliveredAt = UnixDate(Stubs.epoch.addingTimeInterval(Double(id)))
        let notification = ArchivedNotification(
            uuid: "FIXTURE-KEYBOARD-\(id)",
            appId: 1,
            title: "Fixture title \(id)",
            deliveredAt: deliveredAt,
            capturedAt: deliveredAt,
            isRead: isRead,
            isPinned: isPinned
        )
        return TimelineItem(
            id: id,
            notification: notification,
            appName: "Fixture Chat",
            bundleID: bundleID,
            isAppMuted: isAppMuted
        )
    }

    private func makeItems(ids: [Int64]) -> [TimelineItem] {
        ids.map { makeItem(id: $0) }
    }
}
