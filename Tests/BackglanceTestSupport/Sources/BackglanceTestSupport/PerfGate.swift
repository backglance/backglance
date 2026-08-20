import Foundation

/// Whether the performance suites should run at all.
///
/// `BACKGLANCE_PERF=1`, and nothing else — deliberately not the `Fast`/`Full`
/// test scope. Wall-clock budgets are measured against a machine, and a shared
/// runner's variance is larger than the budgets themselves
/// (docs/deployment/PERFORMANCE_GUIDE.md#regression-budgets-and-ci-policy): pull
/// requests skip these, the nightly job on a quiet runner sets the variable, and
/// so does a developer checking a hot path before a release.
///
/// A performance test that fails because the machine was compiling something
/// else teaches everyone to ignore performance tests, which is worse than not
/// having them.
public enum PerfGate {
    /// `true` when `BACKGLANCE_PERF` is set to something truthy.
    public static var isEnabled: Bool {
        switch ProcessInfo.processInfo.environment["BACKGLANCE_PERF"]?.lowercased() {
        case "1",
             "true",
             "yes":
            true

        default:
            false
        }
    }

    /// The budget's failure threshold: 50% above target.
    ///
    /// The budget is what the code is written to; this is where a regression
    /// becomes a failure. The gap is the runner's variance, spelled out in the
    /// policy table rather than left to whoever reads a red test.
    public static func threshold(_ budget: Double) -> Double {
        budget * 1.5
    }
}
