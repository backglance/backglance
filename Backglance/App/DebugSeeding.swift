import BackglanceCore
import Foundation
import os

/// UI-test scaffolding; everything but the empty shell is compiled out of Release.
///
/// `BACKGLANCE_SEED_UNREAD=<n>` inserts `n` synthetic unread notifications into the
/// archive at launch — the archive `BACKGLANCE_ARCHIVE_PATH` has already redirected to a
/// temporary directory, never a real one. It exists because `BackglanceAppUITests`
/// deliberately links nothing: the one way a UI test can put rows on the timeline (for
/// the unread count in the status item's spoken label, the delete toast, the export
/// sheet) is to ask the app to put them there, the same way `BACKGLANCE_FAKE_FDA` asks
/// the probe for a particular answer. The rows are synthetic by construction — a fixed
/// bundle id and numbered placeholder text — so Privacy Invariant #5 is not in play.
enum DebugSeeding {
    #if DEBUG
        /// The environment variable naming how many unread rows to seed.
        static let unreadCountKey = "BACKGLANCE_SEED_UNREAD"

        /// The seeded rows' bundle id, distinct from any real app's.
        static let bundleID = "app.backglance.uitest.seeded"

        /// Seeds when asked, and says only how many — never what (Privacy Invariant #1,
        /// which holds even for synthetic rows because the rule is about log shape, not
        /// data sensitivity).
        static func seedIfAsked(_ archive: Archive, logger: Logger) {
            guard let raw = ProcessInfo.processInfo.environment[unreadCountKey],
                  let count = Int(raw), count > 0
            else {
                return
            }
            do {
                let app = try archive.upsertApp(bundleID: bundleID, now: .now)
                guard let appID = app.id else {
                    return
                }
                for index in 1 ... count {
                    // Staggered a second apart, newest last, so the timeline has a stable
                    // order to render; `isRead` defaults to false, which is the point.
                    _ = try archive.insert(ArchivedNotification(
                        uuid: UUID().uuidString,
                        appId: appID,
                        title: "Seeded notification \(index)",
                        body: "Synthetic row for UI tests",
                        deliveredAt: UnixDate(Date.now.addingTimeInterval(TimeInterval(index - count))),
                        capturedAt: UnixDate(.now),
                        source: .imports
                    ))
                }
                logger.notice("seeded \(count) synthetic unread rows for UI tests")
            } catch {
                let detail = (error as? ArchiveError)?.logDescription ?? ArchiveError.detail(from: error)
                logger.error("UI-test seeding failed: \(detail, privacy: .public)")
            }
        }
    #else
        /// Release builds keep the call site legal and the behaviour absent.
        static func seedIfAsked(_: Archive, logger _: Logger) {}
    #endif
}
