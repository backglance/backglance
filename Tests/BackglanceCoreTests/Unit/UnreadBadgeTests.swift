@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

/// What the unread badge counts, and — since BACKGLANCE-240 — what it stops counting.
///
/// The badge had two definitions of "muted" and only knew one of them.
/// `apps.is_muted` is a column, so SQL could see it; `Triage.muted` is decided in Swift
/// by `RulesEngine`, so SQL could not. A `mute` rule therefore collapsed its rows into
/// the day's Muted group and went on lighting the badge for them —
/// docs/features/RULES.md's Rule Kinds table promises both halves.
final class UnreadBadgeTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - The cheap path is unchanged

    func testAnAppMutedByItsColumnNeverReachesTheBadge() throws {
        let archive = try XCTUnwrap(archive)
        try seed(titles: ["Deploy failed", "Build passed"])
        try seed(titles: ["Newsletter: week 12"], bundleID: Stubs.mail, muted: true)

        XCTAssertEqual(try badge(triage: NoTriage()), 2)
    }

    /// The default install has no rules, so the badge keeps its exact index-only `COUNT`.
    func testWithNoRulesTheCountIsTheSameAsItAlwaysWas() throws {
        let archive = try XCTUnwrap(archive)
        try seed(titles: ["Deploy failed", "Newsletter: week 12"])

        let engine = RulesEngine(archive: archive)
        XCTAssertFalse(engine.hasMuteRules, "a fresh engine must take the cheap path")
        XCTAssertEqual(try badge(triage: engine), 2)
    }

    // MARK: - A mute rule now reaches the badge

    /// The repro from BACKGLANCE-240: a keyword mute rule, matching on `any`.
    func testAKeywordMuteRuleTakesItsRowsOutOfTheBadge() throws {
        let archive = try XCTUnwrap(archive)
        try seed(titles: ["Deploy failed", "Newsletter: week 12", "Newsletter: week 13"])

        let engine = try engineMuting(pattern: "newsletter", matchField: .any)

        XCTAssertTrue(engine.hasMuteRules)
        XCTAssertEqual(try badge(triage: engine), 1, "both newsletters were muted by rule")
    }

    /// A `mute` rule scoped by app is invisible to the badge's SQL too — it writes no
    /// column. The original report framed this as a keyword-only problem; it was not.
    func testAnAppScopedMuteRuleAlsoTakesItsRowsOutOfTheBadge() throws {
        let archive = try XCTUnwrap(archive)
        try seed(titles: ["Deploy failed"])
        try seed(titles: ["Newsletter: week 12"], bundleID: Stubs.mail)

        let engine = try engineMuting(pattern: Stubs.mail, matchField: .app)

        XCTAssertEqual(try badge(triage: engine), 1)
    }

    /// VIP beats mute, in the badge as everywhere else: a row a `vip` rule also matches
    /// stays counted, which is what keeps the badge agreeing with the timeline that
    /// pinned it to the top rather than collapsing it.
    func testAVIPRuleKeepsARowInTheBadgeDespiteAMuteRule() throws {
        let archive = try XCTUnwrap(archive)
        try seed(titles: ["Newsletter: week 12 from Ayse"])

        let engine = try engine(rules: [
            rule(kind: .mute, pattern: "newsletter", matchField: .any),
            rule(kind: .vip, pattern: "ayse", matchField: .any),
        ])

        XCTAssertEqual(try badge(triage: engine), 1)
    }

    /// A disabled rule is not a rule. `compile(_:)` drops it, so it must not push the
    /// badge onto the slower path either.
    func testADisabledMuteRuleChangesNothing() throws {
        let archive = try XCTUnwrap(archive)
        try seed(titles: ["Newsletter: week 12"])

        let engine = try engine(rules: [
            rule(kind: .mute, pattern: "newsletter", matchField: .any, isEnabled: false),
        ])

        XCTAssertFalse(engine.hasMuteRules)
        XCTAssertEqual(try badge(triage: engine), 1)
    }

    // MARK: - Both paths stop at the cap

    func testTheCheapPathStopsAtTheCap() throws {
        let archive = try XCTUnwrap(archive)
        try seed(titles: (0 ..< (Archive.unreadBadgeCap + 25)).map { "Deploy \($0) failed" })

        XCTAssertEqual(try badge(triage: NoTriage()), Archive.unreadBadgeCap)
    }

    func testTheRuleAwarePathStopsAtTheCapToo() throws {
        let archive = try XCTUnwrap(archive)
        try seed(titles: (0 ..< (Archive.unreadBadgeCap + 25)).map { "Deploy \($0) failed" })

        let engine = try engineMuting(pattern: "newsletter", matchField: .any)

        XCTAssertEqual(try badge(triage: engine), Archive.unreadBadgeCap, "nothing matched, but the cap still binds")
    }

    /// The scan bound is real and deliberate: past `unreadBadgeScanCap` candidates the
    /// number under-reports rather than scanning the whole archive on every write. This
    /// asserts the documented trade-off so it cannot change silently.
    func testTheScanIsBoundedAndTheTradeOffIsWhatTheDocSays() throws {
        let archive = try XCTUnwrap(archive)
        // Every row muted, and more of them than the scan will ever look at.
        try seed(titles: (0 ..< (Archive.unreadBadgeScanCap + 50)).map { "Newsletter \($0)" })

        let engine = try engineMuting(pattern: "newsletter", matchField: .any)

        XCTAssertEqual(try badge(triage: engine), 0)
        XCTAssertEqual(Archive.unreadBadgeScanCap, Archive.unreadBadgeCap * 3)
    }

    // MARK: Private

    private enum Stubs {
        static let slack = "com.tinyspeck.slackmacgap"
        static let mail = "com.apple.mail"
        static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    }

    private var archive: Archive?

    /// The badge as the timeline's observation computes it, anchored before every seeded
    /// row so "unread since the anchor" means "all of them".
    private func badge(triage: any TriageEvaluating) throws -> Int {
        let archive = try XCTUnwrap(archive)
        let anchor = UnixDate(Stubs.epoch.addingTimeInterval(-1))
        return try archive.pool.read { db in
            try Archive.unreadBadgeCount(db, since: anchor, triage: triage)
        }
    }

    private func rule(
        kind: Rule.Kind,
        pattern: String,
        matchField: Rule.MatchField,
        isEnabled: Bool = true
    ) -> Rule {
        Rule(
            kind: kind,
            pattern: pattern,
            matchField: matchField,
            isEnabled: isEnabled,
            createdAt: UnixDate(Stubs.epoch)
        )
    }

    private func engineMuting(pattern: String, matchField: Rule.MatchField) throws -> RulesEngine {
        try engine(rules: [rule(kind: .mute, pattern: pattern, matchField: matchField)])
    }

    /// Saves `rules` and installs them directly, rather than going through `start()`'s
    /// observation — these tests are about what the badge counts, not about GRDB's
    /// delivery timing.
    private func engine(rules: [Rule]) throws -> RulesEngine {
        let archive = try XCTUnwrap(archive)
        var saved: [Rule] = []
        try archive.pool.write { db in
            for var rule in rules {
                try rule.insert(db)
                saved.append(rule)
            }
        }
        let apps = try archive.pool.read { db in try AppRecord.fetchAll(db) }
        let engine = RulesEngine(archive: archive)
        engine.install(rules: saved, apps: apps)
        return engine
    }

    private func seed(
        titles: [String],
        bundleID: String = Stubs.slack,
        muted: Bool = false
    ) throws {
        let archive = try XCTUnwrap(archive)
        var app = try archive.upsertApp(bundleID: bundleID, now: Stubs.epoch)
        if muted {
            app.isMuted = true
            try archive.pool.write { db in try app.update(db) }
        }
        let appID = try XCTUnwrap(app.id)
        for (index, title) in titles.enumerated() {
            let at = Stubs.epoch.addingTimeInterval(TimeInterval(index))
            try archive.insert(ArchivedNotification(
                uuid: "BADGE-\(bundleID)-\(index)-\(UUID().uuidString)",
                appId: appID,
                title: title,
                deliveredAt: UnixDate(at),
                capturedAt: UnixDate(at)
            ))
        }
    }
}
