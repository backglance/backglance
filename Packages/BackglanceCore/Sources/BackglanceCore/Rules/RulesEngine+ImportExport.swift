import Foundation
import GRDB

// MARK: - RulesEngine + import/export

/// `backglance.rules` v1 export and import — Settings ▸ Rules ▸ ••• per
/// docs/features/RULES.md#ui-components's "Import and export" subsection, which is the
/// exact contract this file implements.
///
/// Both directions go through ``RulesDocument``, never `Rule` directly — see that type's
/// own doc comment for why an id and a `createdAt` cannot travel in a file. Import treats
/// `(kind, pattern, matchField)` as a rule's identity: the same triple `compile(_:)` and
/// the settings editor already use to distinguish one rule from another, so "this rule
/// already exists" means the same thing on the way in as it does everywhere else.
extension RulesEngine {
    /// Every archived rule as a pretty-printed, key-sorted `backglance.rules` v1 document.
    ///
    /// Ordered `priority DESC, id ASC` — `compile(_:)`'s own sort — so importing this file
    /// into an empty archive reproduces the rules in the same order the settings list
    /// already shows them, rather than whatever order SQLite happened to return rows in.
    ///
    /// - Throws: ``ArchiveError/observationFailed(_:)`` if the archive read fails, the
    ///   same wrapping `Archive+Digest.swift`'s reads use. Encoding a ``RulesDocument``
    ///   cannot itself fail — every field is a plain `String`, `Int`, `Bool`, or
    ///   `String?` — so nothing from `JSONEncoder` reaches a caller here.
    public func exportRules() throws -> Data {
        let rules: [Rule]
        do {
            rules = try archive.pool.read { db in
                try Rule
                    .order(Column("priority").desc, Column("id").asc)
                    .fetchAll(db)
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }

        let document = RulesDocument(rules: rules.map(RulesDocument.Entry.init(rule:)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    /// `exportRules()`, written to `url` — the Settings ▸ Rules ▸ Export… path. Nothing
    /// else: a rules file is at most a few hundred short rows, nothing like the timeline
    /// export's row-by-row stream in `ExportService`, so there is no partial-write case
    /// worth guarding here beyond what `Data.write(to:options:)` already gives for free.
    public func exportRules(to url: URL) throws {
        try exportRules().write(to: url, options: .atomic)
    }

    /// Decodes a `backglance.rules` document from `data` and writes every entry that
    /// isn't a duplicate into the archive, in one transaction.
    ///
    /// - Returns: `imported` is how many new rows were inserted; `skipped` is how many
    ///   entries matched an existing rule — in the archive already, or earlier in this
    ///   same file — by `(kind, pattern, matchField)`, and were left alone rather than
    ///   duplicated.
    /// - Throws: ``RulesError/importFormatMismatch(_:)`` when `format` is not
    ///   `RulesDocument.currentFormat`; ``RulesError/importVersionUnsupported(_:)`` when
    ///   `version` is newer than `RulesDocument.currentVersion`;
    ///   ``RulesError/invalidEntry(index:reason:)`` for the first entry, by file
    ///   position, that fails validation. A `DecodingError` propagates unwrapped if
    ///   `data` is not well-formed JSON at all — that is a different failure from "this
    ///   is a rules file with a problem," and this method does not disguise one as the
    ///   other.
    ///
    ///   Every entry is validated **before** anything is written — trimmed to check for
    ///   empty or over-`RuleLimits.maxPatternLength` patterns, and, for `kind == .regex`
    ///   entries, run through `NSRegularExpression(pattern:)` — so any throw here leaves
    ///   the archive exactly as it was. `NSRegularExpression`, not the `RegexRuleEvaluator`
    ///   RULES.md's prose sketches: v1.0 has no such type yet
    ///   (`RuleLimits.regexRulesEnabled` is `false`, see `RulesEngine+Compile.swift`), so
    ///   this is the closest thing to "compiles as a regex" this version has to check
    ///   with. A regex entry that passes this validation still compiles, once installed,
    ///   to `RuleCompileError.Kind.notAvailableInThisVersion` and matches nothing — import
    ///   only promises the *pattern* is well-formed, not that the rule does anything yet.
    ///
    ///   Reasons never repeat the entry's own `pattern` back: it is user-authored text
    ///   that may echo notification content, and an error string is exactly the kind of
    ///   place that content must never end up (Privacy Invariant #1).
    public func importRules(from data: Data) throws -> (imported: Int, skipped: Int) {
        let document = try JSONDecoder().decode(RulesDocument.self, from: data)

        guard document.format == RulesDocument.currentFormat else {
            throw RulesError.importFormatMismatch(document.format)
        }
        guard document.version <= RulesDocument.currentVersion else {
            throw RulesError.importVersionUnsupported(document.version)
        }

        var validated: [RulesDocument.Entry] = []
        validated.reserveCapacity(document.rules.count)
        for (index, entry) in document.rules.enumerated() {
            var entry = entry
            entry.pattern = entry.pattern.trimmingCharacters(in: .whitespacesAndNewlines)

            if let reason = Self.invalidReason(for: entry) {
                throw RulesError.invalidEntry(index: index, reason: reason)
            }

            validated.append(entry)
        }

        do {
            return try archive.pool.write { db in
                var seen = try Set(Rule.fetchAll(db).map(Self.duplicateKey))
                var imported = 0
                var skipped = 0
                let now = Date()

                for entry in validated {
                    guard seen.insert(Self.duplicateKey(entry)).inserted else {
                        skipped += 1
                        continue
                    }
                    var rule = entry.rule(now: now)
                    try rule.insert(db)
                    imported += 1
                }
                return (imported, skipped)
            }
        } catch let error as RulesError {
            throw error
        } catch {
            throw ArchiveError.writeFailed(table: Rule.databaseTableName, underlying: ArchiveError.detail(from: error))
        }
    }

    // MARK: Private

    /// The reason `entry` fails `importRules(from:)`'s pre-write validation, or `nil` if
    /// it passes — pulled out of that method purely to keep the entry's `pattern` already
    /// trimmed and its three checks off the top-level function's line count; the checks
    /// themselves, and the "never echo the pattern back" rule they follow, are unchanged.
    private static func invalidReason(for entry: RulesDocument.Entry) -> String? {
        if entry.pattern.isEmpty {
            return String(localized: "the pattern is empty")
        }
        if entry.pattern.count > RuleLimits.maxPatternLength {
            return String(localized: "the pattern is over \(RuleLimits.maxPatternLength) characters")
        }
        if entry.kind == .regex, (try? NSRegularExpression(pattern: entry.pattern)) == nil {
            return String(localized: "the regex pattern does not compile")
        }
        return nil
    }

    /// What `importRules(from:)` treats as "this is the same rule" on both sides of the
    /// comparison — an already-archived row and a file entry alike. Deliberately just the
    /// three fields RULES.md names, not `appBundleID`/`color`/`priority`/`isEnabled`: two
    /// entries that differ only in, say, `priority` are still "the same rule" for import's
    /// purposes, and re-importing a file after tweaking a colour in the archive should
    /// skip the row, not duplicate it.
    private struct DuplicateKey: Hashable {
        let kind: Rule.Kind
        let pattern: String
        let matchField: Rule.MatchField
    }

    private static func duplicateKey(_ rule: Rule) -> DuplicateKey {
        DuplicateKey(kind: rule.kind, pattern: rule.pattern, matchField: rule.matchField)
    }

    private static func duplicateKey(_ entry: RulesDocument.Entry) -> DuplicateKey {
        DuplicateKey(kind: entry.kind, pattern: entry.pattern, matchField: entry.matchField)
    }
}
