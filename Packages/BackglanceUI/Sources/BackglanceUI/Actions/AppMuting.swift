import BackglanceCore
import Foundation

// MARK: - AppMuting

/// The one write item 8 ("Mute ‹App› in Timeline" / "Unmute ‹App›", BACKGLANCE-239)
/// needs — flipping `apps.is_muted` for one bundle id — behind a seam
/// ``NotificationActionHandler`` depends on instead of holding a concrete
/// `RulesEngine` reference directly.
///
/// **Why this, and not a wider `TriageEvaluating`.** `NotificationActionHandler`
/// already holds a `triage: any TriageEvaluating` for the timeline's *read* side
/// (`TriageEvaluating.evaluate(_:)`), and its default, `NoTriage`, is a deliberate
/// no-op whose entire contract is "pure, synchronous, never throws — no rules
/// configured, so nothing is ever triaged." Adding `setAppMuted` to that protocol
/// would force `NoTriage` to either grow a body that silently accepts a mute it can
/// never make visible, or start throwing from a type that has never thrown before,
/// for a capability (*writing*) that has nothing to do with the question
/// `TriageEvaluating` exists to answer (*evaluating*). This seam is deliberately
/// narrower instead, mirroring ``AppLaunching``'s own shape: one capability, one
/// method, injected the same way `OpenAction` reaches `NSWorkspace` — through a
/// seam built for exactly this, not through `ActionDispatching` itself, which is
/// questions-to-dispatch rather than capabilities-to-hold (the same distinction
/// `NotificationActionHandler.canActivateApp(bundleID:)`'s own doc comment gives
/// for why *that* question is not on `ActionDispatching` either).
///
/// `RulesEngine` conforms via the retroactive conformance below:
/// `setAppMuted(bundleID:muted:)`'s signature already matches this protocol
/// exactly, so no adapter type is needed, only the declaration.
/// `AppDelegate+Interface.swift` downcasts the shared `any TriageEvaluating` it
/// already threads through `startInterface()` (which is always the app's one
/// `RulesEngine` once rules have started — see `AppDelegate.triage`'s own doc
/// comment) to reach this conformance, the same `as?` step
/// `NotificationRow+ContextMenu.swift`'s `canActivateApp` already takes to reach
/// past `ActionDispatching` to the concrete `NotificationActionHandler`.
///
/// See docs/features/ACTIONS.md#mute-this-app-in-timeline and
/// docs/features/RULES.md#business-logic-rulesengine.
@MainActor
public protocol AppMuting {
    /// Mirrors `RulesEngine.setAppMuted(bundleID:muted:)` exactly: flips
    /// `apps.is_muted` for `bundleID`. The caller's rules snapshot reinstalls
    /// itself the moment the write commits, dropping the triage cache the same
    /// way any other rule change does — nothing here has to invalidate anything
    /// by hand.
    ///
    /// - Throws: `RulesError.unknownApp(_:)` when no archived app has this
    ///   bundle id (the write touched zero rows), or an archive write failure.
    ///   ``NotificationActionHandler`` wraps either as
    ///   ``ActionError/archive(reason:)`` — see
    ///   `NotificationActionHandler.setAppMuted(bundleID:_:)`.
    func setAppMuted(bundleID: String, muted: Bool) throws
}

// MARK: - NoAppMuting

/// The seam's placeholder conformance, mirroring `NoTriage`: what a
/// ``NotificationActionHandler`` built without a live `RulesEngine` — a preview,
/// or a test that only exercises other actions — falls back to.
///
/// Unlike `NoTriage`, muting is a write with a real effect to promise, so this
/// cannot silently "succeed" at nothing without lying to whoever called it: it
/// throws every time, and `NotificationActionHandler` wraps that the same way it
/// wraps a genuine archive failure — the row simply reports "something went
/// wrong" rather than pretending the app is now muted when nothing happened.
public struct NoAppMuting: AppMuting {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public func setAppMuted(bundleID _: String, muted _: Bool) throws {
        throw AppMutingError.notWired
    }
}

// MARK: - AppMutingError

/// ``NoAppMuting``'s one case: there was no `RulesEngine` behind this handler to
/// write through.
public enum AppMutingError: Error, Equatable {
    case notWired
}

// MARK: - RulesEngine + AppMuting

/// Retroactive conformance, declared here rather than in `BackglanceCore`: this
/// protocol belongs to the UI-facing action seam, and `RulesEngine` already has
/// the exact method this needs — nothing to adapt, only to declare. `setAppMuted`
/// is synchronous and lock-guarded internally, so it satisfies this `@MainActor`
/// requirement the same way any nonisolated method can be called from the main
/// actor.
extension RulesEngine: AppMuting {}
