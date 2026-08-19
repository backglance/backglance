import Foundation

// MARK: - RawStoreRecord

/// One row of Apple's `record` table, as read, with nothing decoded.
///
/// ⚠️ The shape of this type is an observation of an undocumented database, verified by
/// the fixtures under `Tests/Fixtures/SystemStore/`, not an API. It is the single place
/// where per-OS column differences stop: adapters translate their own layout into this,
/// and everything downstream — ``RecordParser``, the exclusion check, redaction, the
/// archive — speaks only this vocabulary.
///
/// ``plistData`` is carried as opaque bytes on purpose. Decoding it is what exposes
/// notification content, so it happens once, later, in ``RecordParser`` and only after
/// the exclusion check has cleared the app (docs/features/CAPTURE.md#exclusion-before-parse).
/// A raw record is therefore cheap to hold, cheap to skip, and safe to count.
///
/// > 🔒 The payload must never reach a log. ``description`` and ``debugDescription`` are
/// > overridden to the content-free ``logDescription`` precisely so that an accidental
/// > `"\(record)"` prints a byte count instead of the notification. Do not add a
/// > synthesized dump — the default reflection output would print the plist bytes.
public struct RawStoreRecord: Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        recID: Int64,
        appIdentifier: String,
        uuid: UUID,
        plistData: Data,
        deliveredDate: Date?,
        requestDate: Date?,
        presented: Bool,
        style: Int?
    ) {
        self.recID = recID
        self.appIdentifier = appIdentifier
        self.uuid = uuid
        self.plistData = plistData
        self.deliveredDate = deliveredDate
        self.requestDate = requestDate
        self.presented = presented
        self.style = style
    }

    // MARK: Public

    /// The store's `record.rec_id`. The cursor's unit of progress, the batch's sort key,
    /// and — as `notifications.store_rec_id` — what makes a re-read idempotent.
    public let recID: Int64

    /// The bundle identifier from the joined `app` row, e.g. `com.apple.MobileSMS`.
    ///
    /// Not content: bundle ids are the one identifier Backglance logs, because the
    /// exclusion check, per-app retention and the degraded-mode diagnostics are all
    /// unusable without them (docs/operations/MONITORING_LOGGING.md).
    public let appIdentifier: String

    /// The store's `record.uuid`, decoded from its 16-byte BLOB by the adapter. Adapters
    /// substitute a fresh UUID when the blob is not 16 bytes; deduplication then rests on
    /// ``recID`` alone, which is the stronger key anyway.
    public let uuid: UUID

    /// The undecoded `record.data` binary plist. Everything the user would recognise as
    /// "the notification" is in here, still encoded.
    public let plistData: Data

    /// When the notification was delivered, converted from the store's Cocoa reference
    /// seconds. `nil` for rows that were never delivered — scheduled or withdrawn
    /// requests — which the engine skips rather than archiving with a made-up date.
    public let deliveredDate: Date?

    /// When the app asked for the notification, if the store recorded it. Informational.
    public let requestDate: Date?

    /// Whether the banner was actually shown. The digest's "you missed this" heuristic
    /// rests on this being `false` (docs/features/MISSED_DIGEST.md).
    public let presented: Bool

    /// The store's `style` column, kept as the raw integer. Its meaning is not documented
    /// and Backglance does not branch on it; it is carried so a future adapter or a
    /// diagnostics export can report what was there.
    public let style: Int?

    /// Content-free identification, safe for `os_log` with `privacy: .public`.
    ///
    /// A byte count rather than the bytes: enough to tell "empty payload" from "a record
    /// we failed to parse", which is the only thing a log line needs about the payload.
    public var logDescription: String {
        "rec \(recID) app=\(appIdentifier) bytes=\(plistData.count)"
    }
}

// MARK: CustomStringConvertible, CustomDebugStringConvertible

extension RawStoreRecord: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        logDescription
    }

    public var debugDescription: String {
        logDescription
    }
}
