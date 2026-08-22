import Foundation
import GRDB

// MARK: - RedactionActivity

/// How many codes were redacted, for one app, over some window.
///
/// > 🔒 A count and a bundle identifier. Nothing else, and there is nothing else to have:
/// > `redactions` stores `kind` and `pattern_id` and never the text it replaced, so this
/// > table could not show a code even if someone asked it to (Privacy Invariant #2).
///
/// The pane exists because redaction is irreversible and mostly invisible. Someone who
/// suspects Backglance mangled an order number needs a way to see that it is acting on their
/// messages at all — and someone who assumes it is protecting them deserves to find out if it
/// has never fired once.
public struct RedactionActivity: Sendable, Equatable, Identifiable, FetchableRecord {
    // MARK: Lifecycle

    public init(bundleID: String, displayName: String?, count: Int) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.count = count
    }

    public init(row: Row) {
        self.init(
            bundleID: row["bundle_id"],
            displayName: row["display_name"],
            count: row["redaction_count"]
        )
    }

    // MARK: Public

    public let bundleID: String

    /// The app's name where enrichment resolved one.
    public let displayName: String?

    /// How many redactions happened in the window.
    public let count: Int

    public var id: String {
        bundleID
    }

    /// The app's name, falling back to its bundle identifier.
    public var name: String {
        displayName ?? bundleID
    }
}

// MARK: - Archive + redaction activity

public extension Archive {
    /// Redaction counts per app since `date`, busiest first.
    ///
    /// Joined through `notifications` rather than counted straight off `redactions`, because
    /// an audit row belongs to a notification and a notification belongs to an app — and
    /// because the cascade means a redaction whose notification was pruned is already gone,
    /// which is the right answer: the pane reports on what the archive holds.
    ///
    /// - Parameter date: the start of the window. The pane uses thirty days.
    func redactionActivity(since date: Date, limit: Int = 50) throws -> [RedactionActivity] {
        let sql = """
        SELECT apps.bundle_id       AS bundle_id,
               apps.display_name    AS display_name,
               COUNT(*)             AS redaction_count
          FROM redactions
          JOIN notifications ON notifications.id = redactions.notification_id
          JOIN apps          ON apps.id          = notifications.app_id
         WHERE redactions.redacted_at >= ?
         GROUP BY apps.id
         ORDER BY redaction_count DESC, apps.bundle_id ASC
         LIMIT ?
        """
        do {
            return try pool.read { db in
                try RedactionActivity.fetchAll(db, sql: sql, arguments: [UnixDate(date), limit])
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }
}
