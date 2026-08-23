import Foundation
import GRDB

// MARK: - RulesEngine

/// Backglance's triage layer: compiles a `[Rule]` into a fast-to-walk ``CompiledRules``,
/// then turns one notification into its ``Triage``.
///
/// Two halves live here. `compile(_:)` (`RulesEngine+Compile.swift`) and
/// `evaluate(_:compiled:bundleID:appIsMuted:)` (`RulesEngine+Evaluate.swift`) are pure,
/// static and stateless — no archive access, no locking, never throw, never `async` — which
/// is what makes rule matching testable as a table with no database and no actor anywhere in
/// the picture. This file is the other half: the instance that owns a cached snapshot of
/// *which* rules and apps are current, and the one archive write (`setAppMuted(bundleID:
/// muted:)`) rules triage needs. See docs/features/RULES.md#business-logic-rulesengine.
///
/// **What this instance does.** `start()` subscribes to `Archive.rulesSnapshots()`
/// (`rules` + `apps`, together) and calls `install(rules:apps:)` on every value; `install`
/// recompiles, bumps the snapshot version, and installs the result with an **empty** triage
/// cache — a rules or apps change has to re-triage every row on the next render, so the old
/// cache cannot survive it. `evaluate(_:)` is the `TriageEvaluating` conformance: a cache hit
/// by notification id returns immediately, a miss resolves `notification.appId` to a bundle
/// id through the snapshot's map and calls the static `evaluate`, passing the resolved
/// per-app mute in as `appIsMuted` so VIP-beats-mute stays defined in exactly the one place
/// the static function already defines it.
///
/// **What this instance deliberately does not do.** No `BudgetLedger` and no
/// auto-disable-after-three-violations path: both exist only for `kind = .regex` rules, and
/// `RuleLimits.regexRulesEnabled` is `false` for the whole of v1.0 — `compile(_:)` rejects
/// every regex rule before a matcher is ever built for one, so there is nothing here a
/// budget could ever be charged against. The v1.x task that flips that flag adds
/// `BudgetLedger` alongside it. Import/export lives in `RulesEngine+ImportExport.swift`,
/// not here — `exportRules()`/`importRules(from:)` reuse `archive` and nothing else this
/// file owns.
///
/// `@unchecked Sendable` because `Snapshot` is mutable state the compiler cannot verify on
/// its own; `lock` is what actually makes it safe to call `evaluate(_:)` synchronously from
/// the main actor while a background task replaces the whole snapshot underneath it.
public final class RulesEngine: TriageEvaluating, @unchecked Sendable {
    // MARK: Lifecycle

    /// - Parameter archive: the archive `start()` observes and `setAppMuted(bundleID:muted:)`
    ///   writes to.
    ///
    /// Every row evaluates as `Triage.none` until the first snapshot from `start()` lands —
    /// the same "no rules, no work" fast path an app with zero configured rules takes
    /// forever, so a `RulesEngine` that has not started yet costs nothing and breaks nothing.
    public init(archive: Archive) {
        self.archive = archive
    }

    deinit {
        // Mirrors `TimelineStore`'s own deinit: an observation that outlived this instance
        // would keep the archive's reader open for a subscription nobody is consuming.
        observationTask?.cancel()
    }

    // MARK: Public

    /// The current snapshot's compile problems, for the settings list's warning badges
    /// (BACKGLANCE-209).
    public var problems: [RuleCompileError] {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.problems
    }

    /// ``TriageEvaluating/hasMuteRules``: whether the installed snapshot holds any
    /// enabled `mute` rule.
    ///
    /// Every `mute` rule counts, not only the keyword-scoped ones BACKGLANCE-240 was
    /// filed about. `apps.is_muted` — the column the badge's SQL can see — is written by
    /// ``setAppMuted(bundleID:muted:)`` alone. A `mute` *rule* is a different mechanism
    /// that produces the same `Triage.muted`, and the badge query cannot see any of them,
    /// including one whose `match_field` is `app`.
    ///
    /// Reads the compiled set rather than the raw rules: `compile(_:)` has already dropped
    /// disabled rules and rules whose pattern would not compile, so a rule the engine
    /// would never act on cannot push the badge onto its slower path either.
    public var hasMuteRules: Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.compiled.entries.contains { $0.kind == .mute }
    }

    /// Starts observing `rules` and `apps`, installing every snapshot as it arrives.
    ///
    /// Idempotent — a second call cancels the first observation before starting a new one,
    /// the same shape `TimelineStore.startObserving()` uses. Callers are expected to call
    /// this exactly once: `AppDelegate` builds one `RulesEngine` for the whole app and hands
    /// the same instance to every surface, so the popover and the window can never disagree
    /// about a rule and the triage cache is shared rather than duplicated per surface.
    ///
    /// If the observation's read fails, the stream finishes (`Archive.rulesSnapshots()`
    /// carries the failure to its first — and only — throw) and this method logs it and
    /// stops there **without** touching `snapshot`. Per
    /// docs/features/RULES.md#business-logic-rulesengine: "the last good snapshot stays
    /// installed and the failure is logged" — triage keeps answering with whatever `install`
    /// last set (`.empty`, if this is the very first read and it failed) rather than every
    /// row reverting to `.none`. Stale rules beat no rules.
    public func start() {
        observationTask?.cancel()
        let stream = archive.rulesSnapshots()
        observationTask = Task { [weak self] in
            do {
                for try await snapshot in stream {
                    guard let self, !Task.isCancelled else {
                        return
                    }
                    install(rules: snapshot.rules, apps: snapshot.apps)
                }
            } catch {
                Log.rules.error(
                    "rules observation failed, keeping last snapshot: \(ArchiveError.detail(from: error))"
                )
            }
        }
    }

    /// Recompiles `rules`, re-indexes `apps`, and installs the result as the new snapshot
    /// with an empty triage cache and a bumped version.
    ///
    /// Called by `start()`'s observation loop on every `rules`/`apps` change, and directly by
    /// tests and by any caller that wants to install a snapshot without a live archive
    /// subscription.
    public func install(rules: [Rule], apps: [AppRecord]) {
        let (compiled, problems) = Self.compile(rules)
        var bundleIDs: [Int64: String] = [:]
        var mutedBundleIDs: Set<String> = []
        for app in apps {
            guard let id = app.id else {
                continue // not yet inserted; cannot be any row's `appId`
            }
            bundleIDs[id] = app.bundleId
            if app.isMuted {
                mutedBundleIDs.insert(app.bundleId.lowercased())
            }
        }

        lock.lock()
        snapshot = Snapshot(
            version: snapshot.version + 1,
            compiled: compiled,
            problems: problems,
            bundleIDs: bundleIDs,
            mutedBundleIDs: mutedBundleIDs,
            triage: [:]
        )
        lock.unlock()

        // Logged once per problem, by rule id and kind only. `RuleCompileError.message` is
        // safe to *show* the user — it never carries notification content — but it is still
        // their own typed pattern text, and there is no reason for it to also reach a log.
        for problem in problems {
            Log.rules.error("rule \(problem.ruleID) compile problem: \(problem.kind.rawValue)")
        }
    }

    /// Cached triage for one row, callable synchronously from any isolation — the timeline
    /// calls this from the main actor inside `regroup()`.
    public func evaluate(_ notification: ArchivedNotification) -> Triage {
        lock.lock()
        defer { lock.unlock() }

        if let id = notification.id, let cached = snapshot.triage[id] {
            return cached
        }

        let bundleID = snapshot.bundleIDs[notification.appId]
        let isMuted = bundleID.map { snapshot.mutedBundleIDs.contains($0.lowercased()) } ?? false
        // The static `evaluate` already takes `appIsMuted` and already applies the VIP
        // exemption (see `RulesEngine+Evaluate.swift`) — calling it, rather than
        // re-implementing "if muted && !pinned" here, keeps VIP-beats-mute defined in exactly
        // one place.
        let triage = Self.evaluate(notification, compiled: snapshot.compiled, bundleID: bundleID, appIsMuted: isMuted)

        if snapshot.triage.count >= RuleLimits.triageCacheLimit {
            snapshot.triage.removeAll(keepingCapacity: true) // bounded, never unbounded growth
        }
        if let id = notification.id {
            snapshot.triage[id] = triage
        }
        return triage
    }

    /// Mutes or unmutes one app by bundle id — the one path that writes `apps.is_muted`.
    /// Used by the row context menu's "Mute App" action and by the settings pane.
    ///
    /// Synchronous, matching `Archive+Actions.swift`'s house style and every other
    /// archive-write method `ActionDispatching` already exposes — nothing else in this file
    /// needs `await` either, so there is no concrete reason for this one method to differ
    /// from the doc's older `async throws` sketch.
    ///
    /// Does nothing else on success: `start()`'s observation reinstalls the snapshot the
    /// moment this write lands and commits, and the triage cache dies with that
    /// installation — a caller that just muted an app does not also need to invalidate
    /// anything by hand.
    ///
    /// - Throws: ``RulesError/unknownApp(_:)`` when no archived app has this bundle id (the
    ///   update touched zero rows); ``ArchiveError/writeFailed(table:underlying:)`` if the
    ///   write itself failed.
    public func setAppMuted(bundleID: String, muted: Bool) throws {
        do {
            let changed = try archive.pool.write { db in
                try AppRecord
                    .filter(Column("bundle_id") == bundleID)
                    .updateAll(db, Column("is_muted").set(to: muted))
            }
            guard changed > 0 else {
                throw RulesError.unknownApp(bundleID)
            }
        } catch let error as RulesError {
            throw error
        } catch {
            throw ArchiveError.writeFailed(
                table: AppRecord.databaseTableName,
                underlying: ArchiveError.detail(from: error)
            )
        }
    }

    // MARK: Internal

    /// The archive `start()` observes and `setAppMuted(bundleID:muted:)` writes to.
    /// Not `private`, for the same reason `debugSnapshot` above isn't:
    /// `RulesEngine+ImportExport.swift`'s `exportRules()`/`importRules(from:)` are the
    /// second file in this module that need a direct read/write path to `rules`, and
    /// `private` would not reach across that file boundary.
    let archive: Archive

    /// Test-only window into the snapshot. `install`'s version bump and cache reset are
    /// otherwise only observable indirectly — through whether `evaluate(_:)` returns a stale
    /// or a freshly recomputed `Triage` — so `RulesEngineTests` reads this directly instead.
    /// Not `private`, for the same reason `RulesEngine.containsWord`'s own doc comment gives:
    /// `private` does not reach across files, and nothing outside the module has a use for
    /// this, so there is no case for making it `public`.
    var debugSnapshot: (version: Int, cachedCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (snapshot.version, snapshot.triage.count)
    }

    // MARK: Private

    /// Everything `evaluate(_:)` needs behind one lock, replaced wholesale by
    /// `install(rules:apps:)` — never mutated field-by-field — so a reader that grabbed the
    /// snapshot before a replacement always sees a self-consistent one, not some rules
    /// recompiled against a stale app list or vice versa.
    private struct Snapshot {
        static let empty = Snapshot(
            version: 0,
            compiled: .empty,
            problems: [],
            bundleIDs: [:],
            mutedBundleIDs: [],
            triage: [:]
        )

        /// Bumped on every `install(rules:apps:)` call. Not read by `evaluate(_:)` itself —
        /// the emptied `triage` dictionary is what actually invalidates the cache — but kept
        /// here as the version this snapshot is, for `debugSnapshot` and for a future reader
        /// that wants to detect "the snapshot changed under me" without diffing the whole
        /// thing.
        var version: Int

        var compiled: CompiledRules

        var problems: [RuleCompileError]

        /// `apps.id → apps.bundle_id`, since `ArchivedNotification.appId` stores only the
        /// integer id.
        var bundleIDs: [Int64: String]

        /// Lowercased `apps.bundle_id` for every row with `is_muted = true` — folded the
        /// same way `RulesEngine.compile(_:)` folds a rule's own app scope, so the two
        /// definitions of "this bundle id" can never disagree.
        var mutedBundleIDs: Set<String>

        /// Triage already computed under this snapshot, keyed by `notifications.id`. Bounded
        /// by `RuleLimits.triageCacheLimit` in `evaluate(_:)`; emptied wholesale by every
        /// `install(rules:apps:)` call.
        var triage: [Int64: Triage]
    }

    private let lock = NSLock()
    private var snapshot = Snapshot.empty

    /// Only ever assigned on whichever isolation calls `start()`; cancelled from `deinit`,
    /// which is why this cannot be actor-isolated the way `TimelineStore`'s equivalent
    /// property is — this class has no actor of its own.
    private var observationTask: Task<Void, Never>?
}
