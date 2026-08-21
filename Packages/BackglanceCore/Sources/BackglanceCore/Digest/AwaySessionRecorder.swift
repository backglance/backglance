import Foundation

// MARK: - AwaySessionRecorder

/// What happens when an away session finishes: record it, link what arrived during it, and
/// build a digest if the user's settings want one.
///
/// The three steps are one type because they are one decision with one ordering, and
/// because that ordering has a rule in it that is easy to get backwards. Linking happens
/// when the session is **recorded**, not when a digest is built: sessions under the
/// threshold produce no digest, and the whole reason those rows are kept is that they are
/// still worth searching. Linking at build time would leave exactly those sessions
/// unlinked and quietly make `is:missed` lie
/// (docs/features/MISSED_DIGEST.md#archive-tables-involved).
///
/// It lives in `BackglanceCore` rather than in the app delegate that calls it so the whole
/// chain — tracker event to digest row — can be driven by a test. Wiring that only exists
/// inside an `NSApplicationDelegate` is wiring nothing can check.
public struct AwaySessionRecorder: Sendable {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - policy: read per session rather than captured once, so changing the threshold
    ///     or switching a reason off takes effect on the next session instead of the next
    ///     launch.
    ///   - now: injectable for the digest's `created_at`.
    public init(
        archive: Archive,
        policy: @escaping @Sendable () -> DigestPolicy = { DigestPolicy() },
        triage: any TriageEvaluating = NoTriage(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.archive = archive
        self.policy = policy
        self.triage = triage
        self.now = now
    }

    // MARK: Public

    /// What a finished session left behind.
    public struct Outcome: Sendable, Equatable {
        /// The persisted row, with its `id` filled in.
        public let session: AwaySession

        /// How many notifications the session claimed.
        public let linkedCount: Int

        /// `nil` when the settings said no, when the session was too short, or when
        /// nothing arrived — all of which are ordinary, and none of which write a row.
        public let digest: Digest?
    }

    /// Records one finished session and returns what it produced.
    ///
    /// - Returns: `nil` only when the session could not be written at all. A session that
    ///   is recorded but earns no digest is a successful outcome with `digest == nil`,
    ///   because that is the common case, not a failure.
    @discardableResult
    public func record(_ ended: AwaySessionTracker.EndedSession) -> Outcome? {
        let stored: AwaySession
        let linked: Int
        do {
            stored = try archive.insertAwaySession(ended.session)
            linked = try archive.linkNotifications(to: stored)
            Log.digest.info("Away session recorded, \(linked) notification(s) linked")
        } catch {
            // One session's worth of granularity, and nothing else: the notifications it
            // would have grouped are already archived, and the next session is seconds
            // away. Logged and dropped rather than retried.
            let detail = (error as? ArchiveError)?.logDescription ?? ArchiveError.detail(from: error)
            Log.digest.error("away session not recorded: \(detail)")
            return nil
        }
        return Outcome(session: stored, linkedCount: linked, digest: buildDigest(for: stored, causes: ended))
    }

    // MARK: Private

    private let archive: Archive
    private let policy: @Sendable () -> DigestPolicy
    private let triage: any TriageEvaluating
    private let now: @Sendable () -> Date

    /// Builds the digest, if the settings want one for this session.
    ///
    /// The policy is checked *before* the build rather than after: a digest written and
    /// then never shown is a row nobody asked for, and "never means never" has to stop the
    /// build (docs/features/MISSED_DIGEST.md#never-nagging-rules, rule 7).
    private func buildDigest(for stored: AwaySession, causes ended: AwaySessionTracker.EndedSession) -> Digest? {
        guard policy().allows(ended) else {
            Log.digest.info("Away session \(stored.id ?? 0) earns no digest under the current settings")
            return nil
        }
        do {
            return try DigestEngine(archive: archive, triage: triage, now: now).build(for: stored)
        } catch let error as DigestEngine.DigestError {
            // `alreadyBuilt` is ordinary, not exceptional: wake and unlock race often
            // enough that a second session-end event is a normal Tuesday.
            Log.digest.debug("Digest not built: \(error.logDescription)")
        } catch {
            let detail = (error as? ArchiveError)?.logDescription ?? ArchiveError.detail(from: error)
            Log.digest.error("digest not built: \(detail)")
        }
        return nil
    }
}
