import Foundation

// MARK: - RulesError

/// Errors from the instance side of `RulesEngine` — everything that is not a per-rule
/// compile problem. A bad pattern is a ``RuleCompileError``, collected in
/// `RulesEngine.problems` and never thrown, because one bad rule must never take triage down
/// for the other rules in the set. `RulesError` is for the handful of things that really are
/// exceptional: an archive write that named a row which is not there, or a `backglance.rules`
/// import that cannot be trusted as-is.
///
/// The three import cases below are `RulesEngine.importRules(from:)`'s
/// (`RulesEngine+ImportExport.swift`) — see docs/features/RULES.md#ui-components's "Import
/// and export" subsection for the envelope they validate against.
public enum RulesError: Error, Equatable, Sendable {
    /// `setAppMuted(bundleID:muted:)` touched no row: no archived app has this bundle id.
    case unknownApp(String)

    /// Entry `index` (zero-based, its position in the file's `rules` array) failed
    /// validation before anything was written — an empty or over-length pattern, or a
    /// `kind = .regex` pattern that does not compile. `reason` is a short, fixed sentence
    /// fragment this package writes itself; it never echoes the entry's own `pattern`,
    /// which is user-authored text that may repeat notification content.
    case invalidEntry(index: Int, reason: String)

    /// The envelope's `format` field was not `RulesDocument.currentFormat`
    /// (`"backglance.rules"`) — most often a `backglance.searches` file, or an
    /// unrelated JSON file, dropped into the wrong import sheet.
    case importFormatMismatch(String)

    /// The envelope's `version` field is newer than `RulesDocument.currentVersion` — a
    /// file exported by a newer build of Backglance than the one importing it.
    case importVersionUnsupported(Int)
}

// MARK: LocalizedError

extension RulesError: LocalizedError {
    /// One plain sentence for the UI, matching `ArchiveError.userMessage`'s posture: no
    /// paths, no SQL. `bundleID` is safe here — it is the app identifier the settings pane
    /// already shows next to every rule and every per-app setting, never notification
    /// content.
    public var errorDescription: String? {
        switch self {
        case let .unknownApp(bundleID):
            "No archived app with bundle id \(bundleID)."

        case let .invalidEntry(index, reason):
            "Rule \(index + 1) in the file: \(reason)."

        case let .importFormatMismatch(format):
            "This file's format is \"\(format)\", not a rules file Backglance recognizes."

        case let .importVersionUnsupported(version):
            "This file needs a newer version of Backglance to import (rules format v\(version))."
        }
    }
}
