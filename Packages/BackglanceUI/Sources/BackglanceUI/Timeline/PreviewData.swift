import BackglanceCore
import Foundation

// MARK: - PreviewData

/// Synthetic sample values for `#Preview` blocks across this package.
///
/// Every string here is deliberately fabricated — "Fixture message 000042",
/// never anything that could be mistaken for a real notification. That mirrors
/// the rule for `Tests/Fixtures/SystemStore` (CLAUDE.md, Privacy Invariant #5):
/// previews render in Xcode canvases and screenshots people share, so the same
/// "nothing resembling real personal content, never a real verification code"
/// bar applies here even though this data never touches the archive.
///
/// Dates are computed relative to `Date()` rather than hard-coded, so a
/// preview taken today still reads as "5 minutes ago" / "Yesterday" next year.
public enum PreviewData {
    /// A handful of rows spanning today and yesterday — enough to preview a
    /// scrolled timeline without pulling in the archive.
    public static var items: [TimelineItem] {
        [
            item(
                id: 1,
                appName: "Fixture Mail",
                bundleID: "app.backglance.fixture.mail",
                title: "Deploy finished",
                body: "Fixture message 000041",
                minutesAgo: 5
            ),
            item(
                id: 2,
                appName: "Fixture Chat",
                bundleID: "app.backglance.fixture.chat",
                title: "Standup moved",
                body: "Fixture message 000042",
                minutesAgo: 42,
                isRead: true
            ),
            item(
                id: 3,
                appName: "Fixture Notes",
                bundleID: "app.backglance.fixture.notes",
                title: "Fixture reminder 000043",
                minutesAgo: 26 * 60,
                isRead: true,
                isPinned: true
            ),
            item(
                id: 4,
                appName: "Fixture Weather",
                bundleID: "app.backglance.fixture.weather",
                title: "Fixture message 000044",
                minutesAgo: 27 * 60 + 30,
                isRead: true
            ),
        ]
    }

    /// Two days' worth of sections: today carries the unread ``TimelineSection/Slot/divider``,
    /// yesterday carries a collapsed, muted ``TimelineSection/AppGroup`` — the two slot kinds
    /// `AppGroupHeader` and the divider view need to preview against.
    public static var sections: [TimelineSection.Model] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today

        let todaySlots: [TimelineSection.Slot] = [
            .divider,
            .row(items[0]),
            .row(items[1]),
        ]

        let mutedGroup = TimelineSection.AppGroup(
            id: "muted",
            name: String(localized: "Muted"),
            count: 3,
            isMuted: true,
            bundleID: nil
        )
        let mutedItems = (0 ..< 3).map { index in
            item(
                id: Int64(900 + index),
                appName: "Calendar",
                bundleID: "com.apple.iCal",
                title: "Fixture reminder \(String(format: "%06d", 900 + index))",
                minutesAgo: 1_500 + index * 5,
                isRead: true
            )
        }
        let yesterdaySlots: [TimelineSection.Slot] = [
            .row(items[2]),
            .row(items[3]),
            .appHeader(mutedGroup),
        ]

        return [
            TimelineSection.Model(id: today, title: DayTitle.string(for: today, now: Date()), slots: todaySlots),
            TimelineSection.Model(
                id: yesterday,
                title: DayTitle.string(for: yesterday, now: Date()),
                slots: yesterdaySlots,
                mutedItems: mutedItems
            ),
        ]
    }

    /// A synthetic archived row. `appId` is a fixed fixture id — previews
    /// never join against a real `apps` table, so the exact value only needs
    /// to be stable, not meaningful.
    public static func notification(
        id: Int64,
        title: String,
        body: String? = nil,
        minutesAgo: Int,
        isRead: Bool = false,
        isPinned: Bool = false
    ) -> ArchivedNotification {
        let deliveredAt = UnixDate(Date().addingTimeInterval(-Double(minutesAgo) * 60))
        return ArchivedNotification(
            id: id,
            uuid: "fixture-\(id)",
            appId: 1,
            title: title,
            body: body,
            deliveredAt: deliveredAt,
            capturedAt: deliveredAt,
            isRead: isRead,
            isPinned: isPinned
        )
    }

    /// Wraps ``notification(id:title:body:minutesAgo:isRead:isPinned:)`` with
    /// the app metadata `TimelineItem` needs, so a preview never has to build
    /// the two by hand and keep them in sync.
    public static func item(
        id: Int64,
        appName: String,
        bundleID: String?,
        title: String,
        body: String? = nil,
        minutesAgo: Int,
        isRead: Bool = false,
        isPinned: Bool = false,
        triage: Triage = .none,
        isSelected: Bool = false
    ) -> TimelineItem {
        TimelineItem(
            id: id,
            notification: notification(
                id: id,
                title: title,
                body: body,
                minutesAgo: minutesAgo,
                isRead: isRead,
                isPinned: isPinned
            ),
            appName: appName,
            bundleID: bundleID,
            triage: triage,
            isSelected: isSelected
        )
    }
}
