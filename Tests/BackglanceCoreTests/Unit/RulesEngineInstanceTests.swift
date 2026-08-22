@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

/// Covers the instance side of `RulesEngine` (`RulesEngine.swift`): the cached snapshot,
/// `install(rules:apps:)`, `evaluate(_:)`'s cache and per-app-mute resolution, and
/// `setAppMuted(bundleID:muted:)`. The static `compile(_:)`/`evaluate(_:compiled:bundleID:
/// appIsMuted:)` pair is covered separately by `RulesEngineCompileTests` and
/// `RulesEngineEvaluateTests` — this suite only exercises what wraps them. See
/// docs/features/RULES.md#business-logic-rulesengine.
final class RulesEngineInstanceTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - Cache

    /// `evaluate(_:)` keys its cache by notification id alone. A second call with the same
    /// id but different content must return the *first* result, not a freshly recomputed
    /// one — that is the only way to observe a cache hit from the outside, since recomputing
    /// the same input would look identical to reusing it.
    func testCacheHitReturnsTheFirstResultEvenWhenContentChanged() throws {
        let engine = try RulesEngine(archive: XCTUnwrap(archive))
        engine.install(rules: [Self.rule(1, .vip, "ayse", field: .sender)], apps: [])

        let first = Self.notification(id: 1, sender: "Ayşe")
        let matched = engine.evaluate(first)
        XCTAssertTrue(matched.pinned)

        // Same id, a sender the rule would not match — if this recomputed, `pinned`
        // would flip to `false`.
        let second = Self.notification(id: 1, sender: "Someone Else")
        let cached = engine.evaluate(second)
        XCTAssertEqual(cached, matched, "the cache hit returned the first row's triage, not a fresh one")
    }

    /// `install` throws away whatever was cached — the whole reason it does is that a rule
    /// edit must re-triage every row on the next render, not just the ones not yet seen.
    func testInstallBumpsVersionAndEmptiesTheCache() throws {
        let engine = try RulesEngine(archive: XCTUnwrap(archive))
        engine.install(rules: [], apps: [])
        let versionAfterFirstInstall = engine.debugSnapshot.version

        _ = engine.evaluate(Self.notification(id: 1))
        XCTAssertEqual(engine.debugSnapshot.cachedCount, 1)

        engine.install(rules: [], apps: [])

        XCTAssertEqual(engine.debugSnapshot.version, versionAfterFirstInstall + 1)
        XCTAssertEqual(engine.debugSnapshot.cachedCount, 0, "a new snapshot starts with an empty cache")
    }

    /// The cache is bounded, never unbounded: once it reaches `RuleLimits.triageCacheLimit`
    /// entries, the next `evaluate(_:)` call clears it wholesale before caching its own
    /// result, rather than growing past the limit.
    func testCacheClearsWholesaleAtTheLimit() throws {
        let engine = try RulesEngine(archive: XCTUnwrap(archive))
        engine.install(rules: [], apps: [])

        for id in Int64(1) ... Int64(RuleLimits.triageCacheLimit) {
            _ = engine.evaluate(Self.notification(id: id))
        }
        XCTAssertEqual(engine.debugSnapshot.cachedCount, RuleLimits.triageCacheLimit)

        _ = engine.evaluate(Self.notification(id: Int64(RuleLimits.triageCacheLimit) + 1))

        XCTAssertEqual(
            engine.debugSnapshot.cachedCount,
            1,
            "the cache was cleared wholesale and now holds only the row that triggered the clear"
        )
    }

    // MARK: - Per-app mute

    /// `install(rules:apps:)` folds `apps.is_muted` into the snapshot's bundle-id set, and
    /// `evaluate(_:)` resolves a row's `appId` through the snapshot's `app_id → bundle_id`
    /// map before applying it — exactly the join `CompiledTriage`'s own doc comment says it
    /// cannot do without an instance like this one.
    func testPerAppMuteAppliesThroughTheResolvedBundleID() throws {
        let engine = try RulesEngine(archive: XCTUnwrap(archive))
        engine.install(rules: [], apps: [Self.app(id: 7, bundleID: "com.tinyspeck.slackmacgap", muted: true)])

        let triage = engine.evaluate(Self.notification(id: 1, appId: 7))

        XCTAssertTrue(triage.muted)
    }

    /// The same VIP exemption `RulesEngine.evaluate(_:compiled:bundleID:appIsMuted:)`
    /// applies to a `mute` rule applies here too — folded through the *same* static call,
    /// per this type's own doc comment, rather than a second "if muted && !pinned" copy.
    func testPerAppMuteIsExemptedByAMatchingVIPRule() throws {
        let engine = try RulesEngine(archive: XCTUnwrap(archive))
        engine.install(
            rules: [Self.rule(1, .vip, "ayse", field: .sender)],
            apps: [Self.app(id: 7, bundleID: "com.tinyspeck.slackmacgap", muted: true)]
        )

        let triage = engine.evaluate(Self.notification(id: 1, appId: 7, sender: "Ayşe"))

        XCTAssertTrue(triage.pinned)
        XCTAssertFalse(triage.muted, "a VIP match is never hidden by per-app mute, the same as a VIP vs. mute rule")
    }

    // MARK: - setAppMuted

    /// The one archive write this type owns: a single `apps.is_muted` flip, by bundle id.
    func testSetAppMutedFlipsTheArchiveRow() throws {
        let archive = try XCTUnwrap(archive)
        let app = try archive.upsertApp(bundleID: "com.tinyspeck.slackmacgap", now: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(app.isMuted)
        let engine = RulesEngine(archive: archive)

        try engine.setAppMuted(bundleID: "com.tinyspeck.slackmacgap", muted: true)

        let reloaded = try archive.pool.read { db in
            try AppRecord.filter(Column("bundle_id") == "com.tinyspeck.slackmacgap").fetchOne(db)
        }
        XCTAssertEqual(reloaded?.isMuted, true)
    }

    /// Naming a bundle id with no archived app is an error, not a silent no-op — the doc's
    /// own wording is "throws when the update touched no row".
    func testSetAppMutedThrowsForAnUnknownBundleID() throws {
        let engine = try RulesEngine(archive: XCTUnwrap(archive))

        XCTAssertThrowsError(try engine.setAppMuted(bundleID: "app.example.unknown", muted: true)) { error in
            XCTAssertEqual(error as? RulesError, .unknownApp("app.example.unknown"))
        }
    }

    // MARK: - Compile problems

    /// `problems` mirrors the current snapshot's compile problems, for the settings list's
    /// warning badges — install with a bad pattern, and it should be there.
    func testProblemsReflectsTheCurrentSnapshot() throws {
        let engine = try RulesEngine(archive: XCTUnwrap(archive))
        XCTAssertTrue(engine.problems.isEmpty)

        engine.install(rules: [Self.rule(1, .highlight, "   ", color: "amber")], apps: [])

        XCTAssertEqual(engine.problems.map(\.kind), [.emptyPattern])
    }

    // MARK: Private

    private var archive: Archive?

    private static func rule(
        _ id: Int64,
        _ kind: Rule.Kind,
        _ pattern: String,
        field: Rule.MatchField = .any,
        color: String? = nil
    ) -> Rule {
        Rule(
            id: id,
            kind: kind,
            pattern: pattern,
            matchField: field,
            color: color,
            createdAt: UnixDate(Date(timeIntervalSince1970: 1_755_400_000))
        )
    }

    private static func app(id: Int64, bundleID: String, muted: Bool = false) -> AppRecord {
        AppRecord(
            id: id,
            bundleId: bundleID,
            isMuted: muted,
            firstSeenAt: UnixDate(Date(timeIntervalSince1970: 1_755_400_000)),
            lastSeenAt: UnixDate(Date(timeIntervalSince1970: 1_755_400_000))
        )
    }

    private static func notification(id: Int64, appId: Int64 = 1, sender: String? = nil) -> ArchivedNotification {
        ArchivedNotification(
            id: id,
            uuid: "RULES-ENGINE-\(id)",
            appId: appId,
            title: "URGENT: deploy failed on main",
            sender: sender,
            deliveredAt: UnixDate(Date(timeIntervalSince1970: 1_755_400_000)),
            capturedAt: UnixDate(Date(timeIntervalSince1970: 1_755_400_001))
        )
    }
}
