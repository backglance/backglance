import BackglanceCore
import BackglanceTestSupport
@testable import BackglanceUI
import Foundation
import XCTest

/// Unit coverage for the pure accessibility-composition helpers on
/// `NotificationRow` — docs/reference/ACCESSIBILITY.md#timeline-rows.
///
/// These are not XCUITests: nothing here drives real VoiceOver, and nothing
/// in `BackglanceUI` should have to launch one to be trustworthy (see this
/// package's own dependency-direction note in `AppIconView.swift`). What
/// they pin down instead is the *string contract* the view's
/// `.accessibilityLabel` and `.accessibilityValue` modifiers are built
/// from — order, redaction, and state composition — so a future refactor of
/// the row's layout cannot silently reorder or drop a field a screen reader
/// user relies on.
final class AccessibilityTests: XCTestCase {
    // MARK: Internal

    // MARK: - Label order

    /// "App, title, body, time" — the fixed swipe order from
    /// docs/reference/ACCESSIBILITY.md#timeline-rows.
    func testLabelOrderIsAppTitleBodyTime() {
        let item = makeItem(title: "Deploy finished", body: "main is green")

        let parts = NotificationRow.accessibilityLabelParts(for: item)

        XCTAssertEqual(parts, [
            item.appName,
            "Deploy finished",
            "main is green",
            item.notification.deliveredAt.date.formatted(.dateTime.hour().minute()),
        ])
    }

    /// A body-only row (no title) still reads app → body → time, never a
    /// blank slot where the title would have gone.
    func testEmptyTitleStillProducesASensibleLabel() {
        let item = makeItem(title: nil, body: "main is green")

        let parts = NotificationRow.accessibilityLabelParts(for: item)

        XCTAssertEqual(parts, [
            item.appName,
            "main is green",
            item.notification.deliveredAt.date.formatted(.dateTime.hour().minute()),
        ])
    }

    /// Title and body both absent — the label degrades to app and time, and
    /// still joins into something a screen reader can say, never an empty part.
    func testEmptyTitleAndBodyStillProducesASensibleLabel() {
        let item = makeItem(title: nil, body: nil)

        let parts = NotificationRow.accessibilityLabelParts(for: item)

        XCTAssertEqual(parts, [
            item.appName,
            item.notification.deliveredAt.date.formatted(.dateTime.hour().minute()),
        ])
        XCTAssertFalse(parts.contains(""), "no field is ever appended empty")
    }

    // MARK: - Redaction

    /// `OTPRedactor` already overwrote `body` with a placeholder before this
    /// row ever reached the archive (see `PRIVACY_CONTROLS.md`) — this test
    /// uses that same placeholder, `[code redacted]`, as the stored body, and
    /// checks the label speaks the friendlier "code redacted" instead of
    /// reading the placeholder text aloud.
    func testARedactedRowSaysCodeRedactedAndNeverSpeaksTheStoredBody() {
        let item = makeItem(title: "Verification code", body: "[code redacted]", redaction: .otp)

        let parts = NotificationRow.accessibilityLabelParts(for: item)

        XCTAssertTrue(parts.contains("code redacted"))
        XCTAssertFalse(parts.contains("[code redacted]"), "the stored placeholder is never spoken verbatim")
        XCTAssertFalse(parts.contains { $0.contains("[code redacted]") })
    }

    /// A redacted row with no title at all: the label still substitutes
    /// "code redacted" for the missing body slot rather than skipping it,
    /// so a caller cannot tell from the label alone that the body was empty
    /// versus redacted.
    func testARedactedRowWithNoTitleStillSpeaksCodeRedacted() {
        let item = makeItem(title: nil, body: "[code redacted]", redaction: .otp)

        let parts = NotificationRow.accessibilityLabelParts(for: item)

        XCTAssertEqual(parts.count, 3, "app, \"code redacted\", time")
        XCTAssertEqual(parts[1], "code redacted")
    }

    // MARK: - Value / state

    /// Nothing to say — read, unpinned, unredacted — collapses to "read"
    /// rather than an empty value VoiceOver would announce as silence.
    func testValueIsReadWhenThereIsNothingToSay() {
        let item = makeItem(isRead: true)

        XCTAssertEqual(NotificationRow.accessibilityValueText(for: item), "read")
    }

    func testValueAnnouncesUnread() {
        let item = makeItem(isRead: false)

        XCTAssertEqual(NotificationRow.accessibilityValueText(for: item), "unread")
    }

    func testValueCombinesUnreadAndPinned() {
        let item = makeItem(isRead: false, isPinned: true)

        XCTAssertEqual(NotificationRow.accessibilityValueText(for: item), "unread, pinned")
    }

    func testValueCombinesUnreadPinnedAndRedacted() {
        let item = makeItem(redaction: .otp, isRead: false, isPinned: true)

        XCTAssertEqual(NotificationRow.accessibilityValueText(for: item), "unread, pinned, redacted")
    }

    /// A read, pinned row keeps "pinned" but drops "unread" — the value
    /// tracks each state independently rather than as one fixed template.
    func testAReadPinnedRowOmitsUnreadButKeepsPinned() {
        let item = makeItem(isRead: true, isPinned: true)

        XCTAssertEqual(NotificationRow.accessibilityValueText(for: item), "pinned")
    }

    /// A VIP rule pins exactly like the manual toggle does (one code path,
    /// per docs/reference/ACCESSIBILITY.md and `TimelineItem.isPinned`) — the
    /// value composition reads that merged flag, not the manual one alone.
    func testValueHonoursRuleDerivedPinningAsWellAsTheManualToggle() {
        let item = makeItem(isRead: true, isPinned: false, triage: Triage(pinned: true))

        XCTAssertEqual(NotificationRow.accessibilityValueText(for: item), "pinned")
    }

    func testValueAnnouncesRedactedAloneWhenReadAndUnpinned() {
        let item = makeItem(redaction: .otp, isRead: true, isPinned: false)

        XCTAssertEqual(NotificationRow.accessibilityValueText(for: item), "redacted")
    }

    // MARK: Private

    /// A synthetic row built directly (not through `PreviewData`, which fixes
    /// its own title/body/redaction combinations) so each test can name
    /// exactly the fields it is asserting on. All text is fabricated fixture
    /// content, per CLAUDE.md's Privacy Invariant #5.
    private func makeItem(
        title: String? = "Fixture title",
        body: String? = nil,
        redaction: ArchivedNotification.Redaction = .none,
        isRead: Bool = false,
        isPinned: Bool = false,
        triage: Triage = .none
    ) -> TimelineItem {
        let deliveredAt = UnixDate(Stubs.epoch)
        let notification = ArchivedNotification(
            uuid: "FIXTURE-ACCESSIBILITY",
            appId: 1,
            title: title,
            body: body,
            deliveredAt: deliveredAt,
            capturedAt: deliveredAt,
            redaction: redaction,
            isRead: isRead,
            isPinned: isPinned
        )
        return TimelineItem(id: 1, notification: notification, appName: "Fixture Chat", triage: triage)
    }
}
