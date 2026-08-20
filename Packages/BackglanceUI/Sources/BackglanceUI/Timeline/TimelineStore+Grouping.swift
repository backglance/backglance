import BackglanceCore
import Foundation

// MARK: - Grouping

/// Turning rows into days: the pure half of the store.
///
/// Kept apart from the store's state so it reads as what it is — a function
/// from items to sections, testable without an archive, a subscription or a
/// main actor's worth of ceremony. See docs/features/TIMELINE.md#grouping.
extension TimelineStore {
    /// Turns rows into days: the pure half of the store, so grouping, pinning,
    /// muting and divider placement are all testable without an archive.
    ///
    /// - Parameters:
    ///   - items: rows for display, newest first.
    ///   - groupByApp: whether to emit an app header per run of rows in a day.
    ///   - anchor: the moment the user last looked; the divider goes before the
    ///     first row at or older than it.
    ///   - calendar: decides where days begin.
    static func buildSections(
        items: [TimelineItem],
        groupByApp: Bool,
        anchor: UnixDate,
        calendar: Calendar,
        now: Date = .now
    ) -> [TimelineSection.Model] {
        let byDay = Dictionary(grouping: items) { item in
            calendar.startOfDay(for: item.notification.deliveredAt.date)
        }

        return byDay.keys.sorted(by: >).map { day in
            let dayItems = byDay[day] ?? []
            // Pinned first — the user's own pin, then a VIP rule's — and stable
            // (newest-first) within each group.
            let pinned = dayItems.filter(\.isPinned)
            let unpinned = dayItems.filter { !$0.isPinned }
            let muted = unpinned.filter(\.triage.muted)
            let normal = pinned + unpinned.filter { !$0.triage.muted }

            var slots: [TimelineSection.Slot] = []
            var dividerPlaced = false

            // The divider only earns its place between something new and
            // something old: if the whole day is new, or none of it is, it would
            // sit at an edge and mean nothing.
            let hasNewer = normal.contains { $0.notification.deliveredAt > anchor }
            let hasOlder = normal.contains { $0.notification.deliveredAt <= anchor }

            func emit(_ item: TimelineItem) {
                if !dividerPlaced, hasNewer, hasOlder, item.notification.deliveredAt <= anchor {
                    slots.append(.divider)
                    dividerPlaced = true
                }
                slots.append(.row(item))
            }

            if groupByApp {
                let groups = Dictionary(grouping: normal, by: \.appName).sorted { $0.key < $1.key }
                for (name, groupItems) in groups {
                    slots.append(.appHeader(.init(
                        id: groupItems.first?.bundleID ?? name,
                        name: name,
                        count: groupItems.count,
                        bundleID: groupItems.first?.bundleID
                    )))
                    groupItems.forEach(emit)
                }
            } else {
                normal.forEach(emit)
            }

            if !muted.isEmpty {
                // Collapsed by default: the header is the whole group until the
                // user expands it, so no muted rows are emitted here.
                // The name carries no count: `AppGroupHeader` renders name and
                // count separately, so baking "(n)" in here would print it twice.
                slots.append(.appHeader(.init(
                    id: "muted",
                    name: String(localized: "Muted"),
                    count: muted.count,
                    isMuted: true
                )))
            }

            return TimelineSection.Model(
                id: day,
                title: DayTitle.string(for: day, calendar: calendar, now: now),
                slots: slots,
                mutedItems: muted
            )
        }
    }

    /// Rebuilds ``sections`` from the rows in memory. Pure, synchronous and
    /// bounded by ``maxRows``, so it runs on the main actor without jank.
    func regroup() {
        var visible = rows.filter { !$0.isDeleted }
        if !appFilter.isEmpty {
            visible = visible.filter { row in
                apps[row.appId].map { appFilter.contains($0.bundleId) } ?? false
            }
        }

        let items = visible.compactMap { row in
            TimelineItem(
                row: row,
                apps: apps,
                triage: triage.evaluate(row),
                isSelected: row.id == selectedID
            )
        }

        sections = Self.buildSections(
            items: items,
            groupByApp: groupByApp,
            anchor: unreadAnchor,
            calendar: calendar
        )
    }
}
