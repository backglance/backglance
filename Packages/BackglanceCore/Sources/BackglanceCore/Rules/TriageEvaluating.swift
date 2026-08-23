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

    /// Whether any enabled `mute` rule is currently compiled.
    ///
    /// This exists for exactly one caller: `Archive.unreadBadgeCount(_:since:triage:)`.
    /// The badge is a SQL `COUNT` that runs inside the timeline's `ValueObservation`, so
    /// it fires on every write and has to stay cheap — but SQL can only see
    /// `apps.is_muted`, while `Triage.muted` is decided here, in Swift. A `mute` rule
    /// therefore collapsed its rows into the day's Muted group while they went on
    /// lighting the badge (BACKGLANCE-240).
    ///
    /// Rather than move the badge off SQL for everybody, this lets the count keep its
    /// exact, index-only form whenever there is nothing to correct for — which is the
    /// default install, since Backglance ships with no rules at all
    /// (docs/features/RULES.md#digest-search-and-defaults) — and pay for a bounded
    /// row scan only once the user has actually written a `mute` rule.
    var hasMuteRules: Bool { get }
}

// MARK: - Default

public extension TriageEvaluating {
    /// An evaluator that says nothing about muting is taken at its word: no rules, so
    /// nothing for the badge to correct for. ``NoTriage`` and every test double get the
    /// cheap path for free; only `RulesEngine` has a real answer to give.
    var hasMuteRules: Bool {
        false
    }
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

    /// No rules at all, so nothing the badge query needs to second-guess.
    public var hasMuteRules: Bool {
        false
    }

    public func evaluate(_: ArchivedNotification) -> Triage {
        .none
    }
}
