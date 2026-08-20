import Foundation

// MARK: - TriageEvaluating

/// Turns one archived notification into its ``Triage``.
///
/// The timeline needs triage to group and paint rows, but the thing that
/// computes it — `RulesEngine`, with rule compilation, caching and its own
/// `ValueObservation` — is a later milestone. This protocol is the seam: the
/// timeline depends on the question, not on the answer's implementation, so
/// `RulesEngine` becomes one more conformance rather than an edit to
/// `TimelineStore`.
///
/// Conformances must be callable synchronously from the main actor — the
/// timeline evaluates every visible row inside `regroup()` — and from any
/// isolation, hence `Sendable`. `RulesEngine` satisfies that with an
/// `NSLock`-guarded snapshot; ``NoTriage`` satisfies it by doing nothing.
///
/// See docs/features/RULES.md#business-logic-rulesengine.
public protocol TriageEvaluating: Sendable {
    /// Triage for one row. Pure and synchronous: no archive reads, no throwing.
    func evaluate(_ notification: ArchivedNotification) -> Triage
}

// MARK: - NoTriage

/// The rule-free evaluator: every row comes back as ``Triage/none``.
///
/// The timeline's default until `RulesEngine` lands, and the value tests use
/// when they are asserting grouping rather than rule matching. Behaviourally
/// identical to an enabled rules engine with an empty rule set, so swapping one
/// in cannot change how an untriaged timeline renders.
public struct NoTriage: TriageEvaluating {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public func evaluate(_: ArchivedNotification) -> Triage {
        .none
    }
}
