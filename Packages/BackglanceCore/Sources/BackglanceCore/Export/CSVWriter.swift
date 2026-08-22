import Foundation

/// A small RFC 4180 writer, no dependency — see
/// docs/features/EXPORT_AUTOMATION.md#csv-rfc-4180.
///
/// Rules: fields containing `,`, `"`, `\r` or `\n` are quoted; a quote inside a
/// quoted field is doubled; every row (including the header, which the caller writes
/// with the same ``row(_:)``) ends in `\r\n`; the file is UTF-8. `CSVWriter` itself
/// never opens a file or knows a column name — ``ExportService`` owns both, so this
/// type is trivial to unit-test on its own.
public struct CSVWriter: Sendable {
    // MARK: Lifecycle

    public init(protectFormulas: Bool = true, byteOrderMark: Bool = false) {
        self.protectFormulas = protectFormulas
        self.byteOrderMark = byteOrderMark
    }

    // MARK: Public

    /// CSV-injection guard, on by default. A cell whose *raw* text starts with `=`,
    /// `+`, `-`, `@`, a tab or a CR would be evaluated as a formula by Excel/Numbers
    /// when the file is opened — a notification body is arbitrary text from a third
    /// -party app, so nothing about it is safe to hand a spreadsheet's formula
    /// engine unasked. Prefixing an apostrophe (which no spreadsheet renders) is the
    /// standard mitigation; turning this off is an explicit "I trust these values"
    /// choice the caller makes, not the default.
    public var protectFormulas: Bool

    /// Whether ``preamble`` should return the UTF-8 byte-order mark. Off by default
    /// — a BOM is a courtesy to older Excel builds on Windows that otherwise guess
    /// the encoding wrong, not something every reader wants prepended to its file.
    public var byteOrderMark: Bool

    /// The bytes a caller writes exactly once, before the first ``row(_:)`` call —
    /// normally the header row. Empty when ``byteOrderMark`` is off, so a caller can
    /// unconditionally prepend this without a branch of its own.
    public var preamble: String {
        byteOrderMark ? "\u{FEFF}" : ""
    }

    /// One CSV row: every field escaped, comma-joined, `\r\n`-terminated.
    ///
    /// `nil` fields become the empty string — the schema already says which columns
    /// are optional (docs/features/EXPORT_AUTOMATION.md's schema table), so an empty
    /// cell in, say, `subtitle` is not distinguishable from (and does not need to be
    /// distinguishable from) an empty string that happened to be the subtitle.
    public func row(_ fields: [String?]) -> String {
        fields.map { escape($0 ?? "") }.joined(separator: ",") + "\r\n"
    }

    // MARK: Internal

    /// Escapes one field: the formula guard first (it can add a leading character
    /// that itself may need quoting), then RFC 4180 quoting.
    ///
    /// The quoting check walks ``Swift/String/unicodeScalars``, not the default
    /// `Character` (grapheme cluster) view: Unicode defines CR+LF as a single
    /// extended grapheme cluster, so a field containing an embedded `"\r\n"` has no
    /// `Character` that equals a bare `"\n"` or `"\r"` — `field.contains("\n")` over
    /// `Character`s silently misses it, and an unquoted line ending inside a field
    /// is exactly the corruption RFC 4180 quoting exists to prevent. Scalars have no
    /// such clustering, so `\r` and `\n` are always found individually regardless of
    /// which line-ending style produced them.
    func escape(_ raw: String) -> String {
        var field = raw
        // `unicodeScalars.first`, not `first`, for the same clustering reason spelled
        // out below: a field beginning with a CRLF has `"\r\n"` as its first
        // `Character`, which matches none of the scalars listed here, and the leading
        // CR the guard exists to catch would walk straight past it.
        if protectFormulas, let first = field.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) {
            field = "'" + field
        }
        let needsQuoting = field.unicodeScalars.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
        guard needsQuoting else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
