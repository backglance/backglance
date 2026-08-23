import BackglanceCore
import BackglanceTestSupport
@testable import BackglanceUI
import Foundation
import XCTest

/// Unit coverage for `NotificationRowMenu.items(...)` — the pure, SwiftUI-free
/// model behind the row context menu (docs/features/ACTIONS.md#context-menu-specification).
///
/// Every test here drives the model function directly, the same way
/// `AccessibilityTests` drives `NotificationRow`'s other static helpers: what
/// is asserted is the *string and ordering contract*, not anything about a
/// live `.contextMenu`, which XCTest cannot inspect on this platform anyway.
final class NotificationRowMenuTests: XCTestCase {
    // MARK: Internal

    // MARK: - Order and separator placement

    /// A plain row in the popover: item 2 (no link), item 8 (mute) and item
    /// 10 (export, popover-only) are all absent; every separator the table
    /// draws around them still lands in the right place.
    func testPlainRowOrderInThePopover() {
        let items = NotificationRowMenu.items(
            for: makeItem(),
            appName: "Fixture Chat",
            selectionCount: 0,
            host: .popover,
            canActivateApp: true,
            showsOpenLink: false
        )
        let kinds = items.map(\.kind)

        XCTAssertEqual(kinds, [
            .open,
            .separator,
            .copy, .copyWithAppAndTime,
            .separator,
            .pin, .markRead,
            .separator,
            .notificationSettings,
            .separator,
            .delete,
        ])
    }

    /// The same row in the window, with one row selected: item 10 (Export
    /// Selection…) now appears between the last separator and Delete, and
    /// nothing else about the order changes.
    func testPlainRowOrderInTheWindowWithASelection() {
        let items = NotificationRowMenu.items(
            for: makeItem(),
            appName: "Fixture Chat",
            selectionCount: 1,
            host: .window,
            canActivateApp: true,
            showsOpenLink: false
        )
        let kinds = items.map(\.kind)

        XCTAssertEqual(kinds, [
            .open,
            .separator,
            .copy, .copyWithAppAndTime,
            .separator,
            .pin, .markRead,
            .separator,
            .notificationSettings,
            .separator,
            .exportSelection,
            .delete,
        ])
    }

    /// Open Link present shifts nothing else — it slots in right after item 1,
    /// still ahead of the first separator.
    func testOpenLinkSlotsInAfterOpenWhenShown() {
        let items = NotificationRowMenu.items(
            for: makeItem(),
            appName: "Fixture Chat",
            selectionCount: 0,
            host: .popover,
            canActivateApp: true,
            showsOpenLink: true
        )
        let kinds = items.map(\.kind)

        XCTAssertEqual(Array(kinds.prefix(3)), [.open, .openLink, .separator])
    }

    // MARK: - Item 1: Open in ‹App›

    func testOpenInAppIsPresentAndEnabledWhenTheAppCanBeActivated() {
        let items = NotificationRowMenu.items(
            for: makeItem(),
            appName: "Fixture Chat",
            selectionCount: 0,
            host: .popover,
            canActivateApp: true,
            showsOpenLink: false
        )

        let open = items.first { $0.kind == .open }
        XCTAssertEqual(open?.title, "Open in Fixture Chat")
        XCTAssertEqual(open?.isEnabled, true)
    }

    /// The table's one explicit "disabled, not hidden" case: the item stays
    /// on screen so the user can see *why* nothing happens.
    func testOpenInAppIsPresentButDisabledWhenTheAppCannotBeActivated() {
        let items = NotificationRowMenu.items(
            for: makeItem(),
            appName: "Fixture Chat",
            selectionCount: 0,
            host: .popover,
            canActivateApp: false,
            showsOpenLink: false
        )

        let open = items.first { $0.kind == .open }
        XCTAssertNotNil(open, "item 1 is disabled, never hidden")
        XCTAssertEqual(open?.isEnabled, false)
    }

    // MARK: - Item 2: Open Link

    func testOpenLinkHiddenWhenShowsOpenLinkIsFalse() {
        let items = NotificationRowMenu.items(
            for: makeItem(),
            appName: "Fixture Chat",
            selectionCount: 0,
            host: .popover,
            canActivateApp: true,
            showsOpenLink: false
        )

        XCTAssertFalse(items.contains { $0.kind == .openLink })
    }

    func testOpenLinkPresentWhenShowsOpenLinkIsTrue() {
        let items = NotificationRowMenu.items(
            for: makeItem(),
            appName: "Fixture Chat",
            selectionCount: 0,
            host: .popover,
            canActivateApp: true,
            showsOpenLink: true
        )

        let openLink = items.first { $0.kind == .openLink }
        XCTAssertEqual(openLink?.title, "Open Link")
        XCTAssertEqual(openLink?.isEnabled, true)
    }

    // MARK: - Items 5/6: Pin/Unpin, Mark as Read/Unread

    func testPinLabelWhenNotManuallyPinned() {
        let items = NotificationRowMenu.items(
            for: makeItem(isPinned: false),
            appName: "X",
            selectionCount: 0,
            host: .popover,
            canActivateApp: true,
            showsOpenLink: false
        )

        XCTAssertEqual(items.first { $0.kind == .pin || $0.kind == .unpin }?.kind, .pin)
    }

    func testUnpinLabelWhenManuallyPinned() {
        let items = NotificationRowMenu.items(
            for: makeItem(isPinned: true),
            appName: "X",
            selectionCount: 0,
            host: .popover,
            canActivateApp: true,
            showsOpenLink: false
        )

        XCTAssertEqual(items.first { $0.kind == .pin || $0.kind == .unpin }?.kind, .unpin)
    }

    /// A VIP-triage pin (`triage.pinned`) makes `TimelineItem.isPinned` true
    /// without touching `notification.isPinned` at all. The menu item flips
    /// `is_pinned` — the manual flag — so it must keep offering "Pin", never
    /// "Unpin": offering "Unpin" here would flip a flag that was never true
    /// and do nothing to the row's actual pinned appearance.
    func testAVIPTriagePinnedRowStillOffersPinNotUnpin() {
        let item = makeItem(isPinned: false, triage: Triage(pinned: true))
        XCTAssertTrue(item.isPinned, "sanity: the derived flag is true")
        XCTAssertFalse(item.notification.isPinned, "sanity: the manual flag is not")

        let items = NotificationRowMenu.items(
            for: item,
            appName: "X",
            selectionCount: 0,
            host: .popover,
            canActivateApp: true,
            showsOpenLink: false
        )

        XCTAssertEqual(items.first { $0.kind == .pin || $0.kind == .unpin }?.kind, .pin)
    }

    func testMarkAsReadLabelWhenUnread() {
        let items = NotificationRowMenu.items(
            for: makeItem(isRead: false),
            appName: "X",
            selectionCount: 0,
            host: .popover,
            canActivateApp: true,
            showsOpenLink: false
        )

        XCTAssertEqual(items.first { $0.kind == .markRead || $0.kind == .markUnread }?.kind, .markRead)
    }

    func testMarkAsUnreadLabelWhenRead() {
        let items = NotificationRowMenu.items(
            for: makeItem(isRead: true),
            appName: "X",
            selectionCount: 0,
            host: .popover,
            canActivateApp: true,
            showsOpenLink: false
        )

        XCTAssertEqual(items.first { $0.kind == .markRead || $0.kind == .markUnread }?.kind, .markUnread)
    }

    // MARK: - Item 10: Export Selection…

    func testExportSelectionAbsentInThePopoverEvenWithASelection() {
        let items = NotificationRowMenu.items(
            for: makeItem(),
            appName: "X",
            selectionCount: 3,
            host: .popover,
            canActivateApp: true,
            showsOpenLink: false
        )

        XCTAssertFalse(items.contains { $0.kind == .exportSelection })
    }

    func testExportSelectionPresentInTheWindowWithASelection() {
        let items = NotificationRowMenu.items(
            for: makeItem(),
            appName: "X",
            selectionCount: 1,
            host: .window,
            canActivateApp: true,
            showsOpenLink: false
        )

        XCTAssertTrue(items.contains { $0.kind == .exportSelection })
    }

    func testExportSelectionAbsentInTheWindowWithNoSelection() {
        let items = NotificationRowMenu.items(
            for: makeItem(),
            appName: "X",
            selectionCount: 0,
            host: .window,
            canActivateApp: true,
            showsOpenLink: false
        )

        XCTAssertFalse(items.contains { $0.kind == .exportSelection })
    }

    // MARK: - Item 11: Delete

    func testDeleteLabelForASingleRow() {
        let items = NotificationRowMenu.items(
            for: makeItem(),
            appName: "X",
            selectionCount: 0,
            host: .popover,
            canActivateApp: true,
            showsOpenLink: false
        )

        XCTAssertEqual(items.first { $0.kind == .delete }?.title, "Delete")
    }

    /// `selectionCount == 1` (a lone selection, not a multi-select) reads the
    /// same as no selection at all — "Delete", never "Delete 1 Notification".
    func testDeleteLabelForALoneSelection() {
        let items = NotificationRowMenu.items(
            for: makeItem(),
            appName: "X",
            selectionCount: 1,
            host: .window,
            canActivateApp: true,
            showsOpenLink: false
        )

        XCTAssertEqual(items.first { $0.kind == .delete }?.title, "Delete")
    }

    func testDeleteLabelForAMultiSelect() {
        let items = NotificationRowMenu.items(
            for: makeItem(),
            appName: "X",
            selectionCount: 3,
            host: .window,
            canActivateApp: true,
            showsOpenLink: false
        )

        XCTAssertEqual(items.first { $0.kind == .delete }?.title, "Delete 3 Notifications")
    }

    // Item 8 ("Mute ‹App› in Timeline" / "Unmute ‹App›") has its own suite,
    // `NotificationRowMenuMuteTests`, split out purely to keep this file
    // under SwiftLint's file-length limit as the menu has grown to eleven
    // items — see that file's own doc comment.

    // MARK: - Which ids a menu item acts on

    /// docs/features/ACTIONS.md#context-menu-specification: items 3–6, 10 and 11
    /// "act on the whole selection". A right-click on a row that is part of a
    /// multi-selection must therefore target all of it, not just the row under
    /// the cursor.
    func testARightClickInsideAMultiSelectionTargetsTheWholeSelection() {
        XCTAssertEqual(
            NotificationRow.targetIDs(rightClicked: 2, selectionIDs: [1, 2, 3]),
            [1, 2, 3]
        )
    }

    /// The platform convention, and the thing that keeps item 11's label honest:
    /// right-clicking outside the selection acts on that row alone, so the menu
    /// says "Delete" rather than offering to delete rows the click had nothing
    /// to do with.
    func testARightClickOutsideTheSelectionTargetsOnlyThatRow() {
        XCTAssertEqual(
            NotificationRow.targetIDs(rightClicked: 9, selectionIDs: [1, 2, 3]),
            [9]
        )
    }

    /// A single-row selection is not a multi-select: the row clicked is the row
    /// acted on either way, so there is nothing for the selection to widen.
    func testASingleSelectedRowTargetsItself() {
        XCTAssertEqual(NotificationRow.targetIDs(rightClicked: 1, selectionIDs: [1]), [1])
        XCTAssertEqual(NotificationRow.targetIDs(rightClicked: 1, selectionIDs: []), [1])
    }

    /// The menu's label is built from the *targets*, never the raw selection —
    /// so a right-click outside a 3-row selection can never render "Delete 3
    /// Notifications" over an action that deletes one.
    func testDeleteLabelCountsTargetsNotTheRawSelection() {
        let item = makeItem()
        let targets = NotificationRow.targetIDs(rightClicked: 9, selectionIDs: [1, 2, 3])

        let items = NotificationRowMenu.items(
            for: item,
            appName: "Fixture Chat",
            selectionCount: targets.count,
            host: .window,
            canActivateApp: true,
            showsOpenLink: false
        )

        XCTAssertEqual(items.first { $0.kind == .delete }?.title, "Delete")
    }

    // MARK: Private

    /// A synthetic row built directly, mirroring `AccessibilityTests.makeItem`
    /// so the two suites share one pattern for building a minimal
    /// `TimelineItem`. All text is fabricated fixture content, per CLAUDE.md's
    /// Privacy Invariant #5.
    private func makeItem(
        isPinned: Bool = false,
        isRead: Bool = false,
        triage: Triage = .none,
        bundleID: String? = nil,
        isAppMuted: Bool = false
    ) -> TimelineItem {
        let deliveredAt = UnixDate(Stubs.epoch)
        let notification = ArchivedNotification(
            uuid: "FIXTURE-ROWMENU",
            appId: 1,
            title: "Fixture title",
            deliveredAt: deliveredAt,
            capturedAt: deliveredAt,
            isRead: isRead,
            isPinned: isPinned
        )
        return TimelineItem(
            id: 1,
            notification: notification,
            appName: "Fixture Chat",
            bundleID: bundleID,
            triage: triage,
            isAppMuted: isAppMuted
        )
    }
}
