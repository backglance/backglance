import Foundation
import GRDB

// MARK: - RulesSnapshot

/// Everything `RulesEngine.install(rules:apps:)` needs, fetched together.
///
/// Mirrors `Archive+TimelineObservation.swift`'s `TimelineSnapshot`: `rules` and `apps` come
/// from the same `ValueObservation.tracking` block, in the same transaction, so a write that
/// touches both tables (muting an app while a `vip` rule import is mid-flight, say) can never
/// be observed half-applied — one table's new state paired with the other's old one.
public struct RulesSnapshot: Equatable, Sendable {
    // MARK: Lifecycle

    public init(rules: [Rule], apps: [AppRecord]) {
        self.rules = rules
        self.apps = apps
    }

    // MARK: Public

    public var rules: [Rule]
    public var apps: [AppRecord]
}

// MARK: - Archive + rules observation

public extension Archive {
    /// A stream of ``RulesSnapshot`` values: one now, one after every write to `rules` or
    /// `apps`. `RulesEngine.start()` is the intended, and so far only, consumer — see
    /// docs/features/RULES.md#business-logic-rulesengine.
    ///
    /// Follows `timelineSnapshots(unreadSince:pageSize:)`'s shape exactly, for the same
    /// reasons that method's own doc comment gives: GRDB delivers on the main queue,
    /// coalesced, and the first value arrives without waiting for a write.
    ///
    /// Where this stream differs from the timeline's is in what a caller is expected to do
    /// when it *fails*. `timelineSnapshots` expects a banner and a retry — a stale timeline
    /// is not acceptable. `RulesEngine.start()` expects the opposite: on a terminal error
    /// (this stream, like `timelineSnapshots`, finishes on its first throw) it leaves
    /// whichever snapshot `install(rules:apps:)` last produced installed and only logs the
    /// failure, because per docs/features/RULES.md, stale rules beat no rules. That
    /// difference in posture belongs to the caller, not to this method — this method just
    /// reports the failure faithfully, the same `ArchiveError.observationFailed` shape every
    /// other stream in this file uses.
    func rulesSnapshots() -> AsyncThrowingStream<RulesSnapshot, Error> {
        let observation = ValueObservation.tracking { db -> RulesSnapshot in
            try RulesSnapshot(rules: Rule.fetchAll(db), apps: AppRecord.fetchAll(db))
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await snapshot in observation.values(in: pool) {
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ArchiveError.observationFailed(ArchiveError.detail(from: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
