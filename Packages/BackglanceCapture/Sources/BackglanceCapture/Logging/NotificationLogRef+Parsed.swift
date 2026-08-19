import BackglanceCore
import Foundation

// MARK: - NotificationLogRef + ParsedNotification

public extension NotificationLogRef {
    /// A reference to a notification that has been parsed but not yet archived.
    ///
    /// 🔒 Lives here rather than beside the type because ``ParsedNotification`` belongs to
    /// the capture layer and `BackglanceCore` must not know about it
    /// (docs/architecture/ARCHITECTURE.md#dependency-graph). The rule it enforces is the
    /// same on both sides: a log call takes a reference, never the notification.
    init(_ notification: ParsedNotification) {
        self.init(
            id: notification.uuid.uuidString,
            bundleID: notification.bundleID,
            length: (notification.title?.count ?? 0)
                + (notification.subtitle?.count ?? 0)
                + (notification.body?.count ?? 0)
        )
    }
}

// MARK: - RedactingLogger + capture types

public extension RedactingLogger {
    @available(*, unavailable, message: "Never log a ParsedNotification. Use NotificationLogRef(_:).")
    func notice(_: StaticString, _: ParsedNotification) {}

    @available(*, unavailable, message: "Never log a ParsedNotification. Use NotificationLogRef(_:).")
    func error(_: StaticString, _: ParsedNotification, code _: Int? = nil) {}

    @available(*, unavailable, message: "Never log a RawStoreRecord. Log its recID and byte count.")
    func notice(_: StaticString, _: RawStoreRecord) {}
}
