import Foundation

// MARK: - ParsedNotification

/// One notification, decoded out of Apple's store and ready to be triaged and archived.
///
/// This is the first point in the capture pipeline where the notification exists as text
/// rather than as bytes, which makes it the most sensitive value type in the package. It
/// is created after the exclusion check has cleared the app, handed to redaction, and then
/// to the archive; it is never logged, never exported as-is, and never held longer than
/// the record that produced it.
///
/// > 🔒 ``description`` and ``debugDescription`` render ``logDescription`` — an identifier
/// > and some lengths — so that an accidental `"\(parsed)"` in a log call cannot leak the
/// > notification. Do not remove those conformances, and do not add `Codable`: this type
/// > has no business being serialised anywhere.
///
/// Every field except ``bundleID``, ``uuid`` and ``deliveredAt`` is optional, because the
/// store's plist keys are undocumented and absence is normal rather than exceptional. See
/// docs/features/CAPTURE.md#recordparser.
public struct ParsedNotification: Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        bundleID: String,
        uuid: UUID,
        title: String? = nil,
        subtitle: String? = nil,
        body: String? = nil,
        sender: String? = nil,
        threadID: String? = nil,
        category: String? = nil,
        deliveredAt: Date,
        presented: Bool,
        attachments: [AttachmentMeta] = [],
        deepLink: URL? = nil,
        userInfo: [String: String] = [:]
    ) {
        self.bundleID = bundleID
        self.uuid = uuid
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.sender = sender
        self.threadID = threadID
        self.category = category
        self.deliveredAt = deliveredAt
        self.presented = presented
        self.attachments = attachments
        self.deepLink = deepLink
        self.userInfo = userInfo
    }

    // MARK: Public

    /// The app that posted it. The one identifier Backglance logs.
    public var bundleID: String

    /// The store's record UUID, carried through so the archive's unique index has
    /// something stable to work with.
    public var uuid: UUID

    public var title: String?

    public var subtitle: String?

    public var body: String?

    /// Who it is from, where the app said so or where it can be read off the title. Filled
    /// by the parser's heuristics, not by a store column.
    public var sender: String?

    /// The app's own grouping key — a conversation, an issue, a build. What the timeline
    /// collapses a run of notifications by.
    public var threadID: String?

    /// The app's notification category, which is what its actions were registered under.
    public var category: String?

    /// When it was delivered. Never optional here: a notification with no time cannot be
    /// placed on a timeline, so the parser resolves one or rejects the record.
    public var deliveredAt: Date

    /// Whether the banner was shown. `false` is what the missed digest is built from.
    public var presented: Bool

    /// Metadata about attachments — type, name, size. Never the bytes: Backglance does not
    /// copy attachment payloads out of the store, so an archived notification cannot
    /// resurrect an image the user has since deleted.
    public var attachments: [AttachmentMeta]

    /// Where "Open" should take the user. The parser leaves this `nil`; `EnrichmentService`
    /// fills it in from ``userInfo`` using a per-app resolver.
    public var deepLink: URL?

    /// The app's own `userInfo`, flattened to strings. Non-string values are dropped
    /// rather than described: a coerced blob would be noise at best and a leak vector at
    /// worst, and the deep-link resolvers only ever read strings.
    public var userInfo: [String: String]

    /// Whether there is anything a person could actually read.
    ///
    /// The store holds rows that are not notifications in any user-facing sense — cleared
    /// placeholders, bookkeeping for a request that was never delivered. Archiving those
    /// would put blank entries in the timeline, so the parser rejects a record with no
    /// text and no attachments.
    public var hasDisplayableContent: Bool {
        if attachments.isEmpty == false {
            return true
        }
        return [title, subtitle, body].contains { $0?.isEmpty == false }
    }

    /// Safe for `os_log` with `privacy: .public` and for the diagnostics export.
    ///
    /// Identifier, bundle id, and the *lengths* of the text fields. Lengths are what make
    /// a bug report actionable — "body 0 characters" versus "body 240 characters" is the
    /// difference between a parser bug and a display bug — without any of the text.
    public var logDescription: String {
        let lengths = "t=\(title?.count ?? 0) s=\(subtitle?.count ?? 0) b=\(body?.count ?? 0)"
        return "\(uuid.uuidString.prefix(8)) app=\(bundleID) \(lengths) atta=\(attachments.count)"
    }
}

// MARK: CustomStringConvertible, CustomDebugStringConvertible

extension ParsedNotification: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        logDescription
    }

    public var debugDescription: String {
        logDescription
    }
}

// MARK: - AttachmentMeta

/// What Backglance keeps about an attachment: enough to say "there was a 240 KB image",
/// never the image.
///
/// Storing only metadata is a deliberate limit on the archive's blast radius. The bytes
/// stay in Apple's store, subject to Apple's pruning; Backglance's copy cannot outlive
/// them, and a leaked archive cannot yield photographs.
public struct AttachmentMeta: Codable, Hashable, Sendable {
    // MARK: Lifecycle

    public init(type: String, name: String? = nil, size: Int? = nil) {
        self.type = type
        self.name = name
        self.size = size
    }

    // MARK: Public

    /// The attachment's type as the app declared it, or `"file"` when it declared nothing.
    public var type: String

    /// The file name, where there is one. Treated as content — it can carry a subject
    /// line — so it is redacted and never logged.
    public var name: String?

    /// Size in bytes, if the store recorded one.
    public var size: Int?

    /// Content-free, for logs.
    public var logDescription: String {
        "\(type) bytes=\(size ?? 0)"
    }
}
