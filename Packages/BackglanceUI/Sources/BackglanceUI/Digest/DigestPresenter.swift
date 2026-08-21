import BackglanceCore
import Foundation
import Observation

// MARK: - DigestPresenter

/// Decides whether the popover has a digest to show, and holds the model for it.
///
/// This is the never-nagging contract in code
/// (docs/features/MISSED_DIGEST.md#never-nagging-rules). The card itself is a renderer and
/// deliberately knows none of these rules; every question of *whether* the user is shown
/// anything is answered here, in one place, where a change that could produce a second
/// digest for one session is visible in a diff:
///
/// - **At most one per session.** `DigestEngine` refuses a second build inside its own
///   transaction, so "the pending digest" is already at most one per away session.
/// - **No repeats.** ``BackglanceCore/Archive/pendingDigest()`` only ever returns a digest
///   with `dismissed_at IS NULL`, so dismissing retires it across relaunches too. Being
///   *shown* does not retire it: closing the popover mid-read is not an answer.
/// - **Below-threshold, zero-item and "never" sessions are silent.** None of them produce
///   a digest row at all — `DigestPolicy` stops the first two and `DigestEngine` writes
///   nothing for an empty selection — so there is nothing here to filter.
/// - **No badge.** Nothing in this type touches the unread count.
@MainActor
@Observable
public final class DigestPresenter {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - calendar: passed through to the model, for the multi-day header summary.
    ///   - now: passed through to the model, so a test can assert `shown_at`.
    public init(
        archive: Archive,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.archive = archive
        self.calendar = calendar
        self.now = now
    }

    // MARK: Public

    /// The digest to show, or `nil` for the ordinary case of nothing missed.
    public private(set) var current: DigestViewModel?

    /// Forwards "Open timeline at this point" to the host, which is the only thing that
    /// knows how to open a window. Set by the app shell.
    public var onOpenTimeline: ((AwaySession) -> Void)?

    /// Whether the popover should be showing a digest right now.
    public var hasDigest: Bool {
        current != nil
    }

    /// Looks for a digest worth showing. Called when the surface is about to open, which
    /// is the only moment the answer can have changed for a user who is looking.
    ///
    /// Cheap enough to run on every open: one indexed row, plus its session, and only
    /// when that row exists does the model go on to read any notifications.
    public func refresh() {
        do {
            guard let digest = try archive.pendingDigest() else {
                current = nil
                return
            }
            // Already showing this one. Rebuilding would re-run `load()` and lose the
            // muted group's expanded state for a card the user is in the middle of.
            if current?.digest.id == digest.id {
                return
            }
            let session = try archive.awaySession(id: digest.awaySessionId)
            let model = DigestViewModel(
                archive: archive,
                digest: digest,
                session: session,
                calendar: calendar,
                now: now
            )
            model.onOpenTimeline = { [weak self] session in
                self?.onOpenTimeline?(session)
            }
            model.onDismissed = { [weak self] in
                self?.current = nil
            }
            current = model
            Log.digest.info("Digest \(digest.id ?? 0) queued for the popover")
        } catch {
            // Nothing to show is the overwhelmingly common answer anyway, so a failed
            // lookup degrades to it. The timeline underneath is unaffected.
            current = nil
            Log.digest.error("Digest lookup failed: \(ArchiveError.detail(from: error))")
        }
    }

    /// Retires the current digest and takes the card down. It will not come back.
    ///
    /// The card's own close button goes through the model, which calls back into the
    /// `onDismissed` hook above — so both paths retire the digest the same way, and there
    /// is no second route that could take the card down without writing `dismissed_at`.
    public func dismiss() {
        current?.dismiss()
    }

    // MARK: Private

    private let archive: Archive
    private let calendar: Calendar
    private let now: @Sendable () -> Date
}
