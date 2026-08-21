import Foundation
import GRDB

// MARK: - DigestEngine

/// Builds the "what did I miss" summary for one finished away session.
///
/// Selection uses two independent signals, because either alone would lie. The away
/// window catches what arrived while the user was gone; `presented = 0` catches what the
/// system chose not to show — a Focus swallowing a banner is invisible to lock and sleep
/// detection, and the store records it either way. The `presented` clause is widened by
/// ``skewWindow`` because `usernoted`'s timestamps and ours are not the same clock.
///
/// One digest per session, enforced inside the transaction rather than by a caller
/// remembering to check: wake and unlock racing produces two session-end events often
/// enough that a second build is an ordinary event, not a bug.
///
/// See docs/features/MISSED_DIGEST.md#business-logic-digestengine.
public struct DigestEngine: Sendable {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - triage: the rules seam. `NoTriage()` until `RulesEngine` ships in a later
    ///     milestone, which is behaviourally identical to an empty rule set — so the
    ///     ranking below is written against the question, not the answer.
    ///   - now: injectable so a test can assert `created_at` without racing the clock.
    public init(
        archive: Archive,
        triage: any TriageEvaluating = NoTriage(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.archive = archive
        self.triage = triage
        self.now = now
    }

    // MARK: Public

    public enum DigestError: Error, Equatable {
        /// The session was never inserted, or is still open. Neither can be summarised.
        case sessionNotPersisted

        /// This session already has a digest. Expected, not exceptional — see the note
        /// on racing session-end events above.
        case alreadyBuilt(digestID: Int64)

        // MARK: Public

        /// Safe for the file log. Identifiers and nothing else.
        public var logDescription: String {
            switch self {
            case .sessionNotPersisted: "away session not persisted"
            case let .alreadyBuilt(digestID): "digest \(digestID) already built"
            }
        }
    }

    /// How many items the digest shows before collapsing the rest into "and *n* more".
    public static let shownCap = 50

    /// How far outside the session a `presented = 0` record still counts, absorbing clock
    /// skew between `usernoted`'s timestamps and ours.
    public static let skewWindow: TimeInterval = 120

    /// Builds and persists the digest for a finished, persisted away session.
    ///
    /// - Returns: `nil` when the session yields no notifications. A digest with nothing in
    ///   it is not a quiet digest, it is an interruption that says "nothing happened", so
    ///   no row is written at all.
    /// - Throws: ``DigestError/alreadyBuilt(digestID:)`` if one exists — callers swallow
    ///   it — or ``ArchiveError/writeFailed(table:underlying:)``.
    @discardableResult
    public func build(for session: AwaySession) throws -> Digest? {
        guard let sessionID = session.id, let endedAt = session.endedAt else {
            throw DigestError.sessionNotPersisted
        }

        do {
            return try archive.pool.write { db in
                if let existing = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM digests WHERE away_session_id = ?",
                    arguments: [sessionID]
                ) {
                    throw DigestError.alreadyBuilt(digestID: existing)
                }

                let selected = try select(db, from: session.startedAt.date, to: endedAt.date)
                guard !selected.isEmpty else {
                    Log.digest.info("Away session \(sessionID) had no notifications, no digest built")
                    return nil
                }

                let ranked = try rank(selected, in: db)
                let digest = try persist(ranked, sessionID: sessionID, in: db)
                Log.digest.info(
                    "Digest built for session \(sessionID): \(ranked.count) item(s), "
                        + "\(min(ranked.count, Self.shownCap)) shown"
                )
                return digest
            }
        } catch let error as DigestError {
            throw error
        } catch {
            throw ArchiveError.writeFailed(
                table: Digest.databaseTableName,
                underlying: ArchiveError.detail(from: error)
            )
        }
    }

    // MARK: Private

    /// One notification with its sort key already computed, so triage is evaluated once
    /// per item rather than once per comparison.
    private struct Ranked {
        let notification: ArchivedNotification
        let isVIP: Bool
        let isMuted: Bool
    }

    private let archive: Archive
    private let triage: any TriageEvaluating
    private let now: @Sendable () -> Date

    /// Everything that belongs in this session's digest.
    ///
    /// Excluded apps are checked here as well as at capture time. They are never stored in
    /// the first place, so this is belt and braces — but an exclusion added *after* a
    /// notification was captured is exactly the case where the row exists and must not
    /// resurface in a summary.
    ///
    /// A notification already claimed by another digest is skipped: overlapping windows
    /// must not show the same item twice.
    private func select(_ db: Database, from start: Date, to end: Date) throws -> [ArchivedNotification] {
        try ArchivedNotification.fetchAll(
            db,
            sql: """
            SELECT n.* FROM notifications n
            JOIN apps a ON a.id = n.app_id
            WHERE n.is_deleted = 0
              AND a.is_excluded = 0
              AND n.id NOT IN (SELECT notification_id FROM digest_items)
              AND ( (n.delivered_at >= ? AND n.delivered_at <= ?)
                 OR (n.presented = 0 AND n.delivered_at >= ? AND n.delivered_at <= ?) )
            ORDER BY n.delivered_at DESC
            """,
            arguments: [
                start.timeIntervalSince1970,
                end.timeIntervalSince1970,
                start.timeIntervalSince1970 - Self.skewWindow,
                end.timeIntervalSince1970 + Self.skewWindow,
            ]
        )
    }

    /// Orders the digest: what the rules called important first, muted apps last, and
    /// newest first within each band.
    ///
    /// Sorting by a key computed up front rather than inside the comparator — evaluating
    /// triage on every comparison would call the rules engine O(n log n) times for a
    /// value that does not change.
    private func rank(_ notifications: [ArchivedNotification], in db: Database) throws -> [ArchivedNotification] {
        let mutedAppIDs = try Set(Int64.fetchAll(db, sql: "SELECT id FROM apps WHERE is_muted = 1"))

        let keyed = notifications.map { notification in
            let triage = triage.evaluate(notification)
            return Ranked(
                notification: notification,
                isVIP: triage.highlight != nil || triage.pinned,
                isMuted: mutedAppIDs.contains(notification.appId)
            )
        }

        return keyed.sorted { lhs, rhs in
            if lhs.isVIP != rhs.isVIP {
                return lhs.isVIP
            }
            if lhs.isMuted != rhs.isMuted {
                return rhs.isMuted
            }
            return lhs.notification.deliveredAt > rhs.notification.deliveredAt
        }
        .map(\.notification)
    }

    /// Writes the digest, its shown items, and the session link — all inside the caller's
    /// transaction, so a failure leaves no half-built digest behind.
    private func persist(
        _ ranked: [ArchivedNotification],
        sessionID: Int64,
        in db: Database
    ) throws -> Digest {
        // `itemCount` counts everything selected, not the capped 50: it is the headline
        // number ("you missed 63"), and it has to survive retention pruning the items.
        var digest = Digest(
            awaySessionId: sessionID,
            createdAt: UnixDate(now()),
            itemCount: ranked.count
        )
        try digest.insert(db)
        guard let digestID = digest.id else {
            throw DigestError.sessionNotPersisted
        }

        for (rank, notification) in ranked.prefix(Self.shownCap).enumerated() {
            guard let notificationID = notification.id else {
                continue
            }
            var item = DigestItem(digestId: digestID, notificationId: notificationID, rank: rank)
            try item.insert(db)
        }

        // Every selected notification, not just the shown ones, so `is:missed` and "open
        // the timeline here" cover the tail too. Most are already linked — the session
        // claims its window when it is recorded — but the `presented = 0` clause reaches
        // ± 2 min outside it, and those stragglers are claimed here. Only rows with no
        // session yet, so this never moves one between sessions.
        let unclaimed = ranked.filter { $0.awaySessionId == nil }.compactMap(\.id)
        if !unclaimed.isEmpty {
            let placeholders = unclaimed.map { _ in "?" }.joined(separator: ",")
            try db.execute(
                sql: """
                UPDATE notifications SET away_session_id = ?
                WHERE away_session_id IS NULL AND id IN (\(placeholders))
                """,
                arguments: StatementArguments([sessionID] + unclaimed)
            )
        }

        return digest
    }
}
