import Foundation

// MARK: - CompiledTriage

/// A ``TriageEvaluating`` conformance over one already-compiled rule set — the seam
/// `TimelineStore` and `NotificationActionHandler` can be handed today, in place of
/// ``NoTriage``, without either type's initializer changing shape when the instance-side
/// `RulesEngine` (BACKGLANCE-208, not this task) lands with its own conformance.
///
/// A plain, immutable value type rather than a reference to the eventual instance-side
/// engine, on purpose: `TriageEvaluating.evaluate(_:)` takes only an
/// `ArchivedNotification`, so whatever conforms has to already know everything else
/// `RulesEngine.evaluate(_:compiled:bundleID:appIsMuted:)` needs. This type does — except
/// a bundle id. `ArchivedNotification` stores `appId` (`apps.id`, the archive's integer
/// primary key), not a bundle-id string, and resolving one requires a join this type has
/// no archive access to perform.
///
/// **What it does with `nil` today.** Until `TriageEvaluating.evaluate(_:)` grows a way to
/// carry a row's resolved bundle id — BACKGLANCE-208's problem — every notification
/// triaged through this conformance evaluates with `bundleID: nil` and `appIsMuted:
/// false`. Per `evaluate`'s fail-closed rule, that means app-scoped rules and
/// `match_field == .app` rules never fire through this seam: an unscoped `highlight`,
/// `vip`, or `mute` rule works exactly as compiled, but a rule scoped to one app, or one
/// whose pattern is a bundle id, silently never matches until the real per-row bundle id
/// is threaded through. That is a known, intentional gap, not a bug to chase in this task.
public struct CompiledTriage: TriageEvaluating {
    // MARK: Lifecycle

    public init(compiled: CompiledRules) {
        self.compiled = compiled
    }

    // MARK: Public

    public let compiled: CompiledRules

    public func evaluate(_ notification: ArchivedNotification) -> Triage {
        RulesEngine.evaluate(notification, compiled: compiled, bundleID: nil)
    }
}
