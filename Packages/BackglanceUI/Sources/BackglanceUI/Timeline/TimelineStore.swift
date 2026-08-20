import BackglanceCore
import Foundation
import Observation

// MARK: - TimelineStore

/// The timeline's state: the rows in memory, the sections built from them, and
/// the live subscription that keeps both current.
///
/// One instance serves both hosts. The popover and the window render the same
/// ``sections``; only their chrome differs. Every write the UI triggers — mark
/// read, pin, delete — goes to the archive and comes back through the
/// subscription, so no view ever mutates its own copy of a row and the two hosts
/// cannot drift apart.
///
/// The subscription itself lives in `BackglanceCore`
/// (``BackglanceCore/Archive/timelineSnapshots(unreadSince:pageSize:)``): this
/// package does not import GRDB, and the store is easier to reason about when
/// "the newest page changed" arrives as a value rather than as a query.
///
/// Memory is bounded at ``maxRows``. Scrolling far back drops the newest rows,
/// which the subscription refetches the moment the user scrolls up again — a
/// timeline that pages forever must not also grow forever.
///
/// See docs/features/TIMELINE.md#timelinestore.
@MainActor
@Observable
public final class TimelineStore {
    // MARK: Lifecycle

    public init(
        archive: Archive,
        triage: any TriageEvaluating = NoTriage(),
        host: Host = .popover,
        defaults: UserDefaults = UserDefaults(suiteName: TimelineStore.defaultsSuite) ?? .standard,
        calendar: Calendar = .current
    ) {
        self.archive = archive
        self.triage = triage
        self.host = host
        self.defaults = defaults
        self.calendar = calendar
        // A fresh install has no "last seen", which makes every archived
        // notification new — correct, and the same thing the first import means.
        unreadAnchor = UnixDate(Date(timeIntervalSince1970: defaults.double(forKey: Self.lastSeenKey)))
        startObserving()
    }

    deinit {
        // `nonisolated` on the property below is what makes this legal: deinit is not
        // main-actor isolated, and an observation that outlived its store would
        // hold the archive's reader open for a window nobody is looking at.
        observation?.cancel()
    }

    // MARK: Public

    /// Which surface this store is driving. The two hosts remember their view
    /// mode and grouping separately.
    public enum Host: String, Sendable {
        case popover
        case window
    }

    /// Where the per-host preferences and the unread anchor live. A named
    /// suite rather than `.standard` so a test can hand the store its own.
    public static let defaultsSuite = "app.backglance.Backglance"

    /// Days, newest first, each already flattened into draw-order slots.
    public private(set) var sections: [TimelineSection.Model] = []

    /// Unread, unmuted, delivered since the anchor — capped by the archive at
    /// ``BackglanceCore/Archive/unreadBadgeCap``, which the status item renders
    /// as "99+".
    public private(set) var unreadBadgeCount = 0

    /// A one-sentence, content-free explanation of a failed read, for the banner.
    /// `nil` when the timeline is healthy.
    public private(set) var loadError: String?

    /// Whether ``loadNextPage()`` has anything left to fetch.
    public private(set) var hasMorePages = true

    /// Compact or detailed rows. Persisted per host in Phase 2.3's view-mode task.
    public var viewMode: TimelineViewMode = .compact

    /// What capture is doing, pushed in by the app shell. Only the empty state
    /// and the banner read it; the timeline itself renders the same either way.
    public var captureState: TimelineCaptureState = .running

    /// The keyboard selection.
    public var selectedID: Int64? {
        didSet {
            guard oldValue != selectedID else {
                return
            }
            regroup()
        }
    }

    /// Whether days are sub-grouped by app.
    public var groupByApp = false {
        didSet {
            guard oldValue != groupByApp else {
                return
            }
            regroup()
        }
    }

    /// Bundle ids to show. Empty means "everything" — an empty set is not an
    /// empty timeline.
    public var appFilter: Set<String> = [] {
        didSet {
            guard oldValue != appFilter else {
                return
            }
            regroup()
        }
    }

    /// Which empty state applies when ``sections`` is empty.
    ///
    /// The distinction that matters is between "nothing was captured" and
    /// "nothing is shown": a filter that matches nothing is the user's own doing
    /// and needs a "Clear filters" button, not an explanation of Full Disk Access.
    public var emptyStateKind: EmptyStateKind {
        if !rows.isEmpty {
            return .allFiltered
        }
        switch captureState {
        case .noFullDiskAccess:
            return .noFullDiskAccess

        case .paused:
            return .paused

        case .running,
             .stopped,
             .degraded:
            return .nothingYet
        }
    }

    /// Rows currently held in memory, newest first — what ↑/↓ moves through.
    public var visibleItems: [TimelineItem] {
        sections.flatMap(\.items)
    }

    /// Snapshots the unread anchor just before a surface opens.
    ///
    /// Opening the timeline *is* "the user looked", but the divider they see
    /// has to reflect the moment before they clicked — so the anchor is
    /// resolved and frozen here, and only advanced when the surface closes.
    /// The anchor is the later of the two things that count as looking: the
    /// last time a surface was open, and the end of the last away session.
    public func surfaceWillOpen() {
        let sessionEnd = try? archive.lastAwaySessionEnd()
        if let sessionEnd, sessionEnd > unreadAnchor {
            unreadAnchor = sessionEnd
        }
        regroup()
    }

    /// Advances the anchor after a surface closes: everything up to now has
    /// been seen, so the badge resets and the next open starts a new divider.
    public func surfaceDidClose() {
        let now = Date()
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastSeenKey)
        unreadAnchor = UnixDate(now)
        unreadBadgeCount = 0
        cancelVisibilityTimers()
        // The badge query is defined by the anchor, so a moved anchor needs a
        // new subscription rather than a recount of the old one.
        startObserving()
    }

    /// Starts the "seen for a second" timer for a row that scrolled into view.
    ///
    /// A second is the threshold because anything shorter marks rows read that
    /// merely flew past under a flick scroll — the one failure mode that would
    /// make the badge untrustworthy.
    public func rowBecameVisible(_ id: Int64) {
        guard visibilityTimers[id] == nil else {
            return
        }
        visibilityTimers[id] = Task { [archive] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else {
                return
            }
            // A read flag that fails to persist is not worth a banner: the row
            // is still on screen, and the next pass tries again.
            _ = try? archive.markRead(id)
        }
    }

    /// Cancels that timer when the row scrolls away unseen.
    public func rowBecameHidden(_ id: Int64) {
        visibilityTimers.removeValue(forKey: id)?.cancel()
    }

    /// Opening a row reads it, immediately — no timer, no ambiguity.
    public func open(_ id: Int64) {
        selectedID = id
        _ = try? archive.markRead(id)
    }

    /// Marks everything in the archive read. One statement; the subscription
    /// echoes it back to every open surface.
    public func markAllRead() {
        do {
            _ = try archive.markAllRead()
        } catch {
            loadError = Self.message(for: error)
        }
    }

    /// Re-subscribes after a read failure. The rows already on screen stay put
    /// while it retries: a stale timeline with a banner beats a blank one.
    public func retry() {
        loadError = nil
        startObserving()
    }

    /// Appends the next page. Called by the scroll sentinel, and safe to call
    /// again while one is in flight — the second call returns immediately rather
    /// than fetching the same page twice.
    public func loadNextPage() async {
        guard hasMorePages, !isLoadingPage else {
            return
        }
        isLoadingPage = true
        defer { isLoadingPage = false }

        guard let after = cursor ?? rows.last.flatMap(TimelineCursor.init(row:)) else {
            hasMorePages = false
            return
        }

        do {
            // Bound outside the detached task: reading them inside would be a
            // hop back to the main actor for every page.
            let archive = archive
            let limit = Self.pageSize
            let page = try await Task.detached {
                try archive.timelinePage(after: after, limit: limit)
            }.value

            guard !page.isEmpty else {
                hasMorePages = false
                return
            }
            let known = Set(rows.compactMap(\.id))
            rows.append(contentsOf: page.filter { row in row.id.map { !known.contains($0) } ?? false })
            cursor = page.last.flatMap(TimelineCursor.init(row:))
            hasMorePages = page.count == Self.pageSize
            if rows.count > Self.maxRows {
                // Drop from the head, not the tail: the user is reading the
                // bottom of the list, and the subscription can refetch the top.
                rows.removeFirst(rows.count - Self.maxRows)
            }
            regroup()
        } catch {
            loadError = Self.message(for: error)
        }
    }

    // MARK: Internal

    /// When a surface was last open. Shared by both hosts on purpose: opening
    /// either one counts as having looked.
    static let lastSeenKey = "timeline.lastSeenAt"

    /// Rows per page, and the ceiling on rows held in memory (~1 MB).
    static let pageSize = Archive.timelinePageSize
    static let maxRows = 1_000

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
                mutedCount: muted.count
            )
        }
    }

    /// The newest page from the subscription replaces the head of `rows`; pages
    /// the user already scrolled to are kept.
    ///
    /// Splicing rather than replacing is what makes a live insert cheap: the new
    /// page covers everything down to its oldest row, so only rows strictly
    /// older than that survive from the previous state.
    func mergeFirstPage(_ page: [ArchivedNotification]) {
        guard let oldestNew = page.last, let oldestKey = TimelineCursor(row: oldestNew) else {
            rows = []
            cursor = nil
            hasMorePages = false
            return
        }

        let older = rows.drop { row in
            guard let key = TimelineCursor(row: row) else {
                return true
            }
            return (key.deliveredAt, key.id) >= (oldestKey.deliveredAt, oldestKey.id)
        }
        rows = page + Array(older)

        if rows.count > Self.maxRows {
            rows.removeLast(rows.count - Self.maxRows)
            cursor = rows.last.flatMap(TimelineCursor.init(row:))
            hasMorePages = true
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

    // MARK: Private

    private let archive: Archive
    private let triage: any TriageEvaluating
    private let host: Host
    private let defaults: UserDefaults
    private let calendar: Calendar

    private var rows: [ArchivedNotification] = []
    private var apps: [Int64: AppRecord] = [:]
    private var cursor: TimelineCursor?
    private var unreadAnchor: UnixDate

    /// One live timer per visible row. Held so scrolling a row back off screen
    /// before it has been seen for a second cancels it — a row that flew past
    /// under the user's scroll was not read.
    @ObservationIgnored private var visibilityTimers: [Int64: Task<Void, Never>] = [:]
    /// Only ever assigned on the main actor, and `@ObservationIgnored` because a
    /// view has no business redrawing when the subscription is replaced. The
    /// isolation opt-out is what lets `deinit` — which is not main-actor
    /// isolated — cancel it.
    @ObservationIgnored nonisolated(unsafe) private var observation: Task<Void, Never>?
    @ObservationIgnored private var isLoadingPage = false

    /// A failed archive read is a banner, never a crash and never a modal — the
    /// timeline's job is to render *something* for every combination of archive
    /// health, capture status and permissions.
    private static func message(for error: Error) -> String {
        (error as? ArchiveError)?.userMessage
            ?? ArchiveError.observationFailed(String(describing: type(of: error))).userMessage
    }

    private func cancelVisibilityTimers() {
        for timer in visibilityTimers.values {
            timer.cancel()
        }
        visibilityTimers.removeAll()
    }

    private func startObserving() {
        observation?.cancel()
        let stream = archive.timelineSnapshots(unreadSince: unreadAnchor, pageSize: Self.pageSize)
        observation = Task { [weak self] in
            do {
                for try await snapshot in stream {
                    guard let self, !Task.isCancelled else {
                        return
                    }
                    apps = snapshot.apps
                    mergeFirstPage(snapshot.rows)
                    unreadBadgeCount = snapshot.unreadCount
                    loadError = nil
                    regroup()
                }
            } catch {
                self?.loadError = Self.message(for: error)
            }
        }
    }
}
