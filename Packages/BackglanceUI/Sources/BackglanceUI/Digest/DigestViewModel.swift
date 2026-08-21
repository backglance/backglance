import BackglanceCore
import Foundation
import Observation

// MARK: - DigestViewModel

/// Everything ``DigestView`` draws, and the three writes it can make.
///
/// The digest is a one-shot card, not a live surface: it summarises a window that has
/// already closed, so unlike ``TimelineStore`` there is no observation here. It loads
/// once, renders, and the only things that change afterwards are the two once-only
/// timestamps — `shown_at` and `dismissed_at` — plus "mark all read".
///
/// ``isPartial`` and ``isReconstructed`` are passed in rather than read back, because
/// they are not columns: they live on `AwaySessionTracker.EndedSession` and are gone
/// once the session is written (docs/features/MISSED_DIGEST.md#archive-tables-involved).
/// The build path knows them and hands them over; reopening an old digest from the
/// "Last digest" menu item does not, and renders without the badges rather than
/// inventing them.
///
/// See docs/features/MISSED_DIGEST.md#digestview.
@MainActor
@Observable
public final class DigestViewModel {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - session: the window this digest covers. `nil` renders the card without a
    ///     duration or a reason — worth showing, since the notifications are the point.
    ///   - isPartial: the app launched into an already-away Mac, so the session starts
    ///     at launch rather than at the real start.
    ///   - isReconstructed: rebuilt after the fact from store timestamps.
    ///   - now: injectable so a test can assert `shown_at` without racing the clock.
    public init(
        archive: Archive,
        digest: Digest,
        session: AwaySession?,
        isPartial: Bool = false,
        isReconstructed: Bool = false,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.archive = archive
        self.digest = digest
        self.session = session
        self.isPartial = isPartial
        self.isReconstructed = isReconstructed
        self.calendar = calendar
        self.now = now
    }

    // MARK: Public

    public let digest: Digest
    public let session: AwaySession?

    /// The app launched mid-session, so ``AwaySession/startedAt`` is the launch time.
    public let isPartial: Bool

    /// Rebuilt from store timestamps rather than observed live.
    public let isReconstructed: Bool

    /// Unmuted apps, in rank order.
    public private(set) var appSections: [DigestSection] = []

    /// Rows from muted apps, collapsed behind a disclosure. They are in the digest —
    /// muting de-prioritizes, it does not hide — just not in the way of the rest.
    public private(set) var mutedItems: [TimelineItem] = []

    /// Per local day, oldest first. Empty unless the session spans more than one day.
    public private(set) var dayCounts: [DigestDayCount] = []

    /// A one-sentence, content-free explanation of a failed read. `nil` when healthy.
    public private(set) var loadError: String?

    /// Set by ``dismiss()``. The host removes the card when this flips.
    public private(set) var isDismissed = false

    /// Fired by "Open timeline at this point", with the session to scroll to. `nil`
    /// leaves the button out, which is how a preview renders the card without a window.
    public var onOpenTimeline: ((AwaySession) -> Void)?

    /// Fired once the digest has been retired, so the host can take the card down.
    /// A callback rather than the host observing ``isDismissed``: the write has already
    /// happened by the time this runs, so there is no window in which the card is gone
    /// from the screen but still pending in the archive.
    public var onDismissed: (() -> Void)?

    public var mutedCount: Int {
        mutedItems.count
    }

    /// How many selected notifications did not fit under `DigestEngine.shownCap`.
    ///
    /// `item_count` counts the whole selection and survives retention pruning the items,
    /// so this is clamped at zero: after a prune the stored count is legitimately larger
    /// than what is left to draw, and "and −3 more" would be the wrong way to say so.
    public var overflowCount: Int {
        max(0, digest.itemCount - shownCount)
    }

    /// "You missed 12 notifications from 4 apps".
    ///
    /// The app count is over the rows the digest actually holds, which is all that is
    /// knowable: past the 50-row cap the tail was never written to `digest_items`.
    public var headline: String {
        let apps = appCount
        return String(
            localized: "You missed \(digest.itemCount) notifications from \(apps) apps",
            comment: "Digest headline. Both counts are pluralized by the string catalog."
        )
    }

    /// "while locked · 47 min · ended 09:12". Each part is dropped when it is unknown
    /// rather than filled in with a placeholder.
    public var subheadline: String {
        var parts: [String] = []
        if let session {
            parts.append(Self.whileLabel(for: session.reason))
        }
        if let duration = durationText {
            parts.append(duration)
        }
        if let endedAt = session?.endedAt {
            parts.append(String(
                localized: "ended \(endedAt.date.formatted(.dateTime.hour().minute()))",
                comment: "Digest subheadline: when the away session ended"
            ))
        }
        return parts.joined(separator: " · ")
    }

    /// The SF Symbol for the session's primary reason.
    public var primaryReasonSymbol: String {
        (session?.reason).map(Self.symbol(for:)) ?? "clock"
    }

    /// Loads the digest's rows and groups them. Safe to call again; it replaces state
    /// rather than appending to it.
    public func load() {
        do {
            guard let digestID = digest.id else {
                return
            }
            let rows = try archive.digestNotifications(digestID: digestID)
            let apps = try archive.appsByID()
            group(rows, apps: apps)
            dayCounts = try loadDayCounts()
            loadError = nil
        } catch {
            // The card is a summary of rows that are safely archived either way, so a
            // failed read is a line of text on the card, never a dialog.
            loadError = (error as? ArchiveError)?.userMessage
                ?? String(localized: "Backglance could not read this digest.")
            Log.digest.error("Digest load failed: \(ArchiveError.detail(from: error))")
        }
    }

    /// Stamps `shown_at`, once. Called from the card's `.task`, so it runs on every
    /// appearance and the archive's `IS NULL` predicate is what makes it once-only.
    public func markShown() {
        guard let digestID = digest.id else {
            return
        }
        do {
            if try archive.markDigestShown(digestID, at: now()) {
                Log.digest.info("Digest \(digestID) shown")
            }
        } catch {
            Log.digest.error("Digest shown stamp failed: \(ArchiveError.detail(from: error))")
        }
    }

    /// Retires the digest and removes the card. The notifications stay in the archive
    /// and stay findable — only the summary goes away, and it never comes back.
    public func dismiss() {
        isDismissed = true
        defer { onDismissed?() }
        guard let digestID = digest.id else {
            return
        }
        do {
            try archive.dismissDigest(digestID, at: now())
            Log.digest.info("Digest \(digestID) dismissed")
        } catch {
            // The card still goes away. Leaving it up because the write failed would
            // mean the one click the contract promises did nothing.
            Log.digest.error("Digest dismiss failed: \(ArchiveError.detail(from: error))")
        }
    }

    /// Marks this digest's notifications read — these, not the whole timeline.
    public func markAllRead() {
        let ids = (appSections.flatMap(\.items) + mutedItems).map(\.id)
        do {
            let changed = try archive.markRead(ids: ids)
            Log.digest.info("Digest mark-all-read changed \(changed) row(s)")
        } catch {
            Log.digest.error("Digest mark-all-read failed: \(ArchiveError.detail(from: error))")
        }
    }

    public func openTimelineAtSession() {
        guard let session else {
            return
        }
        onOpenTimeline?(session)
    }

    // MARK: Internal

    /// "while locked" — the reason as the subheadline says it.
    static func whileLabel(for reason: AwayReason) -> String {
        switch reason {
        case .locked: String(localized: "while locked")
        case .asleep: String(localized: "while asleep")
        case .focus: String(localized: "while in a Focus")
        case .presenting: String(localized: "while presenting")
        case .manual: String(localized: "while away")
        }
    }

    /// The glyph per reason — docs/features/MISSED_DIGEST.md#digestheader lists them as
    /// emoji (🔒 / 😴 / 🌙 / 📽 / ✋); these are the SF Symbols that say the same thing
    /// and inherit the label's weight, colour and Dynamic Type size.
    static func symbol(for reason: AwayReason) -> String {
        switch reason {
        case .locked: "lock.fill"
        case .asleep: "powersleep"
        case .focus: "moon.fill"
        case .presenting: "rectangle.on.rectangle"
        case .manual: "hand.raised.fill"
        }
    }

    // MARK: Private

    private let archive: Archive
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    private var shownCount: Int {
        appSections.reduce(0) { $0 + $1.items.count } + mutedItems.count
    }

    private var appCount: Int {
        appSections.count + (mutedItems.isEmpty ? 0 : Set(mutedItems.map(\.appName)).count)
    }

    /// "47 min", or "2 h 05 min" once an hour has passed. Clamped at zero: a backwards
    /// clock correction mid-session can end one before it started
    /// (docs/features/MISSED_DIGEST.md#edge-cases-and-error-handling).
    private var durationText: String? {
        guard let session, let endedAt = session.endedAt else {
            return nil
        }
        let seconds = max(0, endedAt.date.timeIntervalSince(session.startedAt.date))
        let allowed: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 3_600 ? [.hours, .minutes] : [.minutes]
        return Duration.seconds(seconds).formatted(.units(allowed: allowed, width: .abbreviated))
    }

    /// Groups by app, keeping `DigestEngine`'s rank: an app takes the position of its
    /// best-ranked row, and its rows stay in the order they were ranked.
    private func group(_ rows: [ArchivedNotification], apps: [Int64: AppRecord]) {
        var order: [String] = []
        var grouped: [String: [TimelineItem]] = [:]
        var muted: [TimelineItem] = []

        for row in rows {
            guard let item = TimelineItem(row: row, apps: apps) else {
                continue
            }
            if apps[row.appId]?.isMuted == true {
                muted.append(item)
                continue
            }
            let key = item.bundleID ?? item.appName
            if grouped[key] == nil {
                order.append(key)
            }
            grouped[key, default: []].append(item)
        }

        appSections = order.compactMap { key in
            guard let items = grouped[key], let first = items.first else {
                return nil
            }
            return DigestSection(id: key, appName: first.appName, bundleID: first.bundleID, items: items)
        }
        mutedItems = muted
    }

    /// Per-day counts, but only for a session that actually spans days. A single-day
    /// session's breakdown would just repeat the headline.
    private func loadDayCounts() throws -> [DigestDayCount] {
        guard let sessionID = session?.id,
              let session,
              let endedAt = session.endedAt,
              !calendar.isDate(session.startedAt.date, inSameDayAs: endedAt.date)
        else {
            return []
        }
        let dates = try archive.deliveryDates(inAwaySession: sessionID)
        let counted = Dictionary(grouping: dates, by: calendar.startOfDay(for:)).mapValues(\.count)
        return counted.keys.sorted().map { DigestDayCount(id: $0, count: counted[$0] ?? 0) }
    }
}
