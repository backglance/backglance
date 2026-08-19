import BackglanceCore
import Foundation

// MARK: - AppExclusionList

/// Which apps Backglance is allowed to archive.
///
/// > 🔒 The check runs against the *raw* store row's bundle id, before the payload is
/// > decoded, so an excluded app's notification is never turned into objects in memory,
/// > never redacted, never enriched and never logged. That ordering is the whole point:
/// > password managers put account names in their notifications, and the promise
/// > "excluded apps are never read" has to be true of the parse, not just of the insert
/// > (docs/features/CAPTURE.md#exclusion-before-parse).
///
/// The real list — `apps.is_excluded` plus the built-in defaults, reloaded when the user
/// toggles an app in Settings — arrives with the privacy controls. Until then the engine
/// takes one of these and the default allows everything.
public protocol AppExclusionList: Sendable {
    /// Whether notifications from `bundleID` may be archived.
    func allows(_ bundleID: String) -> Bool
}

// MARK: - AllowAllApps

/// The placeholder list: every app is archived.
///
/// Deliberately explicit rather than an optional the engine checks for `nil`. "No
/// exclusions configured" is a real policy, and naming it keeps the engine's pipeline
/// free of branches that would have to be removed later.
public struct AllowAllApps: AppExclusionList {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public func allows(_: String) -> Bool {
        true
    }
}

// MARK: - NotificationRedactor

/// Removes one-time codes and anything else that must not be archived.
///
/// > 🔒 Redaction happens in memory, before the insert, and is irreversible by design:
/// > the original digits must never reach the archive, the search index, an export or a
/// > log (Privacy Invariant #2). The returned ``RedactionEvent`` records *that* a
/// > redaction happened and which pattern fired — never what was redacted.
///
/// `OTPRedactor` implements this in the privacy milestone.
public protocol NotificationRedactor: Sendable {
    /// The notification as it should be archived, and the audit row to record with it.
    func redact(_ notification: ParsedNotification) -> (ParsedNotification, RedactionEvent?)
}

// MARK: - NoRedaction

/// The placeholder redactor: archives what was parsed.
public struct NoRedaction: NotificationRedactor {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public func redact(_ notification: ParsedNotification) -> (ParsedNotification, RedactionEvent?) {
        (notification, nil)
    }
}

// MARK: - NotificationEnricher

/// Fills in what the store does not carry — the app's icon, and where "Open" should go.
///
/// Asynchronous because resolving an app bundle touches the file system, and the engine
/// is an actor: enrichment must not block the tick that is holding it.
public protocol NotificationEnricher: Sendable {
    func enrich(_ notification: ParsedNotification) async -> ParsedNotification
}

// MARK: - NoEnrichment

/// The placeholder enricher: archives what was parsed.
public struct NoEnrichment: NotificationEnricher {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public func enrich(_ notification: ParsedNotification) async -> ParsedNotification {
        notification
    }
}

// MARK: - ArchiveOutcome

/// What became of one store record.
///
/// Counted rather than logged one by one: a tick that archived 3 of 40 records and
/// excluded the rest is a useful line in the log, while forty lines naming each record
/// would not be — and would be forty chances to interpolate something that should not be
/// there.
public enum ArchiveOutcome: Sendable, Equatable {
    /// Written to the archive.
    case archived

    /// The app is excluded. The payload was never decoded.
    case excluded

    /// Already archived — the first-launch import and live capture overlapping, which is
    /// the normal case rather than an error.
    case duplicate

    /// The record could not be parsed or written. Logged by `rec_id` and a fixed reason.
    case failed
}

// MARK: - ArchivedNotification + ParsedNotification

extension ArchivedNotification {
    /// The archive row for a parsed notification.
    ///
    /// - Parameters:
    ///   - parsed: the notification, already redacted and enriched.
    ///   - appID: the `apps` row it belongs to, from `Archive.upsertApp`.
    ///   - storeRecID: the store's `rec_id`, which is what makes a re-read idempotent.
    ///   - source: `.live` for the watcher, `.imports` for the first-launch import.
    ///   - capturedAt: when Backglance wrote it, which is not when it was delivered.
    init(
        parsed: ParsedNotification,
        appID: Int64,
        storeRecID: Int64,
        source: Source,
        capturedAt: Date
    ) {
        self.init(
            id: nil,
            uuid: parsed.uuid.uuidString,
            appId: appID,
            title: parsed.title,
            subtitle: parsed.subtitle,
            body: parsed.body,
            sender: parsed.sender,
            threadId: parsed.threadID,
            category: parsed.category,
            deliveredAt: UnixDate(parsed.deliveredAt),
            capturedAt: UnixDate(capturedAt),
            source: source,
            presented: parsed.presented,
            awaySessionId: nil,
            deepLink: parsed.deepLink?.absoluteString,
            attachmentsJson: Self.attachmentsJSON(parsed.attachments),
            redaction: .none,
            isRead: false,
            isPinned: false,
            isDeleted: false,
            storeRecId: storeRecID
        )
    }

    /// Attachment *metadata* as JSON, or `nil` when there is none.
    ///
    /// Encoding failure yields `nil` rather than throwing: an attachment list that will
    /// not encode is worth losing, and the notification it belongs to is not.
    private static func attachmentsJSON(_ attachments: [AttachmentMeta]) -> String? {
        guard !attachments.isEmpty, let data = try? JSONEncoder().encode(attachments) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
