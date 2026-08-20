import Foundation

/// Which slice of the suite this run is meant to cover.
///
/// `Backglance.xctestplan` defines two configurations, `Fast` and `Full`, and each sets
/// `BACKGLANCE_TEST_SCOPE` accordingly — `Fast` for unit tests and fixtures, `Full` for
/// everything. Nothing read that variable for a while, which made the two configurations
/// identical and the distinction decorative; this is what gives it effect again.
///
/// Deliberately narrow. Only genuinely slow tests consult it, and the default when the
/// variable is absent or unrecognised is ``full`` — a run that has not said what it wants
/// gets the thorough answer, never the quick one, so nothing is skipped by accident.
public enum TestScope: String, Sendable {
    case fast
    case full

    // MARK: Public

    /// The scope this process is running under.
    public static var current: TestScope {
        ProcessInfo.processInfo.environment["BACKGLANCE_TEST_SCOPE"]
            .flatMap(TestScope.init(rawValue:)) ?? .full
    }

    /// Whether the expensive tests should run.
    ///
    /// Prefer expressing the reason at the call site: a skipped test that does not say
    /// why reads as a broken one.
    public static var includesSlowTests: Bool {
        current == .full
    }
}
