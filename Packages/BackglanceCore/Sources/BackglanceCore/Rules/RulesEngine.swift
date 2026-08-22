import Foundation

// MARK: - RulesEngine

/// Backglance's triage layer: compiles a `[Rule]` into a fast-to-walk ``CompiledRules``,
/// then turns one notification into its ``Triage``.
///
/// This declaration currently holds only the two pure, static, stateless halves of the
/// engine — `compile(_:)` in `RulesEngine+Compile.swift` and
/// `evaluate(_:compiled:bundleID:appIsMuted:)` in `RulesEngine+Evaluate.swift`. Both are
/// free functions in every sense but their namespace: no archive access, no locking, no
/// caching, never throw, never `async`. That is deliberate — it is what makes rule
/// matching testable as a table (`compile(rules)` in, `(CompiledRules,
/// [RuleCompileError])` out; `evaluate(notification, compiled:)` in, `Triage` out) with no
/// database and no actor anywhere in the picture. See
/// docs/features/RULES.md#business-logic-rulesengine.
///
/// **What is intentionally not here yet** — tracked as follow-up board tasks against this
/// same type, not gaps in this one:
/// - An immutable `Snapshot` (the compiled rules, their compile problems, an
///   `app_id → bundle id` map, the set of `apps.is_muted` bundle ids, and a bounded
///   triage cache) held behind a lock and replaced wholesale by a `ValueObservation` over
///   `rules` and `apps`.
/// - An instance `evaluate(_:) -> Triage` that resolves `notification.appId` to a bundle
///   id, folds in per-app mute with the same VIP exemption, and caches the result by
///   notification id.
/// - `setAppMuted(bundleID:muted:) async throws`, the one path that writes
///   `apps.is_muted`.
/// - `BudgetLedger` and the auto-disable-after-three-violations path for `kind = .regex`
///   rules (v1.x, once `RuleLimits.regexRulesEnabled` is `true`).
///
/// `RulesEngine` is declared as the eventual home for all of that — a `final class` rather
/// than a caseless enum namespace — so the task that adds it edits this one declaration to
/// add stored properties (an `NSLock`, a `Snapshot`), instead of introducing a second type
/// and migrating every caller of the static functions over to it.
public final class RulesEngine: @unchecked Sendable {
    // No stored properties and no public initializer yet: everything this task ships is
    // static, and nothing static needs `@unchecked Sendable`'s escape hatch — `compile`
    // and `evaluate` are pure functions with no shared mutable state to race on. The class
    // itself is already marked `@unchecked Sendable` in anticipation of the instance side,
    // which will hold state (a lock-guarded snapshot) the compiler cannot verify on its
    // own; that annotation costs nothing today and saves the follow-up task a signature
    // change every caller of the static API would otherwise have to absorb.
}
