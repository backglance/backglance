import Foundation

// MARK: - AwayClock

/// Time, as ``AwaySessionTracker`` sees it.
///
/// The tracker reasons about two intervals that are minutes and seconds long: the
/// 60-second merge gap it waits out before committing a session end, and the minimum
/// duration below which a session earns no digest. A test that proved either against
/// the wall clock would be slow, flaky, or both — so both `now` and the waiting are
/// injected.
///
/// > Note: deliberately not Swift's `Clock`. That protocol's `Instant` machinery buys
/// > nothing here (the archive stores `Date`s), and shadowing the standard library's
/// > name inside a module that also uses it would be a trap.
public protocol AwayClock: Sendable {
    var now: Date { get }

    /// Suspends until `deadline`, or throws `CancellationError` if the surrounding task
    /// is cancelled first — which is exactly what a re-activation inside the merge gap
    /// does. Returns immediately for a deadline already past.
    ///
    /// > Important: an absolute deadline, not a duration. The caller computes it before
    /// > spawning the task that waits, so the gap is measured from the moment the session
    /// > cleared rather than from whenever that task happens to be scheduled. With a
    /// > duration the two differ by however long the executor took to get to it, which is
    /// > unbounded — and against a clock a test drives by hand, unbounded means the
    /// > deadline can land past every advance the test intends to make.
    func sleep(until deadline: Date) async throws
}

// MARK: - SystemAwayClock

/// The production clock: the system's.
public struct SystemAwayClock: AwayClock {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public var now: Date {
        Date()
    }

    public func sleep(until deadline: Date) async throws {
        let remaining = deadline.timeIntervalSince(now)
        guard remaining > 0 else {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(for: .seconds(remaining))
    }
}
