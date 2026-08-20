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
        defaults: UserDefaults = .standard,
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
        // The hosts remember separately, and they start from different places:
        // the popover is for glancing, the window is for reading.
        viewMode = defaults.string(forKey: Self.viewModeKey(host))
            .flatMap(TimelineViewMode.init(rawValue:)) ?? host.defaultViewMode
        groupByApp = defaults.bool(forKey: Self.groupByAppKey(host))
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
    /// mode and grouping separately — glancing and reading are different jobs,
    /// and a setting that followed the user between them would be wrong in one
    /// of the two every time.
    public enum Host: String, Sendable {
        case popover
        case window

        // MARK: Internal

        /// What each host opens as before the user has said otherwise: the
        /// popover glances, so it starts compact; the window is where things
        /// are actually read.
        var defaultViewMode: TimelineViewMode {
            switch self {
            case .popover: .compact
            case .window: .detailed
            }
        }
    }

    /// The bundle identifier the preferences are filed under.
    ///
    /// Kept as documentation rather than used as a suite name: `.standard`
    /// *is* this suite for the app that owns the identifier, and asking
    /// `UserDefaults(suiteName:)` for your own bundle id returns nothing and
    /// logs "does not make sense and will not work" — which is exactly what it
    /// did before this was `.standard`. Tests pass their own throwaway suite.
    public static let defaultsSuite = "app.backglance.Backglance"

    /// Days, newest first, each already flattened into draw-order slots.
    public internal(set) var sections: [TimelineSection.Model] = []

    /// Unread, unmuted, delivered since the anchor — capped by the archive at
    /// ``BackglanceCore/Archive/unreadBadgeCap``, which the status item renders
    /// as "99+".
    public internal(set) var unreadBadgeCount = 0

    /// A one-sentence, content-free explanation of a failed read, for the banner.
    /// `nil` when the timeline is healthy.
    public internal(set) var loadError: String?

    /// Whether ``loadNextPage()`` has anything left to fetch.
    public internal(set) var hasMorePages = true

    /// What capture is doing, pushed in by the app shell. Only the empty state
    /// and the banner read it; the timeline itself renders the same either way.
    public var captureState: TimelineCaptureState = .running

    /// Compact or detailed rows, remembered per host.
    public var viewMode: TimelineViewMode = .compact {
        didSet {
            guard oldValue != viewMode else {
                return
            }
            defaults.set(viewMode.rawValue, forKey: Self.viewModeKey(host))
        }
    }

    /// The keyboard selection.
    public var selectedID: Int64? {
        didSet {
            guard oldValue != selectedID else {
                return
            }
            regroup()
        }
    }

    /// Whether days are sub-grouped by app, remembered per host.
    public var groupByApp = false {
        didSet {
            guard oldValue != groupByApp else {
                return
            }
            defaults.set(groupByApp, forKey: Self.groupByAppKey(host))
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

    /// Moves the keyboard selection by `delta` rows, skipping headers and the
    /// divider — they are not places a selection can rest.
    ///
    /// Selection stops at both ends rather than wrapping: a list that jumps
    /// from the oldest notification to the newest on one extra key press hides
    /// the fact that you reached the end.
    public func moveSelection(_ delta: Int) {
        let items = visibleItems
        guard !items.isEmpty else {
            return
        }
        guard let current = selectedID, let index = items.firstIndex(where: { $0.id == current }) else {
            selectedID = delta >= 0 ? items.first?.id : items.last?.id
            return
        }
        let next = min(max(index + delta, 0), items.count - 1)
        selectedID = items[next].id
    }

    /// Clears every app filter — what the "all filtered" empty state's button does.
    public func clearFilters() {
        appFilter = []
    }

    /// Re-subscribes after a read failure. The rows already on screen stay put
    /// while it retries: a stale timeline with a banner beats a blank one.
    public func retry() {
        loadError = nil
        startObserving()
    }

    // MARK: Internal

    /// When a surface was last open. Shared by both hosts on purpose: opening
    /// either one counts as having looked.
    static let lastSeenKey = "timeline.lastSeenAt"

    /// Rows per page, and the ceiling on rows held in memory (~1 MB).
    static let pageSize = Archive.timelinePageSize
    static let maxRows = 1_000

    // The store's own state. Internal rather than private because the store is
    // split across `TimelineStore+Grouping`, `+Pagination` and `+ReadState` —
    // one type, four files, so that each file is about one thing.

    let archive: Archive
    let triage: any TriageEvaluating
    let host: Host
    let defaults: UserDefaults
    let calendar: Calendar

    var rows: [ArchivedNotification] = []
    var apps: [Int64: AppRecord] = [:]
    var cursor: TimelineCursor?
    var unreadAnchor: UnixDate

    /// One live timer per visible row. Held so scrolling a row back off screen
    /// before it has been seen for a second cancels it — a row that flew past
    /// under the user's scroll was not read.
    @ObservationIgnored var visibilityTimers: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored var isLoadingPage = false

    static func viewModeKey(_ host: Host) -> String {
        "timeline.viewMode.\(host.rawValue)"
    }

    static func groupByAppKey(_ host: Host) -> String {
        "timeline.groupByApp.\(host.rawValue)"
    }

    /// A failed archive read is a banner, never a crash and never a modal — the
    /// timeline's job is to render *something* for every combination of archive
    /// health, capture status and permissions.
    static func message(for error: Error) -> String {
        (error as? ArchiveError)?.userMessage
            ?? ArchiveError.observationFailed(String(describing: type(of: error))).userMessage
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

    func cancelVisibilityTimers() {
        for timer in visibilityTimers.values {
            timer.cancel()
        }
        visibilityTimers.removeAll()
    }

    func startObserving() {
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

    // MARK: Private

    /// Only ever assigned on the main actor, and `@ObservationIgnored` because a
    /// view has no business redrawing when the subscription is replaced. The
    /// isolation opt-out is what lets `deinit` — which is not main-actor
    /// isolated — cancel it.
    @ObservationIgnored nonisolated(unsafe) private var observation: Task<Void, Never>?
}
