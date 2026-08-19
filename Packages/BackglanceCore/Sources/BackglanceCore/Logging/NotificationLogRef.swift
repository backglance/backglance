import Foundation

// MARK: - NotificationLogRef

/// The only thing about a notification that may be logged.
///
/// 🔒 Privacy Invariant #1 says notification content never reaches a log. This type is how
/// that stops being a rule people have to remember: a log call cannot take a notification,
/// only a reference built from one, and a reference has nowhere to put text. There is no
/// initializer that accepts a title, and no property that could hold one.
///
/// What it carries is what a bug report actually needs. An id to correlate with the
/// archive, a bundle id to know which app misbehaved, and a length — "body 0 characters"
/// versus "body 240 characters" is the difference between a parser bug and a display bug,
/// and neither answer requires reading the body.
///
/// See docs/operations/MONITORING_LOGGING.md#type-level-design.
public struct NotificationLogRef: Sendable, Hashable, CustomStringConvertible {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - id: the archive uuid, or `"unsaved"` before the row exists.
    ///   - bundleID: the posting app — the one identifier Backglance logs.
    ///   - length: characters of title, subtitle and body together.
    public init(id: String, bundleID: String, length: Int) {
        self.id = id
        self.bundleID = bundleID
        self.length = length
    }

    /// A reference to an archived notification.
    ///
    /// `bundleID` is passed in rather than read from the row because the row holds an
    /// `app_id`, and resolving it is the caller's business — a logger has no reason to
    /// touch the database.
    public init(_ notification: ArchivedNotification, bundleID: String) {
        self.init(
            id: notification.uuid,
            bundleID: bundleID,
            length: (notification.title?.count ?? 0)
                + (notification.subtitle?.count ?? 0)
                + (notification.body?.count ?? 0)
        )
    }

    // MARK: Public

    public let id: String
    public let bundleID: String
    public let length: Int

    public var description: String {
        "notif(id=\(id.prefix(8)) app=\(bundleID) len=\(length))"
    }
}
