import Foundation

// MARK: - Clock

/// A clock the test controls.
///
/// Retention, away-session detection and the digest all reason about elapsed time. Tests
/// that use the wall clock for that are either slow or flaky, so every type that needs
/// "now" takes a `Clock` and gets `TestClock` under test.
public protocol Clock: Sendable {
    /// The current instant, as the production code sees it.
    var now: Date { get }
}

// MARK: - SystemClock

/// The production clock: the system's.
public struct SystemClock: Clock {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public var now: Date {
        Date()
    }
}

// MARK: - TestClock

/// A clock that only moves when the test moves it.
///
/// Not `Sendable`-by-value: it is a reference type so a test can advance the same clock the
/// code under test is holding. The lock keeps it usable from an actor's executor.
public final class TestClock: Clock, @unchecked Sendable {
    // MARK: Lifecycle

    public init(now: Date = Date(timeIntervalSince1970: 1_767_225_600)) {
        instant = now
    }

    // MARK: Public

    public var now: Date {
        lock.withLock { instant }
    }

    /// Moves the clock forward. Negative intervals are allowed: some tests need to prove
    /// that code survives a clock that went backwards (an NTP correction, a timezone change).
    public func advance(by interval: TimeInterval) {
        lock.withLock { instant = instant.addingTimeInterval(interval) }
    }

    /// Jumps the clock to an exact instant.
    public func set(to date: Date) {
        lock.withLock { instant = date }
    }

    // MARK: Private

    private let lock = NSLock()
    private var instant: Date
}
