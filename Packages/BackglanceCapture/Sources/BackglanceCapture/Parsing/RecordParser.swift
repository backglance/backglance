import Foundation

// MARK: - RecordParser

/// Turns a store row's binary plist into a ``ParsedNotification``.
///
/// ⚠️ The keys read here are undocumented and abbreviated — `titl`, `subt`, `body`, `thre`,
/// `cate`, `atta`, `usda` — observed on macOS 11 through 26 and verified by the fixtures.
/// The parser is tolerant by design: it accepts long-form spellings alongside the short
/// ones, tries several candidates per field, and treats an absent key as `nil` rather than
/// as an error. A macOS that renames one key should cost that field, not the notification.
///
/// Exactly two things fail a parse — data that is not a property list, and a payload with
/// no text, no attachments and no date. Everything else degrades.
///
/// > 🔒 A parse failure carries the `rec_id` and one of a small fixed set of reasons.
/// > Nothing from the payload reaches the error, the log, or the diagnostics export. The
/// > parser also runs *after* the exclusion check, so an excluded app's plist is never
/// > deserialised into objects at all (docs/features/CAPTURE.md#exclusion-before-parse).
///
/// See docs/features/CAPTURE.md#recordparser.
public struct RecordParser: Sendable {
    // MARK: Lifecycle

    /// - Parameter guard: the limits every payload is read under. The default is the one
    ///   the security model documents; tests narrow it.
    public init(guard plistGuard: PlistGuard = PlistGuard()) {
        self.plistGuard = plistGuard
    }

    // MARK: Public

    /// Decodes `raw` into a notification.
    ///
    /// - Throws: ``CaptureError/parseFailed(recID:reason:)``. One bad record must never
    ///   abort a batch: the caller logs this and moves to the next row.
    public func parse(_ raw: RawStoreRecord) throws -> ParsedNotification {
        let root = try rootDictionary(of: raw)

        // The payload usually nests the notification request under `req`; some rows put
        // the fields at the top level. Reading the root as a fallback costs nothing and
        // survives that difference.
        let request = (root["req"] as? [String: Any]) ?? root

        let title = Self.string(request["titl"], request["title"])
        let subtitle = Self.string(request["subt"], request["subtitle"])
        let body = Self.string(request["body"])
        let userInfo = Self.stringMap(request["usda"] ?? request["userInfo"])
        let attachments = Self.attachments(request["atta"] ?? request["attachments"])

        // The store keeps rows that are not notifications in any user-facing sense.
        // Archiving one would put a blank entry in the timeline.
        guard title != nil || subtitle != nil || body != nil || !attachments.isEmpty else {
            throw CaptureError.parseFailed(recID: raw.recID, reason: "empty payload")
        }

        // The row's own column first, then the payload's date, then when the app asked.
        // There is no final fallback to "now": a made-up timestamp files a notification
        // under the wrong day forever, and a timeline is only worth having if its order
        // is real.
        guard let deliveredAt = raw.deliveredDate ?? Self.date(root["date"]) ?? raw.requestDate else {
            throw CaptureError.parseFailed(recID: raw.recID, reason: "no delivered date")
        }

        // The plist's own `app` wins over the joined `app.identifier`: helper processes
        // and iPhone Mirroring post on behalf of another bundle, and the payload is the
        // one that knows which.
        let bundleID = Self.string(root["app"]) ?? raw.appIdentifier

        return ParsedNotification(
            bundleID: bundleID,
            uuid: raw.uuid,
            title: title,
            subtitle: subtitle,
            body: body,
            sender: Self.sender(bundleID: bundleID, title: title, userInfo: userInfo),
            threadID: Self.string(request["thre"], request["thread"], request["threadIdentifier"]),
            category: Self.string(request["cate"], request["category"]),
            deliveredAt: deliveredAt,
            presented: raw.presented,
            attachments: attachments,
            // Enrichment fills this in from `userInfo` with a per-app resolver.
            deepLink: nil,
            userInfo: userInfo
        )
    }

    // MARK: Private

    /// The limits the payload is decoded under. See ``PlistGuard``.
    private let plistGuard: PlistGuard

    /// The first non-empty string among the candidates.
    ///
    /// Attributed strings are flattened rather than skipped: an app that posts a styled
    /// title still posted a title, and the archive stores text.
    private static func string(_ candidates: Any?...) -> String? {
        for candidate in candidates {
            if let string = candidate as? String, !string.isEmpty {
                return string
            }
            if let attributed = candidate as? NSAttributedString, attributed.length > 0 {
                return attributed.string
            }
        }
        return nil
    }

    /// A date from either of the two shapes the payload uses: a real `Date`, or Cocoa
    /// reference seconds as a number.
    private static func date(_ value: Any?) -> Date? {
        if let date = value as? Date {
            return date
        }
        if let number = value as? NSNumber {
            return Date(timeIntervalSinceReferenceDate: number.doubleValue)
        }
        return nil
    }

    /// The app's `userInfo`, flattened to strings.
    ///
    /// Nested containers and `Data` are dropped rather than described. Backglance archives
    /// what a person could read; an app's arbitrary payload is neither readable nor ours
    /// to keep, and a coerced blob would be noise in the archive and in search.
    ///
    /// Only strings and numbers survive because those are the only scalars a property list
    /// carries — a URL in `userInfo` reaches us as its string, since plists cannot hold a
    /// `CFURL` in the first place.
    private static func stringMap(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else {
            return [:]
        }
        var flattened: [String: String] = [:]
        for (key, raw) in dictionary {
            switch raw {
            case let string as String:
                flattened[key] = string

            case let number as NSNumber:
                flattened[key] = number.stringValue

            default:
                continue
            }
        }
        return flattened
    }

    /// Attachment metadata. Never the bytes — see ``AttachmentMeta``.
    private static func attachments(_ value: Any?) -> [AttachmentMeta] {
        guard let items = value as? [[String: Any]] else {
            return []
        }
        return items.map { item in
            AttachmentMeta(
                type: string(item["type"], item["UTI"], item["uti"]) ?? "unknown",
                name: string(item["name"], item["iden"], item["identifier"]),
                size: (item["size"] as? NSNumber)?.intValue
            )
        }
    }

    /// Who the notification is from, where that can be known.
    ///
    /// Apps that say so in `userInfo` are taken at their word. Messages and Mail do not:
    /// they put the correspondent in the title, and a timeline grouped "from" nobody would
    /// be much less useful for exactly the two apps people search most. No other bundle is
    /// guessed at — a wrong sender is worse than none.
    private static func sender(bundleID: String, title: String?, userInfo: [String: String]) -> String? {
        if let declared = string(userInfo["sender"], userInfo["from"]) {
            return declared
        }
        switch bundleID {
        case "com.apple.MobileSMS",
             "com.apple.mail":
            return title

        default:
            return nil
        }
    }

    /// The payload's root dictionary, decoded under the guard's limits.
    ///
    /// The guard runs before anything else in ``parse(_:)``: a payload that breaks a limit
    /// is never walked for keys, so a hostile record costs one size check rather than an
    /// unbounded traversal.
    private func rootDictionary(of raw: RawStoreRecord) throws -> [String: Any] {
        do {
            return try plistGuard.decode(raw.plistData)
        } catch let error as PlistGuardError {
            // The guard's descriptions are shapes — a count, a depth, a length — so they
            // can be used as the reason verbatim.
            throw CaptureError.parseFailed(recID: raw.recID, reason: error.logDescription)
        }
    }
}
