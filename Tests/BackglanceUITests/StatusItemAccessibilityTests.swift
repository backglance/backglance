import BackglanceCore
@testable import BackglanceUI
import Foundation
import XCTest

/// Unit coverage for what VoiceOver says about the menu bar item —
/// docs/reference/ACCESSIBILITY.md#menu-bar-item.
///
/// The status item is `NSStatusItem` in the app shell, which has no test
/// bundle; the string contract is pinned here instead, where it is a pure
/// function. What matters is that both signals the icon carries — the unread
/// count and the capture state — survive into words, because a screen reader
/// user gets neither from a template image.
final class StatusItemAccessibilityTests: XCTestCase {
    // MARK: - Unread count

    /// Zero unread is said out loud, not left as silence. "Backglance" alone
    /// would be indistinguishable from a label that simply failed to update.
    func testZeroUnreadIsAnnouncedExplicitly() {
        let label = StatusItemAccessibility.label(unreadCount: 0, state: .running)

        XCTAssertEqual(label, "Backglance, no unread notifications")
    }

    /// One unread reads as a singular. The drawn badge can get away with a bare
    /// digit; a sentence cannot.
    func testSingleUnreadReadsAsSingular() {
        let label = StatusItemAccessibility.label(unreadCount: 1, state: .running)

        XCTAssertEqual(label, "Backglance, 1 unread notification")
    }

    func testSeveralUnreadReadsAsPlural() {
        let label = StatusItemAccessibility.label(unreadCount: 7, state: .running)

        XCTAssertEqual(label, "Backglance, 7 unread notifications")
    }

    /// At and above the cap the badge draws "99+", so the label stops giving an
    /// exact number too — announcing 214 when the icon shows 99+ is its own
    /// kind of wrong.
    func testCountIsCappedTheSameWayTheBadgeIs() {
        let atCap = StatusItemAccessibility.label(unreadCount: Archive.unreadBadgeCap, state: .running)
        let far = StatusItemAccessibility.label(unreadCount: Archive.unreadBadgeCap + 114, state: .running)

        XCTAssertEqual(atCap, "Backglance, more than 99 unread notifications")
        XCTAssertEqual(far, atCap)
    }

    /// One below the cap is still an exact count — the boundary belongs to the
    /// capped phrasing, not to the count.
    func testJustUnderTheCapStillReadsExactly() {
        let label = StatusItemAccessibility.label(unreadCount: Archive.unreadBadgeCap - 1, state: .running)

        XCTAssertEqual(label, "Backglance, 99 unread notifications")
    }

    // MARK: - Capture state

    /// Running adds nothing: the common case should not make every focus read a
    /// clause that never changes.
    func testRunningAddsNoStateClause() {
        let label = StatusItemAccessibility.label(unreadCount: 3, state: .running)

        XCTAssertEqual(label, "Backglance, 3 unread notifications")
    }

    /// Paused, degraded and stopped each get their own words. The icon changes
    /// too, but the icon is the one signal a screen reader user does not have.
    func testEveryNonRunningStateAppendsItsOwnClause() {
        let cases: [(TimelineCaptureState, String)] = [
            (.paused(until: nil), "capture paused"),
            (.paused(until: Date(timeIntervalSince1970: 1_700_000_000)), "capture paused"),
            (.noFullDiskAccess, "needs Full Disk Access"),
            (.degraded(message: "unknown store fingerprint"), "capture degraded"),
            (.stopped, "capture stopped"),
        ]

        for (state, expectedSuffix) in cases {
            let label = StatusItemAccessibility.label(unreadCount: 2, state: state)

            XCTAssertEqual(label, "Backglance, 2 unread notifications, \(expectedSuffix)")
        }
    }

    /// The state clause survives a zero count — a paused item with nothing
    /// unread is exactly the case where the state is the only news.
    func testStateClauseSurvivesAZeroCount() {
        let label = StatusItemAccessibility.label(unreadCount: 0, state: .paused(until: nil))

        XCTAssertEqual(label, "Backglance, no unread notifications, capture paused")
    }

    /// The capture layer's degraded sentence stays in the tooltip. Whatever it
    /// says, the spoken label is the same fixed clause.
    func testDegradedMessageDoesNotLeakIntoTheSpokenLabel() {
        let label = StatusItemAccessibility.label(
            unreadCount: 0,
            state: .degraded(message: "adapter v26 rejected the store fingerprint")
        )

        XCTAssertFalse(
            label.contains("adapter"),
            "Expected the degraded sentence to stay in the tooltip, got: \(label)"
        )
        XCTAssertEqual(label, "Backglance, no unread notifications, capture degraded")
    }

    // MARK: - Help

    /// The help text names the hotkey, which is the only way to reach the
    /// timeline without finding the menu bar item first.
    func testHelpNamesTheHotkey() {
        XCTAssertTrue(
            StatusItemAccessibility.help.contains("Control-Option-N"),
            "Expected the help text to name ⌃⌥N, got: \(StatusItemAccessibility.help)"
        )
    }
}
