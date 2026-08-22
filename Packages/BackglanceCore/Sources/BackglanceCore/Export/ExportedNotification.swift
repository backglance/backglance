import Foundation
import GRDB

// MARK: - ExportedNotification

/// One row of a CSV or JSON export — the schema table at
/// docs/features/EXPORT_AUTOMATION.md#exportednotification-schema, reproduced field for
/// field. `ExportService` is the only thing that constructs these, from the joined
/// `notifications`/`apps` row its own SQL selects (`Self.sql(for:)` in
/// `ExportService.swift`); nothing here reaches back into the archive on its own.
///
/// `Codable` with explicit snake_case `CodingKeys` rather than
/// `.convertToSnakeCase` on the encoder: the export is a public file format a user
/// might feed into a spreadsheet or a script, and its keys need to stay exactly what
/// this file says even if `JSONEncoder`'s key strategy ever changes. `CaseIterable`
/// exists only so a test can walk the keys in declaration order and check them
/// against `ExportService.csvHeader` without hand-copying the list a second time.
public struct ExportedNotification: Codable, Equatable, Sendable {
    // MARK: Lifecycle

    /// Builds one export row from a `Row` produced by `ExportService.sql(for:)`.
    ///
    /// - Parameters:
    ///   - row: must carry `uuid, bundle_id, display_name, title, subtitle, body,
    ///     sender, delivered_at, presented, away_session_id, redaction, deep_link,
    ///     attachments_json` — exactly the column list `ExportService.sql(for:)`
    ///     selects. Any other shape is a caller bug, not something worth guarding
    ///     against here.
    ///   - iso: the formatter `ExportService` builds once per export (`.current`
    ///     time zone, `.withInternetDateTime`) rather than one per row — an
    ///     `ISO8601DateFormatter` is expensive enough to construct that doing it
    ///     100k times would be a measurable fraction of a large export.
    public init(row: Row, iso: ISO8601DateFormatter) {
        uuid = row["uuid"]
        appBundleID = row["bundle_id"]
        appName = row["display_name"]
        title = row["title"]
        subtitle = row["subtitle"]
        body = row["body"]
        sender = row["sender"]

        let deliveredSeconds: Double = row["delivered_at"]
        deliveredAt = iso.string(from: Date(timeIntervalSince1970: deliveredSeconds))

        presented = row["presented"]

        let awaySessionID: Int64? = row["away_session_id"]
        missed = awaySessionID != nil

        let redaction: String = row["redaction"]
        redacted = redaction != "none"

        deepLink = row["deep_link"]

        let attachmentsJSON: String? = row["attachments_json"]
        attachments = Self.decodeAttachments(attachmentsJSON)
    }

    // MARK: Public

    /// One attachment's metadata, as it appears inside `notifications
    /// .attachments_json` — never the bytes. See
    /// docs/features/EXPORT_AUTOMATION.md#what-is-never-exported: the archive never
    /// held attachment bytes in the first place, so there is nothing an export could
    /// leak beyond what the store already told capture.
    ///
    /// Nested inside ``ExportedNotification`` rather than declared at the top level:
    /// `BackglanceCapture`'s `ParsedNotification.swift` already owns a top-level
    /// `AttachmentMeta` — the type that actually gets JSON-encoded into
    /// `attachments_json` at capture time — and `BackglanceCore` cannot import
    /// `BackglanceCapture` to reuse it (capture depends on the archive, never the
    /// other way around). A second top-level type of the same name would be
    /// ambiguous the moment any file imports both modules unqualified, which several
    /// already do. `name`/`size` are `Optional` for the same reason the capture-side
    /// type's are: `JSONEncoder`'s synthesized `Encodable` omits a nil `Optional`
    /// property's key entirely rather than writing `null`, so a real
    /// `attachments_json` value can legitimately be `{"type":"image"}` with no
    /// `name` or `size` key at all — decoding that here must succeed with `nil`
    /// fields, not fall through to ``decodeAttachments(_:)``'s "malformed" path and
    /// drop the whole array for a shape the archive writes on purpose.
    public struct AttachmentMeta: Codable, Equatable, Sendable {
        // MARK: Lifecycle

        public init(type: String, name: String? = nil, size: Int? = nil) {
            self.type = type
            self.name = name
            self.size = size
        }

        // MARK: Public

        public var type: String
        public var name: String?
        public var size: Int?
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case uuid
        case appBundleID = "app_bundle_id"
        case appName = "app_name"
        case title, subtitle, body, sender
        case deliveredAt = "delivered_at"
        case presented, missed, redacted
        case deepLink = "deep_link"
        case attachments
    }

    public var uuid: String
    public var appBundleID: String
    public var appName: String?
    public var title: String?
    public var subtitle: String?
    public var body: String?
    public var sender: String?
    public var deliveredAt: String // ISO 8601 with offset, local time zone
    public var presented: Bool
    public var missed: Bool
    public var redacted: Bool
    public var deepLink: String?
    public var attachments: [AttachmentMeta]

    /// This row's fields in exactly the schema table's column order — the same order
    /// as ``CodingKeys``, so `CSVWriter` never has to know a single archive column
    /// name. Booleans render as the literal strings `"true"`/`"false"`: CSV has no
    /// native boolean, and a spreadsheet reading `1`/`0` next to a `presented` header
    /// reads as a count, not a flag.
    ///
    /// ``attachments`` — the one non-scalar field — is inlined as a compact JSON
    /// array (`"[]"` when there are none) rather than dropped or summarized: a CSV
    /// cell can hold a string, and the metadata is small enough that a JSON string is
    /// more useful to a script reading the export than a lossy "2 attachments" note.
    public var csvFields: [String?] {
        [
            uuid,
            appBundleID,
            appName,
            title,
            subtitle,
            body,
            sender,
            deliveredAt,
            presented ? "true" : "false",
            missed ? "true" : "false",
            redacted ? "true" : "false",
            deepLink,
            Self.attachmentsCSVField(attachments),
        ]
    }

    // MARK: Private

    /// Decodes `attachments_json` into ``AttachmentMeta`` values, tolerating both a
    /// `NULL` column (a notification with no attachments) and malformed JSON (a
    /// future store shape this parser has not seen yet) as "no attachments" rather
    /// than throwing. A row whose attachment metadata cannot be decoded still has a
    /// title, a body, a sender — everything the export exists for — so it must still
    /// export; refusing the whole row over one unparseable side field would be a
    /// worse failure than an empty attachments array.
    private static func decodeAttachments(_ json: String?) -> [AttachmentMeta] {
        guard let json, let data = json.data(using: .utf8) else {
            return []
        }
        return (try? JSONDecoder().decode([AttachmentMeta].self, from: data)) ?? []
    }

    /// Compact (not pretty-printed) JSON, keys sorted so the same attachments array
    /// always renders as the same bytes — a diff-friendly export, and a stable target
    /// for a test comparing two CSV rows.
    private static func attachmentsCSVField(_ attachments: [AttachmentMeta]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard
            let data = try? encoder.encode(attachments),
            let json = String(bytes: data, encoding: .utf8)
        else {
            return "[]"
        }
        return json
    }
}
