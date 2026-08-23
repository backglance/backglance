import BackglanceCore
@testable import BackglanceUI
import Foundation
import XCTest

/// Covers `RulesSettingsModel`: what the pane lists, the debounced live preview over the
/// last 50 archived notifications, the inline compile error, the empty-pattern save gate,
/// and the export/import passthroughs.
///
/// See docs/features/RULES.md#ui-components, whose `RulesSettingsModelTests` row names the
/// four cases this file leads with: preview debounce, preview over 50 rows, inline error
/// surfaced, save blocked on empty pattern.
@MainActor
final class RulesSettingsModelTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - Preview debounce

    /// A second `refreshPreview(for:)` call cancels the first before its 200 ms delay
    /// elapses, so the first draft's compile result — deliberately an error here — must
    /// never land. If cancellation did not work, the two tasks would race to set
    /// `compileError` last, and this test would be flaky rather than reliably green; the
    /// cancellation is synchronous, so it isn't.
    func testRefreshPreviewDebouncesAndOnlyTheLastCallTakesEffect() async throws {
        let model = try makeModel()

        model.refreshPreview(for: Self.draft(pattern: "   ")) // would report .emptyPattern
        model.refreshPreview(for: Self.draft(pattern: "invoice")) // supersedes it
        await model.previewTask?.value

        XCTAssertNil(model.compileError, "the superseded call's error must never land")
    }

    /// A stale call that already started sleeping is what gets cancelled — a fresh call
    /// made after the first one has already finished must still run normally.
    func testRefreshPreviewRunsNormallyWhenCallsAreNotOverlapping() async throws {
        let model = try makeModel()

        model.refreshPreview(for: Self.draft(pattern: "   "))
        await model.previewTask?.value
        XCTAssertEqual(model.compileError?.kind, .emptyPattern)

        model.refreshPreview(for: Self.draft(pattern: "invoice"))
        await model.previewTask?.value
        XCTAssertNil(model.compileError, "a call made after the previous one finished is not stale")
    }

    // MARK: - Preview over 50 rows

    /// The live preview only ever evaluates the newest `previewSampleSize` (50) archived
    /// notifications, even when the archive holds more than that.
    func testPreviewIsCappedAtTheSampleSizeEvenWithMoreArchived() async throws {
        let archive = try XCTUnwrap(archive)
        let app = try archive.upsertApp(bundleID: "com.example.chat", now: Self.now)
        let appID = try XCTUnwrap(app.id)
        for offset in 0 ..< (RulesSettingsModel.previewSampleSize + 10) {
            _ = try archive.insertOrUpdate(ArchivedNotification(
                uuid: UUID().uuidString,
                appId: appID,
                title: "ping \(offset)",
                deliveredAt: UnixDate(Self.now.addingTimeInterval(TimeInterval(offset))),
                capturedAt: UnixDate(Self.now.addingTimeInterval(TimeInterval(offset)))
            ))
        }
        let model = try makeModel()

        model.refreshPreview(for: Self.draft(pattern: "ping"))
        await model.previewTask?.value

        XCTAssertEqual(model.preview.count, RulesSettingsModel.previewSampleSize)
    }

    // MARK: - Inline error surfaced

    func testRefreshPreviewSurfacesAnInlineErrorForAnEmptyPattern() async throws {
        let model = try makeModel()

        model.refreshPreview(for: Self.draft(pattern: "   "))
        await model.previewTask?.value

        XCTAssertEqual(model.compileError?.kind, .emptyPattern)
        XCTAssertTrue(model.preview.isEmpty, "an uncompilable draft has nothing to preview")
    }

    func testRefreshPreviewSurfacesAnInlineErrorForAnOverlongPattern() async throws {
        let model = try makeModel()

        model.refreshPreview(for: Self.draft(pattern: String(repeating: "a", count: RuleLimits.maxPatternLength + 1)))
        await model.previewTask?.value

        XCTAssertEqual(model.compileError?.kind, .patternTooLong)
    }

    // MARK: - Save blocked on empty pattern

    func testSaveIsBlockedOnAnEmptyPatternAndNeverTouchesTheArchive() async throws {
        let model = try makeModel()

        let saved = await model.save(Self.draft(pattern: "   "))

        XCTAssertFalse(saved)
        XCTAssertEqual(model.compileError?.kind, .emptyPattern)
        XCTAssertEqual(model.compileError?.message, "Enter something to match.")
        let archive = try XCTUnwrap(archive)
        XCTAssertTrue(try archive.allRules().isEmpty, "the archive was never touched")
    }

    /// The pattern is trimmed before the emptiness check, so leading/trailing whitespace
    /// around real content is not itself a reason to refuse the save.
    func testSaveTrimsThePatternBeforeSaving() async throws {
        let model = try makeModel()

        let saved = await model.save(Self.draft(pattern: "  invoice  "))

        XCTAssertTrue(saved)
        let archive = try XCTUnwrap(archive)
        let stored = try XCTUnwrap(archive.allRules().first)
        XCTAssertEqual(stored.pattern, "invoice")
    }

    // MARK: - Loading, saving, deleting, enabling

    func testWithoutAnArchiveNothingIsListedAndWritesAreNoOps() async {
        let model = RulesSettingsModel(archive: nil, engine: nil)

        await model.load()
        _ = await model.save(Self.draft(pattern: "invoice"))
        await model.delete(Self.draft(pattern: "invoice"))
        await model.setEnabled(false, for: Self.draft(pattern: "invoice"))

        XCTAssertTrue(model.rules.isEmpty)
        XCTAssertFalse(model.canImportExport)
    }

    func testSavingANewRuleInsertsItAndReloadsTheList() async throws {
        let model = try makeModel()

        let saved = await model.save(Self.draft(pattern: "invoice", kind: .vip, matchField: .sender, color: nil))

        XCTAssertTrue(saved)
        XCTAssertEqual(model.rules.map(\.pattern), ["invoice"])
        XCTAssertEqual(model.rules.first?.kind, .vip)
    }

    func testSavingAnExistingRuleUpdatesRatherThanDuplicates() async throws {
        let model = try makeModel()
        _ = await model.save(Self.draft(pattern: "invoice"))
        let existing = try XCTUnwrap(model.rules.first)

        var edited = existing
        edited.priority = 7
        _ = await model.save(edited)

        XCTAssertEqual(model.rules.count, 1, "the same rule was updated, not duplicated")
        XCTAssertEqual(model.rules.first?.priority, 7)
    }

    func testDeleteRemovesTheRuleFromTheArchive() async throws {
        let model = try makeModel()
        _ = await model.save(Self.draft(pattern: "invoice"))
        let saved = try XCTUnwrap(model.rules.first)

        await model.delete(saved)

        XCTAssertTrue(model.rules.isEmpty)
    }

    func testSetEnabledFlipsTheRowWithoutChangingAnythingElse() async throws {
        let model = try makeModel()
        _ = await model.save(Self.draft(pattern: "invoice"))
        let saved = try XCTUnwrap(model.rules.first)
        XCTAssertTrue(saved.isEnabled)

        await model.setEnabled(false, for: saved)

        let reloaded = try XCTUnwrap(model.rules.first)
        XCTAssertFalse(reloaded.isEnabled)
        XCTAssertEqual(reloaded.pattern, "invoice")
    }

    // MARK: - Warning badges

    /// A saved rule with a compile problem gets an entry in `problemsByRuleID`, keyed by
    /// its own id — what the list's orange badge reads.
    func testProblemsByRuleIDReflectsASavedRuleThatFailsToCompile() async throws {
        let archive = try XCTUnwrap(archive)
        // Saved directly, bypassing `save(_:)`'s own empty-pattern gate — an
        // overlong pattern is exactly the kind of problem RULES.md says a rule keeps and
        // shows a badge for, rather than one the editor refuses to save at all.
        let overlong = Self.draft(pattern: String(repeating: "a", count: RuleLimits.maxPatternLength + 1))
        try archive.saveRule(overlong)
        let model = try makeModel()

        await model.load()

        let id = try XCTUnwrap(model.rules.first?.id)
        XCTAssertEqual(model.problemsByRuleID[id]?.kind, .patternTooLong)
    }

    /// A disabled rule with a bad pattern gets no badge — `RulesEngine.compile(_:)` skips
    /// disabled rules before it can find anything wrong with them, and a badge on a row
    /// already switched off would warn about nothing the engine is even looking at.
    func testProblemsByRuleIDHasNoEntryForADisabledRule() async throws {
        let archive = try XCTUnwrap(archive)
        var overlong = Self.draft(pattern: String(repeating: "a", count: RuleLimits.maxPatternLength + 1))
        overlong.isEnabled = false
        try archive.saveRule(overlong)
        let model = try makeModel()

        await model.load()

        let id = try XCTUnwrap(model.rules.first?.id)
        XCTAssertNil(model.problemsByRuleID[id])
    }

    // MARK: - Export and import

    func testExportAndImportRoundTripThroughTheEngine() async throws {
        let archive = try XCTUnwrap(archive)
        let engine = RulesEngine(archive: archive)
        let model = RulesSettingsModel(archive: archive, engine: engine)
        _ = await model.save(Self.draft(pattern: "invoice"))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rules-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        await model.exportRules(to: url)
        XCTAssertNil(model.failure)

        let otherArchive = try Archive(inMemory: true)
        let otherEngine = RulesEngine(archive: otherArchive)
        let otherModel = RulesSettingsModel(archive: otherArchive, engine: otherEngine)

        await otherModel.importRules(from: url)

        XCTAssertEqual(otherModel.importResult, "1 imported, 0 skipped")
        XCTAssertEqual(otherModel.rules.map(\.pattern), ["invoice"])
    }

    /// Without an engine, the two file items have nothing to call through to — the model
    /// reports a failure rather than silently doing nothing.
    func testExportWithoutAnEngineReportsAFailure() async throws {
        let model = try makeModel(engine: nil)

        await model.exportRules(to: FileManager.default.temporaryDirectory.appendingPathComponent("unused.json"))

        XCTAssertNotNil(model.failure)
        XCTAssertFalse(model.canImportExport)
    }

    // MARK: Private

    private static let now = Date(timeIntervalSince1970: 1_787_236_200)

    private var archive: Archive?

    private static func draft(
        pattern: String,
        kind: Rule.Kind = .highlight,
        matchField: Rule.MatchField = .any,
        color: String? = HighlightColor.amber.rawValue
    ) -> Rule {
        Rule(kind: kind, pattern: pattern, matchField: matchField, color: color, createdAt: UnixDate(now))
    }

    private func makeModel(engine: RulesEngine? = nil) throws -> RulesSettingsModel {
        let archive = try XCTUnwrap(archive)
        return RulesSettingsModel(archive: archive, engine: engine)
    }
}
