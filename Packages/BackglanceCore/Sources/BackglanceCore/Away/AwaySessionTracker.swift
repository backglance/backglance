import Foundation

// MARK: - AwaySessionTracker

/// The state machine that decides when the user was away, and for how long.
///
/// Every detection source — the screen lock, sleep and wake, the Focus watcher, the
/// presentation heuristic, the manual toggle — is adapted into one ``Event`` and handed
/// to ``handle(_:)``. Nothing in here knows what a `DistributedNotificationCenter` is,
/// which is what makes the whole of the away model testable from a scripted stream and
/// a clock the test controls.
///
/// Causes overlap freely. A session begins when the *first* cause activates and ends
/// when the *last* one clears, so locking the lid during a Focus is one session, not
/// three. The end is not committed immediately: unlocking to glance at the screen and
/// re-locking within the merge gap continues the same session rather than splitting it.
///
/// The tracker writes nothing. Finished sessions go to the ``onEnd`` callback, whose
/// caller persists them through `Archive` — see
/// docs/features/MISSED_DIGEST.md#awaysessiontracker.
public actor AwaySessionTracker {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - clock: `SystemAwayClock()` in production.
    ///   - minDuration: read on every session end rather than captured once, so changing
    ///     the setting takes effect without rebuilding the tracker. Default 300 s.
    ///   - onEnd: called once per finished session, after the merge gap has elapsed.
    public init(
        clock: any AwayClock = SystemAwayClock(),
        minDuration: @escaping @Sendable () -> TimeInterval = { AwaySessionTracker.defaultMinDuration },
        onEnd: @escaping @Sendable (EndedSession) async -> Void
    ) {
        self.clock = clock
        self.minDuration = minDuration
        self.onEnd = onEnd
    }

    // MARK: Public

    /// One thing that happened, already stripped of its AppKit origins.
    public enum Event: Sendable, Equatable {
        case screenLocked
        case screenUnlocked
        case willSleep
        case didWake
        case focusChanged(active: Bool)
        case presentingChanged(active: Bool)
        case manualAway(active: Bool)
    }

    /// A session that has finished and been committed — the merge gap is over and it
    /// will not reopen.
    public struct EndedSession: Sendable, Equatable {
        // MARK: Lifecycle

        public init(
            session: AwaySession,
            reasons: Set<AwayReason>,
            isPartial: Bool,
            isReconstructed: Bool,
            meetsDigestThreshold: Bool
        ) {
            self.session = session
            self.reasons = reasons
            self.isPartial = isPartial
            self.isReconstructed = isReconstructed
            self.meetsDigestThreshold = meetsDigestThreshold
        }

        // MARK: Public

        /// The row to persist. `id` is `nil` — the caller inserts it. `reason` holds the
        /// primary cause only, which is all the column has room for.
        public let session: AwaySession

        /// Every cause seen during the session, including ones that came and went.
        public let reasons: Set<AwayReason>

        /// The app launched into an already-away Mac, so `startedAt` is the launch time
        /// rather than the real start. `DigestHeader` badges this.
        public let isPartial: Bool

        /// Rebuilt after the fact from store timestamps rather than observed live.
        /// Always `false` here; the reconstruction path sets it.
        public let isReconstructed: Bool

        /// Long enough to be worth a digest. Short sessions are still recorded — they
        /// make `is:missed` work — but produce no digest.
        public let meetsDigestThreshold: Bool

        public var duration: TimeInterval {
            guard let endedAt = session.endedAt else {
                return 0
            }
            return endedAt.date.timeIntervalSince(session.startedAt.date)
        }
    }

    /// Minimum session length that earns a digest, per
    /// docs/features/MISSED_DIGEST.md#session-merging-and-thresholds.
    public static let defaultMinDuration: TimeInterval = 300

    /// How long a cleared session waits before it is committed. A cause re-activating
    /// inside this window continues the session instead of starting a new one.
    public static let mergeGap: TimeInterval = 60

    /// Whether a session is currently open. For the Settings ▸ Status line and tests.
    public var isAway: Bool {
        switch state {
        case .idle: false
        case .away,
             .ending: true
        }
    }

    public func handle(_ event: Event) {
        let now = clock.now
        switch event {
        case .screenLocked: activate(.locked, at: now)
        case .screenUnlocked: deactivate(.locked, at: now)
        case .willSleep: activate(.asleep, at: now)
        case .didWake: deactivate(.asleep, at: now)
        case let .focusChanged(active): change(.focus, active: active, at: now)
        case let .presentingChanged(active): change(.presenting, active: active, at: now)
        case let .manualAway(active): change(.manual, active: active, at: now)
        }
    }

    /// Opens a session for a Mac that was *already* away when Backglance launched.
    ///
    /// The real start is unknowable — nothing was watching — so the session starts now
    /// and is flagged partial, which is the honest thing to show rather than a duration
    /// invented from a guess. A no-op if a session is already open.
    public func beginPartial(reason: AwayReason, at now: Date? = nil) {
        guard case .idle = state else {
            return
        }
        state = .away(Span(primary: reason, active: [reason], seen: [reason], since: now ?? clock.now, isPartial: true))
        Log.digest.info("Away session started partial, reason \(reason.rawValue)")
    }

    /// Commits any open session immediately, skipping the merge gap.
    ///
    /// For app termination, where waiting 60 s for a timer that will be torn down is not
    /// an option. A session still open (no cause has cleared) ends now.
    public func flush() async {
        mergeTask?.cancel()
        mergeTask = nil
        switch state {
        case .idle:
            return

        case let .away(span):
            state = .ending(span, candidateEnd: clock.now)
            await finalize()

        case .ending:
            await finalize()
        }
    }

    // MARK: Private

    /// One session in progress.
    private struct Span: Equatable {
        /// The first cause chronologically — what lands in `away_sessions.reason`.
        var primary: AwayReason
        /// Causes active right now. The session ends when this empties.
        var active: Set<AwayReason>
        /// Every cause seen, including ones that have already cleared.
        var seen: Set<AwayReason>
        var since: Date
        var isPartial: Bool
    }

    private enum State: Equatable {
        case idle
        /// At least one cause is active.
        case away(Span)
        /// Every cause cleared at `candidateEnd`; waiting out the merge gap.
        case ending(Span, candidateEnd: Date)
    }

    private let clock: any AwayClock
    private let minDuration: @Sendable () -> TimeInterval
    private let onEnd: @Sendable (EndedSession) async -> Void

    private var state: State = .idle
    private var mergeTask: Task<Void, Never>?

    private func change(_ reason: AwayReason, active: Bool, at now: Date) {
        if active {
            activate(reason, at: now)
        } else {
            deactivate(reason, at: now)
        }
    }

    private func activate(_ reason: AwayReason, at now: Date) {
        mergeTask?.cancel()
        mergeTask = nil

        switch state {
        case .idle:
            state = .away(Span(primary: reason, active: [reason], seen: [reason], since: now, isPartial: false))
            Log.digest.info("Away session started, reason \(reason.rawValue)")

        case var .away(span):
            span.active.insert(reason)
            span.seen.insert(reason)
            state = .away(span)

        case var .ending(span, _):
            // Re-activated inside the merge gap: the same session continues, and the
            // candidate end is discarded along with the cancelled timer.
            span.active.insert(reason)
            span.seen.insert(reason)
            state = .away(span)
            Log.digest.debug("Away session merged, reason \(reason.rawValue)")
        }
    }

    private func deactivate(_ reason: AwayReason, at now: Date) {
        // A deactivation while idle is a stray event — an unlock with no preceding lock
        // happens on login — and a deactivation while already ending changes nothing.
        guard case var .away(span) = state else {
            return
        }

        span.active.remove(reason)
        if span.active.isEmpty {
            state = .ending(span, candidateEnd: now)
            scheduleFinalize(clearedAt: now)
        } else {
            state = .away(span)
        }
    }

    /// Starts the merge-gap timer for a session whose last cause cleared at `clearedAt`.
    ///
    /// The deadline is computed here, synchronously, rather than inside the task: the gap
    /// runs from the moment the session cleared, not from whenever the executor gets
    /// around to the task. See the note on ``AwayClock/sleep(until:)``.
    private func scheduleFinalize(clearedAt: Date) {
        mergeTask?.cancel()
        let deadline = clearedAt.addingTimeInterval(Self.mergeGap)
        mergeTask = Task { [clock] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return // Cancelled by a re-activation: the session lives on.
            }
            await self.finalize()
        }
    }

    private func finalize() async {
        guard case let .ending(span, candidateEnd) = state else {
            return
        }
        state = .idle
        mergeTask = nil

        let session = AwaySession(
            id: nil,
            startedAt: UnixDate(span.since),
            endedAt: UnixDate(candidateEnd),
            reason: span.primary
        )
        let duration = candidateEnd.timeIntervalSince(span.since)
        let meets = duration >= minDuration()

        Log.digest.info(
            "Away session ended after \(Int(duration))s, causes \(span.seen.count), digest eligible \(meets)"
        )
        await onEnd(EndedSession(
            session: session,
            reasons: span.seen,
            isPartial: span.isPartial,
            isReconstructed: false,
            meetsDigestThreshold: meets
        ))
    }
}
