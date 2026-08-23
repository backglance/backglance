import Foundation
import GRDB

// MARK: - ExportFormat

public enum ExportFormat: String, CaseIterable, Sendable {
    case csv
    case json
}

// MARK: - ExportRequest

/// What to export and how. See docs/features/EXPORT_AUTOMATION.md#business-logic.
public struct ExportRequest: Sendable {
    // MARK: Lifecycle

    public init(
        from: Date,
        to: Date,
        format: ExportFormat,
        bundleIDs: Set<String>? = nil,
        notificationIDs: [Int64]? = nil
    ) {
        self.from = from
        self.to = to
        self.format = format
        self.bundleIDs = bundleIDs
        self.notificationIDs = notificationIDs
    }

    // MARK: Public

    public var from: Date
    public var to: Date
    public var format: ExportFormat

    /// `nil` = every app.
    public var bundleIDs: Set<String>?

    /// Non-nil = a selection export: only these ids, in addition to whatever date
    /// range and app filter are also set.
    public var notificationIDs: [Int64]?

    /// The v1.0 "Export Selection…" path (docs/features/ACTIONS.md#select-and-export):
    /// an explicit id list with no date range. `EXPORT_AUTOMATION.md`'s Business
    /// Logic notes spell out the range as `distantPast..<distantFuture` rather than
    /// leaving the date filter out of the SQL entirely — one query shape serves both
    /// paths, so a selection export cannot silently start matching *more* than its id
    /// list if `Self.sql(for:)` ever changes. Named rather than left for every call
    /// site to build the same two sentinel dates by hand.
    public static func selection(_ notificationIDs: [Int64], format: ExportFormat) -> ExportRequest {
        ExportRequest(from: .distantPast, to: .distantFuture, format: format, notificationIDs: notificationIDs)
    }
}

// MARK: - ExportError

public enum ExportError: Error, LocalizedError, Equatable, Sendable {
    case invalidRange
    case rangeTooLarge(days: Int)
    case cancelled
    case io(String)

    // MARK: Public

    public var errorDescription: String? {
        switch self {
        case .invalidRange:
            String(localized: "The start date must be before the end date.")

        case let .rangeTooLarge(days):
            String(localized: "Ranges above \(days) days are exported as multiple files.")

        case .cancelled:
            String(localized: "Export cancelled.")

        case let .io(msg):
            String(localized: "Couldn't write the export file: \(msg)")
        }
    }
}

// MARK: - ExportService

/// Streams the archive to a CSV or JSON file the user chose. Pure logic, no UI: the
/// confirmation sheet and `NSSavePanel` are `ExportCoordinator`/`ExportSheet` in the
/// app target and `BackglanceUI` (docs/features/EXPORT_AUTOMATION.md#architecture).
///
/// `final class … : Sendable` rather than `@unchecked Sendable`: the only stored
/// property is a `let archive: Archive`, and ``Archive`` is itself `Sendable` (its
/// mutable state lives behind an internal lock — see `Archive.swift`'s
/// `WriterState`), so the compiler can verify this conformance rather than being
/// asked to trust it.
public final class ExportService: Sendable {
    // MARK: Lifecycle

    public init(archive: Archive) {
        self.archive = archive
    }

    // MARK: Public

    /// The CSV header, in the same order as ``ExportedNotification/CodingKeys`` —
    /// `ExportServiceTests` asserts the two agree, since nothing at the type level
    /// forces this hand-written list to track that enum.
    public static let csvHeader: [String?] = [
        "uuid", "app_bundle_id", "app_name", "title", "subtitle", "body",
        "sender", "delivered_at", "presented", "missed", "redacted",
        "deep_link", "attachments",
    ]

    /// Streams `request`'s rows into `url`, never materialising the whole result set.
    ///
    /// The entire read — the GRDB cursor and every row it yields — runs inside one
    /// `archive.pool.read { … }` snapshot, so the export sees the archive as it stood
    /// the instant this call started even though capture keeps inserting concurrently
    /// on the writer connection; ``Archive/pool`` is a plain `DatabaseWriter` (a
    /// `DatabasePool` for the app, a `DatabaseQueue` in tests) and, like every other
    /// `Archive` extension in this package, `read`/`write` here are synchronous calls
    /// on the calling thread — never `try await pool.read { }`, which is not this
    /// package's API.
    ///
    /// - Parameters:
    ///   - progress: called on the calling task roughly every 500 rows. Never called
    ///     for the final partial batch — a caller that wants the true final count
    ///     reads this method's return value, not the last `progress` call.
    /// - Returns: the number of rows written.
    /// - Throws: ``ExportError/invalidRange`` before anything is written;
    ///   ``ExportError/cancelled`` if the calling `Task` is cancelled mid-export (no
    ///   file is left behind); ``ExportError/io(_:)`` for anything else, including an
    ///   archive read failure.
    public func export(
        _ request: ExportRequest,
        to url: URL,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> Int {
        guard request.from < request.to else {
            throw ExportError.invalidRange
        }

        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ExportError.io("couldn't create \(url.lastPathComponent)")
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw ExportError.io("couldn't open \(url.lastPathComponent)")
        }
        defer { try? handle.close() }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let csv = CSVWriter()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime] // includes the UTC offset
        iso.timeZone = .current

        var written = 0
        do {
            if request.format == .csv {
                try handle.write(contentsOf: Data((csv.preamble + csv.row(Self.csvHeader)).utf8))
            } else {
                try handle.write(contentsOf: Data("[\n".utf8))
            }

            written = try streamRows(
                for: request,
                into: handle,
                csv: csv,
                encoder: encoder,
                iso: iso,
                progress: progress
            )

            if request.format == .json {
                try handle.write(contentsOf: Data("\n]\n".utf8))
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: url) // never leave a partial file
            throw ExportError.cancelled
        } catch let error as ExportError {
            // Also cleaned up, not just rethrown: the only `ExportError` that can
            // reach here is one `streamRows` threw *mid-file* (a row that would not
            // encode as UTF-8 JSON). `.invalidRange` is checked before the file is
            // created and never lands here. So this branch means the same thing the
            // two around it do — the export stopped part-way — and leaving the half
            // file on disk would hand the user something that looks like an export
            // and is not one.
            try? FileManager.default.removeItem(at: url)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: url) // never leave a partial file
            throw ExportError.io(Self.ioMessage(for: error))
        }
        return written
    }

    // MARK: Internal

    /// - `n.id IN (SELECT value FROM json_each(:ids))` and the `:bundles` clause
    ///   below are the parameterized-SQL idiom this package uses everywhere a caller
    ///   supplies a *list* rather than a scalar (docs/security/SECURITY.md
    ///   #parameterized-sql-only): the list travels as one JSON-text argument bound
    ///   through `?`/named placeholders, never spliced into the SQL string, so its
    ///   length can't turn into a hand-built run of `?, ?, ?, …` placeholders and
    ///   can't be an injection surface no matter what a bundle id or an id array
    ///   contains.
    static func sql(for request: ExportRequest) -> String {
        var sql = """
        SELECT n.uuid, a.bundle_id, a.display_name, n.title, n.subtitle, n.body, n.sender,
               n.delivered_at, n.presented, n.away_session_id, n.redaction, n.deep_link, n.attachments_json
        FROM notifications n JOIN apps a ON a.id = n.app_id
        WHERE n.is_deleted = 0 AND n.delivered_at >= :from AND n.delivered_at < :to
        """
        if request.notificationIDs != nil {
            sql += " AND n.id IN (SELECT value FROM json_each(:ids))"
        }
        if request.bundleIDs != nil {
            sql += " AND a.bundle_id IN (SELECT value FROM json_each(:bundles))"
        }
        return sql + " ORDER BY n.delivered_at ASC"
    }

    static func arguments(for request: ExportRequest) -> StatementArguments {
        var args: [String: (any DatabaseValueConvertible)?] = [
            "from": request.from.timeIntervalSince1970,
            "to": request.to.timeIntervalSince1970,
        ]
        if let ids = request.notificationIDs {
            args["ids"] = jsonArray(ids.map(String.init))
        }
        if let bundles = request.bundleIDs {
            args["bundles"] = jsonArray(Array(bundles))
        }
        return StatementArguments(args)
    }

    /// Encodes a list of strings as a compact JSON array for `json_each` to unpack.
    ///
    /// `try?` with an `"[]"` fallback rather than `try!`: encoding `[String]` cannot
    /// realistically fail, but a filter that matches nothing on the one input that
    /// somehow did fail is a far smaller blast radius than crashing a running
    /// export part-way through — especially for a value (bundle ids, numeric ids
    /// rendered as strings) that carries no notification content to begin with.
    static func jsonArray(_ values: [String]) -> String {
        guard
            let data = try? JSONEncoder().encode(values),
            let json = String(bytes: data, encoding: .utf8)
        else {
            return "[]"
        }
        return json
    }

    // MARK: Private

    private let archive: Archive

    /// Renders a failure caught while reading or writing into text that is safe to
    /// carry inside ``ExportError/io(_:)``.
    ///
    /// A `FileHandle`/`FileManager` failure's `localizedDescription` is an
    /// operating-system message about a path and a disk — "No space left on
    /// device", "Operation not permitted" — with no notification content in it, so
    /// it is used as-is. A GRDB `DatabaseError` is different: `Archive
    /// .makeConfiguration(inMemory:)` turns on `Configuration
    /// .publicStatementArguments` in DEBUG builds so SQL is readable while
    /// developing, which means a failing statement's *bound arguments* — here,
    /// dates and ids, but this helper cannot assume that of every archive error
    /// forever — can end up folded into `String(describing:)`. Every other
    /// `Archive` extension in this package routes exactly this case through
    /// ``ArchiveError/detail(from:)`` instead of describing the error directly, and
    /// this does the same rather than being the one path in the export pipeline
    /// that could leak a bound value into `ExportError.io`'s message, which a
    /// caller might show in a UI alert or write to the log.
    private static func ioMessage(for error: Error) -> String {
        if error is DatabaseError {
            return ArchiveError.detail(from: error)
        }
        return error.localizedDescription
    }

    /// The row-by-row read-and-write loop, factored out of ``export(_:to:progress:)``
    /// purely so it can be an ordinary (non-`async`) throwing method.
    ///
    /// `DatabaseReader` vends both a synchronous `read` and an `async throws` one
    /// (the sync overload is `@_disfavoredOverload`, marked that way upstream for
    /// exactly this reason — see GRDB's own "SR-15150 Async overloading in protocol
    /// implementation fails" comment on the declaration). Written inline inside
    /// `export`, which is itself `async`, a bare trailing closure resolves to the
    /// async overload — silently requiring `await` and every capture to cross an
    /// `@Sendable` boundary for no reason, since this is deliberately the
    /// synchronous, single-snapshot read every other `Archive` extension in this
    /// package uses. A private, non-`async` method has no async candidate to
    /// resolve to in the first place, which is a stronger guarantee than trying to
    /// out-prioritize `@_disfavoredOverload` from an async call site.
    private func streamRows(
        for request: ExportRequest,
        into handle: FileHandle,
        csv: CSVWriter,
        encoder: JSONEncoder,
        iso: ISO8601DateFormatter,
        progress: (@Sendable (Int) -> Void)?
    ) throws -> Int {
        try archive.pool.read { db in
            var written = 0
            let cursor = try Row.fetchCursor(
                db,
                sql: Self.sql(for: request),
                arguments: Self.arguments(for: request)
            )
            while let row = try cursor.next() {
                try Task.checkCancellation()
                let item = ExportedNotification(row: row, iso: iso)
                let line: String
                switch request.format {
                case .csv:
                    line = csv.row(item.csvFields)

                case .json:
                    guard let obj = try String(bytes: encoder.encode(item), encoding: .utf8) else {
                        throw ExportError.io("couldn't encode a row as UTF-8 JSON")
                    }
                    line = (written == 0 ? "" : ",\n") + obj
                }
                try handle.write(contentsOf: Data(line.utf8))
                written += 1
                if written.isMultiple(of: 500) {
                    progress?(written)
                }
            }
            return written
        }
    }
}
