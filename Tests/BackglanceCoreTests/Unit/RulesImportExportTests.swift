@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

/// Covers the `backglance.rules` v1 envelope (`RulesEngine+ImportExport.swift`,
/// `RulesDocument.swift`): the export round trip, duplicate skipping, format/version
/// mismatch, all-or-nothing rollback on a bad entry, and the two per-entry validation
/// rejections. See docs/features/RULES.md#ui-components's "Import and export" subsection.
final class RulesImportExportTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - Round trip

    /// Exporting a seeded archive and importing the result into a fresh, empty archive
    /// reproduces every rule's behaviour-defining fields. `id` and `createdAt` are
    /// deliberately not compared — `RulesDocument.Entry` never carries them, and a
    /// re-import is expected to mint new ones.
    func testExportThenImportRoundTripsEveryRuleField() throws {
        let source = try XCTUnwrap(archive)
        try insert(Self.vipRule, Self.muteRule, into: source)
        let engine = RulesEngine(archive: source)

        let data = try engine.exportRules()

        let destination = try Archive(inMemory: true)
        let destinationEngine = RulesEngine(archive: destination)
        let result = try destinationEngine.importRules(from: data)

        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.skipped, 0)

        let imported = try destination.pool.read { db in
            try Rule.order(Column("priority").desc, Column("id").asc).fetchAll(db)
        }
        XCTAssertEqual(imported.map(\.kind), [Self.vipRule.kind, Self.muteRule.kind])
        XCTAssertEqual(imported.map(\.pattern), [Self.vipRule.pattern, Self.muteRule.pattern])
        XCTAssertEqual(imported.map(\.matchField), [Self.vipRule.matchField, Self.muteRule.matchField])
        XCTAssertEqual(imported.map(\.appBundleId), [Self.vipRule.appBundleId, Self.muteRule.appBundleId])
        XCTAssertEqual(imported.map(\.priority), [Self.vipRule.priority, Self.muteRule.priority])
        XCTAssertEqual(imported.map(\.isEnabled), [Self.vipRule.isEnabled, Self.muteRule.isEnabled])
    }

    /// `exportRules()` orders `priority DESC, id ASC` — `compile(_:)`'s own sort — so the
    /// document's array order matches the settings list rather than whatever order SQLite
    /// happened to return rows in.
    func testExportOrdersByPriorityDescendingThenID() throws {
        let source = try XCTUnwrap(archive)
        // Inserted out of priority order on purpose, to prove export re-sorts rather than
        // just reflecting insertion order.
        try insert(Self.rule(kind: .mute, pattern: "low", priority: 0), into: source)
        try insert(Self.rule(kind: .highlight, pattern: "high", color: "amber", priority: 10), into: source)

        let engine = RulesEngine(archive: source)
        let document = try JSONDecoder().decode(RulesDocument.self, from: engine.exportRules())

        XCTAssertEqual(document.rules.map(\.pattern), ["high", "low"])
    }

    // MARK: - Duplicate skipping

    /// Importing the same document twice skips every entry the second time — duplicates
    /// are recognised by `(kind, pattern, matchField)` against rows already archived.
    func testReimportingTheSameDocumentSkipsEveryEntry() throws {
        let archive = try XCTUnwrap(archive)
        let engine = RulesEngine(archive: archive)
        let document = RulesDocument(rules: [
            RulesDocument.Entry(rule: Self.vipRule),
            RulesDocument.Entry(rule: Self.muteRule),
        ])
        let data = try JSONEncoder().encode(document)

        let first = try engine.importRules(from: data)
        XCTAssertEqual(first.imported, 2)
        XCTAssertEqual(first.skipped, 0)

        let second = try engine.importRules(from: data)
        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(second.skipped, 2)

        let count = try archive.pool.read { db in try Rule.fetchCount(db) }
        XCTAssertEqual(count, 2, "a duplicate import must not double the archive's rows")
    }

    /// Two identical entries in the *same* file are also a duplicate pair — the first is
    /// imported, the second is skipped against it, without ever touching the archive
    /// twice.
    func testDuplicateEntriesWithinTheSameFileAreSkipped() throws {
        let archive = try XCTUnwrap(archive)
        let engine = RulesEngine(archive: archive)
        let entry = RulesDocument.Entry(rule: Self.vipRule)
        let data = try JSONEncoder().encode(RulesDocument(rules: [entry, entry]))

        let result = try engine.importRules(from: data)

        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.skipped, 1)
    }

    // MARK: - Format and version

    /// A file whose `format` isn't `backglance.rules` — a `backglance.searches` file, say
    /// — is rejected before any entry is even looked at.
    func testFormatMismatchThrowsAndWritesNothing() throws {
        let archive = try XCTUnwrap(archive)
        let engine = RulesEngine(archive: archive)
        let document = RulesDocument(
            format: "backglance.searches",
            version: 1,
            rules: [RulesDocument.Entry(rule: Self.vipRule)]
        )
        let data = try JSONEncoder().encode(document)

        XCTAssertThrowsError(try engine.importRules(from: data)) { error in
            XCTAssertEqual(error as? RulesError, .importFormatMismatch("backglance.searches"))
        }
        let count = try archive.pool.read { db in try Rule.fetchCount(db) }
        XCTAssertEqual(count, 0)
    }

    /// A file whose `version` is newer than this build understands is rejected the same
    /// way — never guessed at.
    func testVersionNewerThanSupportedThrowsAndWritesNothing() throws {
        let archive = try XCTUnwrap(archive)
        let engine = RulesEngine(archive: archive)
        let document = RulesDocument(
            format: RulesDocument.currentFormat,
            version: 2,
            rules: [RulesDocument.Entry(rule: Self.vipRule)]
        )
        let data = try JSONEncoder().encode(document)

        XCTAssertThrowsError(try engine.importRules(from: data)) { error in
            XCTAssertEqual(error as? RulesError, .importVersionUnsupported(2))
        }
        let count = try archive.pool.read { db in try Rule.fetchCount(db) }
        XCTAssertEqual(count, 0)
    }

    // MARK: - All-or-nothing

    /// The whole point of validating every entry before opening the writer: a file whose
    /// third entry is invalid leaves the first two — which would otherwise import cleanly
    /// — unwritten too.
    func testAThirdInvalidEntryRollsBackTheWholeImport() throws {
        let archive = try XCTUnwrap(archive)
        let engine = RulesEngine(archive: archive)
        let document = RulesDocument(rules: [
            RulesDocument.Entry(rule: Self.vipRule),
            RulesDocument.Entry(rule: Self.muteRule),
            RulesDocument.Entry(rule: Self.rule(kind: .highlight, pattern: "   ", color: "amber")),
        ])
        let data = try JSONEncoder().encode(document)

        XCTAssertThrowsError(try engine.importRules(from: data)) { error in
            XCTAssertEqual(error as? RulesError, .invalidEntry(index: 2, reason: "the pattern is empty"))
        }
        let count = try archive.pool.read { db in try Rule.fetchCount(db) }
        XCTAssertEqual(count, 0, "a validation failure must leave the archive untouched, including the valid entries")
    }

    // MARK: - Per-entry validation

    /// A pattern that is empty after trimming whitespace is rejected, not silently
    /// coerced into anything.
    func testEmptyPatternIsRejected() throws {
        let engine = try RulesEngine(archive: XCTUnwrap(archive))
        let document = RulesDocument(rules: [RulesDocument.Entry(rule: Self.rule(kind: .mute, pattern: "   "))])
        let data = try JSONEncoder().encode(document)

        XCTAssertThrowsError(try engine.importRules(from: data)) { error in
            XCTAssertEqual(error as? RulesError, .invalidEntry(index: 0, reason: "the pattern is empty"))
        }
    }

    /// A pattern over `RuleLimits.maxPatternLength` characters is rejected the same way
    /// `compile(_:)` rejects one at compile time — the same bound, enforced at the door.
    func testOverLengthPatternIsRejected() throws {
        let engine = try RulesEngine(archive: XCTUnwrap(archive))
        let tooLong = String(repeating: "a", count: RuleLimits.maxPatternLength + 1)
        let document = RulesDocument(rules: [RulesDocument.Entry(rule: Self.rule(kind: .mute, pattern: tooLong))])
        let data = try JSONEncoder().encode(document)

        XCTAssertThrowsError(try engine.importRules(from: data)) { error in
            XCTAssertEqual(
                error as? RulesError,
                .invalidEntry(index: 0, reason: "the pattern is over \(RuleLimits.maxPatternLength) characters")
            )
        }
    }

    /// A `kind = .regex` entry whose pattern does not compile is rejected at import, even
    /// though v1.0 would only ever report it as "not available in this version" once
    /// installed — a bad pattern is still caught at the door rather than lying dormant.
    func testUncompilableRegexPatternIsRejected() throws {
        let engine = try RulesEngine(archive: XCTUnwrap(archive))
        let document = RulesDocument(rules: [
            RulesDocument.Entry(rule: Self.rule(kind: .regex, pattern: "(unclosed", color: "amber")),
        ])
        let data = try JSONEncoder().encode(document)

        XCTAssertThrowsError(try engine.importRules(from: data)) { error in
            XCTAssertEqual(error as? RulesError, .invalidEntry(index: 0, reason: "the regex pattern does not compile"))
        }
    }

    // MARK: Private

    private static let vipRule = rule(kind: .vip, pattern: "\"Ayse Yilmaz\"", field: .sender, priority: 10)
    private static let muteRule = rule(kind: .mute, pattern: "com.tinyspeck.slackmacgap", field: .app)

    private var archive: Archive?

    private static func rule(
        kind: Rule.Kind,
        pattern: String,
        field: Rule.MatchField = .any,
        appBundleID: String? = nil,
        color: String? = nil,
        priority: Int = 0
    ) -> Rule {
        Rule(
            id: nil,
            kind: kind,
            pattern: pattern,
            matchField: field,
            appBundleId: appBundleID,
            color: color,
            priority: priority,
            isEnabled: true,
            createdAt: UnixDate(Date(timeIntervalSince1970: 1_755_400_000))
        )
    }

    /// Inserts each rule directly through GRDB, the way a settings-editor save would —
    /// this suite is about import/export, not about `RulesEngine`'s own write paths.
    private func insert(_ rules: Rule..., into archive: Archive) throws {
        try archive.pool.write { db in
            for var rule in rules {
                try rule.insert(db)
            }
        }
    }
}
