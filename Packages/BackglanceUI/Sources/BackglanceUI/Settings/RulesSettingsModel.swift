import BackglanceCore
import Foundation
import Observation

// MARK: - RulesSettingsModel

/// The Rules pane's state: the rule list, the editor draft's debounced live preview, and
/// the ••• menu's export/import passthroughs.
///
/// Two collaborators, not one, and for different reasons. `archive` is where rules
/// actually live — every read and write in this file goes through the one-shot helpers
/// `Archive+Rules.swift` adds for exactly this pane, the same shape
/// `RetentionSettingsModel` and `ExcludedAppsSettingsModel` already use for their own
/// tables. `engine` is only ever asked for two things, `exportRules()`/`importRules(from:)`
/// — this model does not reimplement the `backglance.rules` envelope
/// (docs/features/RULES.md#ui-components's "Import and export" subsection already
/// specifies it exactly, and `RulesEngine+ImportExport.swift` is where it lives). Compile
/// problems for the list's warning badges are **not** read from `engine.problems`: that
/// property mirrors whichever snapshot `RulesEngine.start()`'s observation last installed,
/// which can lag one write behind this pane's own `load()` — badges here are recomputed
/// straight from the rows this model just fetched, with the same static
/// `RulesEngine.compile(_:)` the engine itself calls, so the two can never show a
/// different verdict on the same row.
///
/// > ℹ️ **Info:** BACKGLANCE-211's pane-header sentence — "Rules change how Backglance
/// > shows notifications. They do not change what macOS delivers." — lives in
/// > `RulesSettingsView`, not here: it is fixed copy with nothing to observe, and this
/// > model's job is state, not strings that never change.
///
/// See docs/features/RULES.md#ui-components.
@MainActor
@Observable
public final class RulesSettingsModel {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - archive: where rules live and where the live preview reads its sample from.
    ///     `nil` — a preview, or a launch whose archive would not open — leaves the list
    ///     empty and every write a no-op, the same posture every other settings model in
    ///     this directory takes.
    ///   - engine: the app's one `RulesEngine`, for `exportRules()`/`importRules(from:)`
    ///     only. `nil` disables the ••• menu's two file items rather than showing controls
    ///     that would silently do nothing when pressed.
    public init(archive: Archive?, engine: RulesEngine?) {
        self.archive = archive
        self.engine = engine
    }

    // MARK: Public

    /// How many of the most recently delivered notifications the live preview evaluates a
    /// draft against — "the last 50 archived notifications" per
    /// docs/features/RULES.md#ui-components. A named constant rather than a literal `50`
    /// scattered across this file and its tests.
    public static let previewSampleSize = 50

    /// What the pane's `Table` lists: every archived rule, `priority DESC, id ASC`.
    public private(set) var rules: [Rule] = []

    /// Compile problems for the rows in ``rules``, keyed by `Rule.id` — the list's orange
    /// warning badge reads this to know which rows get one and what their tooltip says.
    /// Only ever has an entry for an *enabled* rule: `RulesEngine.compile(_:)` skips
    /// disabled rules before it can find anything wrong with them, the same way the badge
    /// itself would have nothing to warn about on a row already switched off.
    public private(set) var problemsByRuleID: [Int64: RuleCompileError] = [:]

    /// Set when a read or a write did not go through, so the pane can say the list is not
    /// reflecting anything rather than sit there looking authoritative.
    public private(set) var failure: String?

    /// The editor's inline error, under the pattern field — the same `RuleCompileError`
    /// `refreshPreview(for:)` computes for the draft, or the `.emptyPattern` problem
    /// `save(_:)` sets when it refuses to touch the archive at all. Cleared implicitly:
    /// the next `refreshPreview(for:)` call (the very next keystroke) always overwrites it
    /// with a fresh verdict, so there is no separate "clear the error" method to forget to
    /// call.
    public private(set) var compileError: RuleCompileError?

    /// Which of the last ``previewSampleSize`` archived notifications the draft passed to
    /// `refreshPreview(for:)` would have matched. Empty whenever `compileError` is set —
    /// an uncompilable draft has nothing to preview — and also empty, with
    /// ``previewError`` set instead, when the sample itself could not be read.
    public private(set) var preview: [ArchivedNotification] = []

    /// Set when the live preview's own archive read failed — distinct from ``failure``,
    /// which is this model's list-level read/write failure, because the two can be true
    /// at once (the list loaded fine earlier; the preview's read just failed) and the
    /// editor sheet only ever wants to say something about the one that is its business.
    public private(set) var previewError: String?

    /// What the last import did — "7 imported, 2 skipped" — or `nil` before the first
    /// import in this session. Cleared on the next `exportRules(to:)` call and on the
    /// start of every new `importRules(from:)` call, so a stale result from a previous
    /// file can never be mistaken for the current one's.
    public private(set) var importResult: String?

    /// Whether the ••• menu's Export Rules… / Import Rules… items are worth showing
    /// enabled: there is an engine to ask, the same `canRunCleanupNow`-shaped gate
    /// `RetentionSettingsModel` uses for its own button.
    public var canImportExport: Bool {
        engine != nil
    }

    /// Reads the rule list and recomputes ``problemsByRuleID``. Called on appearance, and
    /// again after every write, because the row that changed is the one the user is
    /// looking at.
    public func load() async {
        guard let archive else {
            return
        }
        do {
            let fetched = try await Task.detached { try archive.allRules() }.value
            rules = fetched
            problemsByRuleID = Self.problems(for: fetched)
            failure = nil
        } catch {
            failure = Self.message(for: error)
        }
    }

    /// Recompiles `draft` alone and re-runs it over ``previewSampleSize`` recently
    /// archived notifications, debounced at 200 ms so a mistyped pattern costs nothing —
    /// the exact contract docs/features/RULES.md#ui-components sketches, adapted from its
    /// illustrative `archive.reader.read` to the real `Archive.recentNotificationsForRulesPreview(limit:)`
    /// this task added.
    ///
    /// Cancels whatever the previous call started before scheduling its own delay, which
    /// is the entire debounce: a keystroke that arrives before the sleep elapses is what
    /// stops the stale evaluation from ever running, not a timer this method resets.
    public func refreshPreview(for draft: Rule) {
        previewTask?.cancel()
        previewTask = Task { [weak self, archive] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else {
                return
            }

            let (compiled, problems) = RulesEngine.compile([draft])
            compileError = problems.first
            guard problems.isEmpty else {
                preview = []
                return
            }
            guard let archive else {
                preview = []
                previewError = nil
                return
            }

            do {
                // `Self.previewSampleSize` is read here, on the actor, and handed in as a
                // plain `Int` — reading a `@MainActor` static property from inside the
                // detached closure below would isolation-hop for no reason and trips the
                // Swift 6 concurrency checker even though the value never changes.
                let limit = Self.previewSampleSize
                let sample = try await Task.detached {
                    try archive.recentNotificationsForRulesPreview(limit: limit)
                }.value
                guard !Task.isCancelled else {
                    return
                }
                preview = sample
                    .filter { row in
                        !RulesEngine.evaluate(row.notification, compiled: compiled, bundleID: row.bundleID)
                            .matchedRuleIDs.isEmpty
                    }
                    .map(\.notification)
                previewError = nil
            } catch {
                previewError = Self.message(for: error)
            }
        }
    }

    /// Trims `draft`'s pattern and refuses an empty one before the archive is touched,
    /// exactly as docs/features/RULES.md#ui-components specifies — an unsaved rule with
    /// nothing to match is not a rule that compiles to "match nothing forever", it is a
    /// mistake the editor should not let through.
    ///
    /// - Returns: whether the write went through. `false` for an empty pattern or a write
    ///   failure; the caller (`RuleEditorSheet`) reads this to decide whether to dismiss.
    @discardableResult
    public func save(_ draft: Rule) async -> Bool {
        var rule = draft
        rule.pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.pattern.isEmpty else {
            compileError = RuleCompileError(
                ruleID: rule.id ?? Rule.draftID,
                message: String(localized: "Enter something to match."),
                kind: .emptyPattern
            )
            return false
        }
        guard let archive else {
            return false
        }
        do {
            _ = try await Task.detached { try archive.saveRule(rule) }.value
            failure = nil
            compileError = nil
        } catch {
            failure = Self.message(for: error)
            return false
        }
        await load()
        return true
    }

    /// Deletes `rule`. A rule with a compile problem is never deleted on its own behalf —
    /// this is the one path that removes a row, and it only runs from the row's own
    /// Delete button.
    public func delete(_ rule: Rule) async {
        guard let archive, let id = rule.id else {
            return
        }
        do {
            try await Task.detached { try archive.deleteRule(id: id) }.value
            failure = nil
        } catch {
            failure = Self.message(for: error)
        }
        await load()
    }

    /// The list's per-row enable toggle.
    public func setEnabled(_ enabled: Bool, for rule: Rule) async {
        guard let archive, let id = rule.id else {
            return
        }
        do {
            try await Task.detached { try archive.setRuleEnabled(enabled, id: id) }.value
            failure = nil
        } catch {
            failure = Self.message(for: error)
        }
        await load()
    }

    /// The ••• menu's Export Rules… item. A passthrough to `RulesEngine.exportRules(to:)`
    /// — see this type's own doc comment for why nothing here rebuilds the
    /// `backglance.rules` envelope.
    public func exportRules(to url: URL) async {
        importResult = nil
        guard let engine else {
            failure = String(localized: "Rules can’t be exported right now.")
            return
        }
        do {
            try await Task.detached { try engine.exportRules(to: url) }.value
            failure = nil
        } catch {
            failure = Self.message(for: error)
        }
    }

    /// The ••• menu's Import Rules… item. Reads `url` and hands the bytes to
    /// `RulesEngine.importRules(from:)`, then turns the result into the "7 imported, 2
    /// skipped" sentence the sheet shows — see this type's own doc comment for why import
    /// itself is not reimplemented here.
    public func importRules(from url: URL) async {
        importResult = nil
        guard let engine else {
            failure = String(localized: "Rules can’t be imported right now.")
            return
        }
        do {
            let result = try await Task.detached {
                let data = try Data(contentsOf: url)
                return try engine.importRules(from: data)
            }.value
            importResult = String(localized: "\(result.imported) imported, \(result.skipped) skipped")
            failure = nil
        } catch {
            failure = Self.message(for: error)
        }
        await load()
    }

    // MARK: Internal

    /// The in-flight debounced preview task, if one is running. Not `private`, for the
    /// same reason `RulesEngine.debugSnapshot` isn't: `RulesSettingsModelTests` awaits
    /// this directly to know when a debounced `refreshPreview(for:)` call has actually
    /// finished, rather than sleeping a guessed-at duration past the 200 ms delay.
    var previewTask: Task<Void, Never>?

    // MARK: Private

    private let archive: Archive?
    private let engine: RulesEngine?

    /// Recompiles `rules` and turns the resulting `RuleCompileError`s into the
    /// `ruleID`-keyed map ``problemsByRuleID`` reads. A `compile(_:)` call never produces
    /// two problems for the same rule — the loop it runs `continue`s the moment it
    /// appends one — so the dictionary literal below can never collide.
    private static func problems(for rules: [Rule]) -> [Int64: RuleCompileError] {
        let (_, problems) = RulesEngine.compile(rules)
        return Dictionary(uniqueKeysWithValues: problems.map { ($0.ruleID, $0) })
    }

    /// One plain sentence for the pane's failure/error text, whatever kind of error
    /// produced it. `RulesError` first (import's own validation failures already read
    /// well, e.g. "Rule 3 in the file: the pattern is empty."), then `ArchiveError`, then
    /// the generic fallback every other settings model in this directory uses for
    /// anything else — a `DecodingError` from a malformed import file included, since a
    /// bespoke sentence for that case would still boil down to "this file isn't a rules
    /// file Backglance recognizes," which is already covered when the format check itself
    /// fails first for any file that was ever a real export.
    private static func message(for error: Error) -> String {
        if let rulesError = error as? RulesError {
            return rulesError.errorDescription ?? String(localized: "The archive could not be read.")
        }
        return (error as? ArchiveError)?.errorDescription ?? String(localized: "The archive could not be read.")
    }
}
