import BackglanceCore
import BackglanceTestSupport
@testable import BackglanceUI
import Foundation

/// Synthetic timeline items for the grouping and store suites.
///
/// Everything here is generated: titles are numbered fixtures, app names are
/// Apple's own published bundle identifiers, and no value resembles real
/// notification content — the same rule the store fixtures follow.
enum TimelineFixtures {
    /// A calendar pinned to Istanbul so a day boundary assertion does not depend
    /// on where the machine running the tests happens to be.
    static var istanbul: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul") ?? .gmt
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    /// One item, `secondsAgo` before `reference`.
    static func item(
        id: Int64,
        secondsAgo: TimeInterval,
        reference: Date = Stubs.epoch,
        appName: String = "Slack",
        bundleID: String = Stubs.BundleID.slack,
        isPinned: Bool = false,
        isRead: Bool = false,
        triage: Triage = .none
    ) -> TimelineItem {
        let delivered = reference.addingTimeInterval(-secondsAgo)
        let notification = ArchivedNotification(
            id: id,
            uuid: "FIXTURE-\(String(format: "%08d", id))",
            appId: 1,
            title: "Fixture message \(String(format: "%06d", id))",
            deliveredAt: UnixDate(delivered),
            capturedAt: UnixDate(delivered),
            isRead: isRead,
            isPinned: isPinned
        )
        return TimelineItem(
            id: id,
            notification: notification,
            appName: appName,
            bundleID: bundleID,
            triage: triage
        )
    }

    /// `newer` items delivered after `anchor` and `older` delivered before it,
    /// newest first — the shape the unread divider is placed into.
    static func items(around anchor: UnixDate, newer: Int, older: Int) -> [TimelineItem] {
        var items: [TimelineItem] = []
        for index in 0 ..< newer {
            items.append(item(
                id: Int64(100 + index),
                secondsAgo: TimeInterval(-(newer - index) * 10),
                reference: anchor.date
            ))
        }
        for index in 0 ..< older {
            items.append(item(
                id: Int64(200 + index),
                secondsAgo: TimeInterval((index + 1) * 10),
                reference: anchor.date
            ))
        }
        return items
    }
}
