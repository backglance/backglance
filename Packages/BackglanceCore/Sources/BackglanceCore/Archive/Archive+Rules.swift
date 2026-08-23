import Foundation
import GRDB

// MARK: - Archive + rules CRUD

/// The one-shot rule reads and writes the Rules settings pane needs (BACKGLANCE-209).
///
/// `Archive+RulesObservation.swift`'s `rulesSnapshots()` is what `RulesEngine` subscribes
/// to for live triage; this file is its opposite number — plain `pool.read`/`pool.write`
/// calls for a settings model that reloads explicitly after every write, the same shape
/// `Archive+Privacy.swift` gives `RetentionSettingsModel` and `ExcludedAppsSettingsModel`.
/// `BackglanceUI` carries no GRDB dependency at all (see that package's own manifest
/// comment), so every `Column(...)`/`.fetchAll(db)` call the settings model would
/// otherwise need to make lives here instead.
public extension Archive {
    /// Every rule, ordered `priority DESC, id ASC` — the same order `RulesEngine.compile(_:)`
    /// walks and `exportRules()` writes, so the settings list shows rules in the order
    /// they are actually evaluated in rather than SQLite's insertion order.
    func allRules() throws -> [Rule] {
        do {
            return try pool.read { db in
                try Rule.order(Column("priority").desc, Column("id").asc).fetchAll(db)
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// Inserts `rule` when it has no `id` yet, or updates the existing row otherwise.
    ///
    /// - Returns: the row as it now stands, with `id` filled in for a fresh insert —
    ///   `RulesSettingsModel.save(_:)` does not need it (it reloads the whole list
    ///   afterwards, the same as every other settings model's write path), but a caller
    ///   that does need the new id has it without a second read.
    @discardableResult
    func saveRule(_ rule: Rule) throws -> Rule {
        do {
            return try pool.write { db in
                var rule = rule
                if rule.id == nil {
                    try rule.insert(db)
                } else {
                    try rule.update(db)
                }
                return rule
            }
        } catch {
            throw ArchiveError.writeFailed(
                table: Rule.databaseTableName,
                underlying: ArchiveError.detail(from: error)
            )
        }
    }

    /// Deletes one rule by id.
    ///
    /// A rule the engine could not compile is never deleted or silently rewritten on its
    /// own (docs/features/RULES.md#edge-cases-and-error-handling) — this is the one path
    /// that removes a row, and it only runs when the user presses Delete.
    func deleteRule(id: Int64) throws {
        do {
            _ = try pool.write { db in try Rule.deleteOne(db, key: id) }
        } catch {
            throw ArchiveError.writeFailed(
                table: Rule.databaseTableName,
                underlying: ArchiveError.detail(from: error)
            )
        }
    }

    /// Flips one rule's `is_enabled` column without touching anything else about it — the
    /// settings list's per-row toggle.
    func setRuleEnabled(_ enabled: Bool, id: Int64) throws {
        do {
            try pool.write { db in
                try Rule.filter(Column("id") == id).updateAll(db, Column("is_enabled").set(to: enabled))
            }
        } catch {
            throw ArchiveError.writeFailed(
                table: Rule.databaseTableName,
                underlying: ArchiveError.detail(from: error)
            )
        }
    }
}

// MARK: - Archive + rules preview

public extension Archive {
    /// The `limit` most recently delivered, non-deleted notifications, each paired with
    /// its app's bundle id where one resolves — exactly what the Rules pane's live preview
    /// (BACKGLANCE-209) needs to evaluate a draft rule against, and nothing a draft
    /// evaluation doesn't need: no title/body processing happens here, only what
    /// `RulesEngine.evaluate(_:compiled:bundleID:)` itself takes as arguments.
    ///
    /// Reuses `ArchivedNotification.recent(limit:)`, which until this method had no
    /// `Archive`-level caller — the popover's own "recent" surface is
    /// `timelinePage(after:limit:)` instead. Apps are fetched whole rather than joined
    /// per row, the same trade-off `appsByID()` documents: the app table is tiny next to
    /// even fifty notifications.
    ///
    /// - Parameter limit: `RulesSettingsModel.previewSampleSize` in production; a
    ///   parameter rather than a hardcoded `50` so `RulesSettingsModelTests` can exercise
    ///   the "over 50 rows" case with a smaller, faster fixture.
    func recentNotificationsForRulesPreview(
        limit: Int
    ) throws -> [(notification: ArchivedNotification, bundleID: String?)] {
        do {
            return try pool.read { db in
                let rows = try ArchivedNotification.recent(limit: limit).fetchAll(db)
                let apps = try AppRecord.fetchAll(db)
                let bundleIDs = Dictionary(uniqueKeysWithValues: apps.compactMap { app in
                    app.id.map { ($0, app.bundleId) }
                })
                return rows.map { (notification: $0, bundleID: bundleIDs[$0.appId]) }
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }
}
