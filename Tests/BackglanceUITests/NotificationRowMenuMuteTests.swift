import BackglanceCore
import BackglanceTestSupport
@testable import BackglanceUI
import Foundation
import XCTest

/// Unit coverage for item 8 ("Mute ‹App› in Timeline" / "Unmute ‹App›",
/// BACKGLANCE-239) on `NotificationRowMenu.items(...)` —
/// docs/features/ACTIONS.md#context-menu-specification.
///
/// Split out of `NotificationRowMenuTests` purely for length: that file
/// already covers items 1–7, 9–11 and the multi-select targeting rules, and
/// adding item 8's five cases on top pushed it past SwiftLint's file-length
/// and type-body-length limits. Same style, same `makeItem` shape, same
/// "drive the pure model directly" approach the split file's own doc comment
/// explains — only the app scope changed compared to
/// `TimelineKeyboardTests`'s own file split.
final class NotificationRowMenuMuteTests: XCTestCase {
    // MARK: Internal

    /// The unmuted state offers "Mute ‹App› in Timeline", matching
    /// docs/features/ACTIONS.md's table exactly, and slots in right after the
    /// separator that follows item 6 — ahead of item 9.
    func testMuteLabelWhenTheAppIsNotMuted() {
        let items = NotificationRowMenu.items(
            for: makeItem(bundleID: "app.backglance.fixture.chat", isAppMuted: false),
            appName: "Fixture Chat",
            selectionCount: 0,
            host: .popover,
            canActivateApp: true,
            showsOpenLink: false
        )

        let mute = items.first { $0.kind == .mute || $0.kind == .unmute }
        XCTAssertEqual(mute?.kind, .mute)
        XCTAssertEqual(mute?.title, "Mute Fixture Chat in Timeline")
        XCTAssertEqual(mute?.isEnabled, true)
    }

    /// The muted state flips to "Unmute ‹App›" — the shorter form the table
    /// gives item 8's other half, not "Unmute ‹App› in Timeline".
    func testUnmuteLabelWhenTheAppIsMuted() {
        let items = NotificationRowMenu.items(
            for: makeItem(bundleID: "app.backglance.fixture.chat", isAppMuted: true),
            appName: "Fixture Chat",
            selectionCount: 0,
            host: .popover,
            canActivateApp: true,
            showsOpenLink: false
        )

        let mute = items.first { $0.kind == .mute || $0.kind == .unmute }
        XCTAssertEqual(mute?.kind, .unmute)
        XCTAssertEqual(mute?.title, "Unmute Fixture Chat")
        XCTAssertEqual(mute?.isEnabled, true)
    }

    /// The label reads `item.isAppMuted` — the raw `apps.is_muted` flag — and
    /// deliberately not `item.triage.muted`. A VIP-pinned row from a muted app
    /// has `triage.muted == false` (VIP beats mute,
    /// docs/features/RULES.md#edge-cases-and-error-handling) even though the
    /// app itself is still muted, so this row must still offer "Unmute", not
    /// "Mute" — the opposite of what reading `triage.muted` would produce.
    func testMuteLabelReadsTheRawAppFlagNotTheVIPOverriddenTriage() {
        let item = makeItem(
            triage: Triage(pinned: true, muted: false),
            bundleID: "app.backglance.fixture.chat",
            isAppMuted: true
        )
        XCTAssertFalse(item.triage.muted, "sanity: VIP beat mute for this row's own triage")

        let items = NotificationRowMenu.items(
            for: item,
            appName: "Fixture Chat",
            selectionCount: 0,
            host: .popover,
            canActivateApp: true,
            showsOpenLink: false
        )

        XCTAssertEqual(items.first { $0.kind == .mute || $0.kind == .unmute }?.kind, .unmute)
    }

    /// Item 2's own treatment: hidden entirely, not disabled, when there is no
    /// bundle id for `RulesEngine.setAppMuted` to act on.
    func testMuteHiddenWhenTheBundleIDDoesNotResolve() {
        let items = NotificationRowMenu.items(
            for: makeItem(bundleID: nil),
            appName: "Fixture Chat",
            selectionCount: 0,
            host: .popover,
            canActivateApp: true,
            showsOpenLink: false
        )

        XCTAssertFalse(items.contains { $0.kind == .mute || $0.kind == .unmute })
    }

    /// Item 8 sits between the item 6/7 separator and item 9, in both hosts —
    /// the same slot docs/features/ACTIONS.md's table draws it in.
    func testMuteSlotsInBetweenTheSeparatorAndNotificationSettings() {
        let items = NotificationRowMenu.items(
            for: makeItem(bundleID: "app.backglance.fixture.chat"),
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
            .mute,
            .notificationSettings,
            .separator,
            .delete,
        ])
    }

    // MARK: Private

    /// A synthetic row built directly, mirroring `NotificationRowMenuTests.makeItem`
    /// (the two are kept as separate small copies rather than shared, the same
    /// choice `TimelineKeyboardTests` and `NotificationRowMenuTests` already
    /// make independently of each other). All text is fabricated fixture
    /// content, per CLAUDE.md's Privacy Invariant #5.
    private func makeItem(
        triage: Triage = .none,
        bundleID: String? = nil,
        isAppMuted: Bool = false
    ) -> TimelineItem {
        let deliveredAt = UnixDate(Stubs.epoch)
        let notification = ArchivedNotification(
            uuid: "FIXTURE-ROWMENU-MUTE",
            appId: 1,
            title: "Fixture title",
            deliveredAt: deliveredAt,
            capturedAt: deliveredAt
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
