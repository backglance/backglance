import Foundation

/// Whether the performance suites should run at all.
///
/// `BACKGLANCE_PERF=1`, and nothing else — deliberately not the `Fast`/`Full`
/// test scope. Wall-clock budgets are measured against a machine, and a shared
/// runner's variance is larger than the budgets themselves
/// (docs/deployment/PERFORMANCE_GUIDE.md#regression-budgets-and-ci-policy): pull
/// requests skip these, and the nightly job on a quiet runner measures them.
///
/// **The one way to set it is the test plan's `Performance` configuration**:
///
///     xcodebuild test -scheme Backglance -testPlan Backglance \
///       -only-test-configuration Performance \
///       -only-testing:BackglanceSearchTests/SearchLatencyTests
///
/// `env BACKGLANCE_PERF=1 xcodebuild test …` does *not* work — xcodebuild does not
/// forward the invoking shell's environment into the test host process, so the
/// variable never arrives and every budget quietly skips. That is not theoretical:
/// it is how three milestones were closed against budgets nothing had measured
/// (BACKGLANCE-194). `.github/workflows/perf.yml` runs the configuration nightly and
/// fails if any of its tests were *skipped* rather than run, so a gate that stops
/// working is a red build rather than a green one.
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

    /// A memory budget's failure threshold: 50% above target.
    ///
    /// Deliberately *not* ``threshold(_:)``'s allowance. Resident size does not
    /// move with how busy the runner is — a loaded machine makes the same code
    /// take longer, not allocate more — so the wall-clock slack below would be
    /// meaningless here, and at 3× a 150 MB ceiling would only fail at 450 MB.
    public static func memoryThreshold(_ budget: Double) -> Double {
        budget * 1.5
    }

    /// A wall-clock budget's failure threshold: 3× target.
    ///
    /// The budget is what the code is written to; this is where a regression
    /// becomes a failure. The gap is the runner's variance, spelled out in the
    /// policy table rather than left to whoever reads a red test.
    ///
    /// It was 1.5× until BACKGLANCE-258 measured what the variance actually is.
    /// The nightly went green then red on the *same commit* (dd08883, 24 and 25
    /// August), and one assertion moved 80.0 ms → 109.4 ms across identical code:
    /// 2.2× the 50 ms budget, from nothing but a busier runner. The same suite
    /// passes locally in 7.5 s against the runner's 32 s. At 1.5× the gate was
    /// reporting the weather.
    ///
    /// 3× is chosen over the ~2.2× observed worst case so ordinary noise has
    /// headroom rather than sitting just under the line. It costs sensitivity —
    /// a 2× slowdown now passes — and that is the deliberate trade: the
    /// regressions this exists to catch (an accidental O(n²), a dropped index)
    /// are far larger than 3×, while a gate that cries wolf catches nothing at
    /// all, which is the failure this workflow's own header warns about.
    ///
    /// The budgets themselves are untouched and are still verified on real
    /// hardware — see docs/deployment/PERFORMANCE_GUIDE.md. This number is the
    /// instrument's tolerance, not the product's promise.
    public static func threshold(_ budget: Double) -> Double {
        budget * 3.0
    }
}
