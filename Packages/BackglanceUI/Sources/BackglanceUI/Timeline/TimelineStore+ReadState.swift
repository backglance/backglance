import BackglanceCore
import Foundation

// MARK: - Read state and the unread anchor

/// What "new" means, and when a row stops being unread.
///
/// Both halves are here because they are the same question asked twice: the
/// anchor decides which rows the badge counts and where the divider goes, and
/// the visibility timer decides when a row leaves that set. See
/// docs/features/TIMELINE.md#read-state-and-the-unread-badge.
public extension TimelineStore {
    /// Snapshots the unread anchor just before a surface opens.
    ///
    /// Opening the timeline *is* "the user looked", but the divider they see
    /// has to reflect the moment before they clicked — so the anchor is
    /// resolved and frozen here, and only advanced when the surface closes.
    /// The anchor is the later of the two things that count as looking: the
    /// last time a surface was open, and the end of the last away session.
    func surfaceWillOpen() {
        let sessionEnd = try? archive.lastAwaySessionEnd()
        if let sessionEnd, sessionEnd > unreadAnchor {
            unreadAnchor = sessionEnd
        }
        regroup()
    }

    /// Advances the anchor after a surface closes: everything up to now has
    /// been seen, so the badge resets and the next open starts a new divider.
    func surfaceDidClose() {
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
    func rowBecameVisible(_ id: Int64) {
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
    func rowBecameHidden(_ id: Int64) {
        visibilityTimers.removeValue(forKey: id)?.cancel()
    }

    /// Opening a row reads it, immediately — no timer, no ambiguity.
    func open(_ id: Int64) {
        selectedID = id
        _ = try? archive.markRead(id)
    }

    /// Marks everything in the archive read. One statement; the subscription
    /// echoes it back to every open surface.
    func markAllRead() {
        do {
            _ = try archive.markAllRead()
        } catch {
            loadError = Self.message(for: error)
        }
    }
}
