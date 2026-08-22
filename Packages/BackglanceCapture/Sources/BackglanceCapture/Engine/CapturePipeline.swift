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
/// ``PerAppOTPRedaction`` is the shipped implementation.
public protocol NotificationRedactor: Sendable {
    /// The notification as it should be archived, and the audit row to record with it.
    ///
    /// - Parameter appRedactsOTP: the app row's `redact_otp`. Passed in rather than
    ///   looked up, because the engine already holds the `AppRecord` from the upsert and
    ///   a second query per notification would buy nothing. It also keeps this protocol
    ///   synchronous and free of the archive, which is what lets a redactor be tested
    ///   against plain values.
    func redact(
        _ notification: ParsedNotification,
        appRedactsOTP: Bool
    ) -> (ParsedNotification, RedactionEvent?)
}

// MARK: - NoRedaction

/// The redactor that archives what was parsed.
///
/// Not a placeholder any more: it is what a test uses when redaction is not what it is
/// testing, and what the engine falls back to when no redactor is injected.
public struct NoRedaction: NotificationRedactor {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public func redact(
        _ notification: ParsedNotification,
        appRedactsOTP _: Bool
    ) -> (ParsedNotification, RedactionEvent?) {
        (notification, nil)
    }
}

// MARK: - PerAppOTPRedaction

/// The shipped redactor: ``OTPRedactor``, run on the apps the user has it on for.
///
/// > 🔒 The gate is *which* apps, never *whether* the result is written. Once the
/// > redactor has fired, the digits are gone from the value the engine goes on to insert
/// > — there is no branch here that keeps the original around for anything, and no
/// > logging of what was matched (Privacy Invariant #2).
///
/// The policy is read per notification rather than captured at construction, so that
/// switching "Redact codes in all apps" on takes effect on the next notification instead
/// of the next launch. `UserDefaults.bool(forKey:)` is a cached lookup, and the redactor
/// itself does far more work than the read that gated it.
///
/// See docs/features/PRIVACY_CONTROLS.md#per-app-toggle-and-redact-codes-in-all-apps.
public struct PerAppOTPRedaction: NotificationRedactor {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - redactor: the matcher. Injectable so a test can pin one language's keywords.
    ///   - defaults: where `privacy.redactOTPInAllApps` lives.
    public init(redactor: OTPRedactor = .default, defaults: UserDefaults = .standard) {
        self.redactor = redactor
        self.defaults = defaults
    }

    // MARK: Public

    public func redact(
        _ notification: ParsedNotification,
        appRedactsOTP: Bool
    ) -> (ParsedNotification, RedactionEvent?) {
        guard RedactionPolicy(defaults: defaults).redacts(appRedactsOTP: appRedactsOTP) else {
            return (notification, nil)
        }
        return notification.redactingOTP(with: redactor)
    }

    // MARK: Private

    private let redactor: OTPRedactor
    private let defaults: UserDefaults
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
    /// Written to the archive as a new row.
    case archived

    /// The store re-delivered a notification the archive already had — a thread update —
    /// and the existing row was refreshed in place.
    case updated

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
