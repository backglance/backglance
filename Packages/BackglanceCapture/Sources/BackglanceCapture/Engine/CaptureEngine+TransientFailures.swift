import BackglanceCore
import Foundation

// MARK: - Transient failures

/// Copying a live SQLite database races the process writing to it, so some read failures
/// are noise rather than news. This is the retry budget that tells them apart.
///
/// See docs/features/CAPTURE.md#edge-cases-and-error-handling.
extension CaptureEngine {
    /// How many transient read failures in a row become a degraded state.
    ///
    /// Five 15-second polls is roughly a minute of a store that genuinely will not copy,
    /// which is long past the couple of seconds a checkpoint takes and still quick enough
    /// that a user waiting for their notifications learns something is wrong.
    static var transientFailureLimit: Int {
        5
    }

    /// Degrades, or spends one of the retries a transient failure is allowed first.
    ///
    /// See ``CaptureError/isTransient`` for which failures get a budget and why. The
    /// counter is reset by any tick that reads the store successfully, so "consecutive"
    /// really does mean consecutive: five scattered checkpoint races over an afternoon
    /// never add up to a degraded banner.
    func handleTickFailure(_ error: CaptureError) {
        guard error.isTransient else {
            consecutiveTransientFailures = 0
            transition(to: .degraded(error.degradedReason))
            return
        }

        consecutiveTransientFailures += 1
        metrics.transientFailures += 1
        let attempt = consecutiveTransientFailures
        Log.capture.notice(
            "transient: \(error.logDescription) (\(attempt)/\(Self.transientFailureLimit))"
        )

        if consecutiveTransientFailures >= Self.transientFailureLimit {
            transition(to: .degraded(error.degradedReason))
        }
    }
}
