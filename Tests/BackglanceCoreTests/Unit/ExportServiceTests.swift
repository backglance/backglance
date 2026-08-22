@testable import BackglanceCore
import BackglanceTestSupport
import Foundation
import GRDB
import XCTest

/// Covers `ExportService`: the CSV/JSON streaming write, redaction pass-through, the
/// v1.0 selection-export path, cancellation, and I/O failure handling. See
/// docs/features/EXPORT_AUTOMATION.md#export-formats and
/// docs/features/EXPORT_AUTOMATION.md#business-logic. `CSVWriter`'s own escaping rules
/// are covered separately in `CSVWriterTests.swift`; these tests treat CSV output as a
/// black box and parse it back with a tiny test-only reader, per
/// docs/features/EXPORT_AUTOMATION.md#testing-approach.
final class ExportServiceTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archiveStorage = try Archive(inMemory: true)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: XCTUnwrap(directory), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        archiveStorage = nil
        try super.tearDownWithError()
    }

    // MARK: - The header/field-order relationship

    /// `ExportService.csvHeader` and `ExportedNotification.CodingKeys` are two
    /// hand-maintained lists — nothing at the type level forces the header string
    /// literals to track the enum. This is the test that would fail the moment they
    /// drifted.
    func testCSVHeaderMatchesExportedNotificationCodingKeyOrder() {
        XCTAssertEqual(
            ExportService.csvHeader.compactMap { $0 },
            ExportedNotification.CodingKeys.allCases.map(\.rawValue)
        )
    }

    // MARK: - CSV

    /// The whole round trip: five rows seeded (two soft-deleted), exported, and read
    /// back. Row count excludes the deleted rows, and the surviving rows come back
    /// oldest-first — `ORDER BY delivered_at ASC`, the opposite of the timeline's own
    /// newest-first order, because an export reads like a log.
    func testCSVExportRoundTripsASeededArchiveOldestFirstExcludingDeletedRows() async throws {
        let seeded = try seed(count: 5, deleted: [1, 3])
        let service = try ExportService(archive: archive())
        let url = try fileURL("export.csv")

        let written = try await service.export(fullRangeRequest(format: .csv), to: url)

        let lines = try csvLines(at: url)
        XCTAssertEqual(written, 3)
        XCTAssertEqual(lines.first, ExportService.csvHeader.compactMap { $0 })
        let uuidColumn = try XCTUnwrap(
            ExportedNotification.CodingKeys.allCases.firstIndex(of: .uuid)
        )
        let expectedUUIDs = [seeded[0].uuid, seeded[2].uuid, seeded[4].uuid]
        XCTAssertEqual(lines.dropFirst().map { $0[uuidColumn] }, expectedUUIDs)
    }

    // MARK: - JSON

    /// JSON decodes as a flat array of the right length, using the snake_case keys
    /// the schema table promises rather than `JSONDecoder`'s default camelCase.
    func testJSONExportParsesAsAnArrayWithSnakeCaseKeys() async throws {
        let seeded = try seed(count: 4)
        let service = try ExportService(archive: archive())
        let url = try fileURL("export.json")

        let written = try await service.export(fullRangeRequest(format: .json), to: url)

        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([ExportedNotification].self, from: data)
        XCTAssertEqual(written, 4)
        XCTAssertEqual(decoded.map(\.uuid), seeded.map(\.uuid))

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"app_bundle_id\""), text)
        XCTAssertTrue(text.contains("\"delivered_at\""), text)
        XCTAssertFalse(text.contains("\"appBundleID\""), text)
    }

    // MARK: - Redaction

    /// A redacted row exports the placeholder that is already sitting in
    /// `notifications.body` — there is no original text anywhere to export instead
    /// (Privacy Invariant #2). `ExportService` does not know or care that a
    /// redaction happened beyond reading the column; this is what proves it passes
    /// the placeholder through untouched.
    func testRedactedRowExportsItsPlaceholderBodyAsIs() async throws {
        try seed(count: 1, redacted: [0])
        let service = try ExportService(archive: archive())
        let url = try fileURL("redacted.json")

        _ = try await service.export(fullRangeRequest(format: .json), to: url)

        let decoded = try JSONDecoder().decode([ExportedNotification].self, from: Data(contentsOf: url))
        let item = try XCTUnwrap(decoded.first)
        XCTAssertTrue(item.redacted)
        XCTAssertEqual(item.body, Self.redactedPlaceholder)
    }

    // MARK: - Selection export

    /// `ExportRequest.selection(_:format:)` — the v1.0 "Export Selection…" path —
    /// returns exactly the requested ids and nothing else, even though every row in
    /// the archive falls inside the sentinel `distantPast..<distantFuture` range it
    /// exports over.
    func testSelectionExportReturnsOnlyTheRequestedIds() async throws {
        let seeded = try seed(count: 5)
        let service = try ExportService(archive: archive())
        let url = try fileURL("selection.csv")
        let selectedIDs = [seeded[1].id, seeded[3].id]

        let written = try await service.export(.selection(selectedIDs, format: .csv), to: url)

        let lines = try csvLines(at: url)
        let uuidColumn = try XCTUnwrap(
            ExportedNotification.CodingKeys.allCases.firstIndex(of: .uuid)
        )
        XCTAssertEqual(written, 2)
        XCTAssertEqual(
            Set(lines.dropFirst().map { $0[uuidColumn] }),
            Set([seeded[1].uuid, seeded[3].uuid])
        )
    }

    // MARK: - Invalid range

    /// `from >= to` is rejected before anything is written — no file appears at all,
    /// not even an empty one.
    func testFromNotBeforeToThrowsInvalidRangeAndCreatesNoFile() async throws {
        let service = try ExportService(archive: archive())
        let url = try fileURL("invalid.csv")
        let request = ExportRequest(from: Stubs.epoch, to: Stubs.epoch, format: .csv)

        do {
            _ = try await service.export(request, to: url)
            XCTFail("expected ExportError.invalidRange")
        } catch let error as ExportError {
            XCTAssertEqual(error, .invalidRange)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Cancellation

    /// Cancelling the calling task mid-export throws `.cancelled` and leaves no
    /// partial file behind. The progress callback — which `export` calls every 500
    /// rows on the calling task, per its own contract — is what cancels the task
    /// here: `Task.checkCancellation()` runs synchronously on the very next row, so
    /// this is deterministic rather than a race against wall-clock timing.
    func testCancellingMidExportThrowsCancelledAndLeavesNoFile() async throws {
        try seed(count: 1_000)
        let service = try ExportService(archive: archive())
        let url = try fileURL("cancelled.csv")

        let box = CancellableTaskBox()
        box.task = Task {
            try await service.export(fullRangeRequest(format: .csv), to: url) { written in
                if written >= 500 {
                    box.task?.cancel()
                }
            }
        }

        let task = try XCTUnwrap(box.task)
        let result = await task.result
        switch result {
        case .success:
            XCTFail("expected the export to be cancelled")

        case let .failure(error):
            XCTAssertEqual(error as? ExportError, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - I/O failure

    /// A destination whose parent directory does not exist can never be created —
    /// this is the "disk full" / "unwritable" family of failure the doc's edge-case
    /// table describes, surfaced as `.io` rather than a fatal error or a silently
    /// empty file.
    func testUnwritableDestinationThrowsIO() async throws {
        try seed(count: 1)
        let service = try ExportService(archive: archive())
        let url = try fileURL("missing-subdirectory").appendingPathComponent("export.csv")

        do {
            _ = try await service.export(fullRangeRequest(format: .csv), to: url)
            XCTFail("expected ExportError.io")
        } catch let error as ExportError {
            guard case .io = error else {
                XCTFail("expected .io, got \(error)")
                return
            }
        }
    }

    // MARK: - Read-only

    /// Export reads the archive; it must never write to it. Every flag a row can
    /// carry — read, pinned, deleted — is checked before and after the export and
    /// must be bit-for-bit identical, not just "still the same count".
    func testExportNeverWritesToTheArchive() async throws {
        let seeded = try seed(count: 3)
        let ids = seeded.map(\.id)
        let before = try rowStates(ids)
        let service = try ExportService(archive: archive())
        let url = try fileURL("read-only.csv")

        _ = try await service.export(fullRangeRequest(format: .csv), to: url)

        let after = try rowStates(ids)
        XCTAssertEqual(before, after)
    }

    // MARK: Private

    /// A `Task` handle that a closure captured by its own body can cancel — the
    /// reference has to live somewhere outside the `Task { }` literal for the
    /// closure to reach it, and a plain class does that without pulling in an actor
    /// for something this small. `@unchecked Sendable` because the only mutation
    /// (setting `.task` once, immediately after creation, from the same thread that
    /// then awaits its `.result`) never overlaps a read from the task body, which
    /// only *reads* `.task` well after that assignment has already landed — see the
    /// doc comment on the test that uses this.
    private final class CancellableTaskBox: @unchecked Sendable {
        var task: Task<Int, Error>?
    }

    private struct SeededRow {
        let id: Int64
        let uuid: String
    }

    private struct RowState: Equatable {
        let isRead: Bool
        let isPinned: Bool
        let isDeleted: Bool
        let redaction: ArchivedNotification.Redaction
    }

    private enum SeedError: Error {
        case missingRowID
    }

    private static let redactedPlaceholder = "[code redacted]"

    private var archiveStorage: Archive?
    private var directory: URL?

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                    } else {
                        inQuotes = false
                        index += 1
                    }
                } else {
                    field.append(character)
                    index += 1
                }
            } else if character == "\"" {
                inQuotes = true
                index += 1
            } else if character == "," {
                fields.append(field)
                field = ""
                index += 1
            } else {
                field.append(character)
                index += 1
            }
        }
        fields.append(field)
        return fields
    }

    private func archive() throws -> Archive {
        try XCTUnwrap(archiveStorage)
    }

    private func fileURL(_ name: String) throws -> URL {
        try XCTUnwrap(directory).appendingPathComponent(name)
    }

    /// A request wide enough to cover every row `seed(count:)` produces (they start
    /// at `Stubs.epoch` and step forward one second per row), for tests that are not
    /// themselves about the date range.
    private func fullRangeRequest(format: ExportFormat) -> ExportRequest {
        ExportRequest(
            from: Stubs.epoch.addingTimeInterval(-1),
            to: Stubs.epoch.addingTimeInterval(100_000),
            format: format
        )
    }

    /// Inserts `count` notifications under one app, one second apart starting at
    /// `Stubs.epoch` — so `ORDER BY delivered_at ASC` sorts them index 0, 1, 2, …
    /// Text is fixed, readable fixture text, never anything resembling a real
    /// notification, matching the rest of this package's seed helpers
    /// (`TimelineSeed.fill`).
    ///
    /// - Parameters:
    ///   - deleted: indexes to insert with `is_deleted = 1`.
    ///   - redacted: indexes to insert with `redaction = .otp` and a body already
    ///     replaced by the placeholder — mirroring what `OTPRedactor` would have
    ///     done before insert, not something `ExportService` or this helper redacts
    ///     itself.
    @discardableResult
    private func seed(
        count: Int,
        deleted: Set<Int> = [],
        redacted: Set<Int> = []
    ) throws -> [SeededRow] {
        try archive().pool.write { db in
            var app = AppRecord(
                bundleId: Stubs.BundleID.slack,
                displayName: "Slack",
                firstSeenAt: UnixDate(Stubs.epoch),
                lastSeenAt: UnixDate(Stubs.epoch)
            )
            try app.insert(db)
            guard let appID = app.id else {
                throw SeedError.missingRowID
            }

            var rows: [SeededRow] = []
            for index in 0 ..< count {
                let isRedacted = redacted.contains(index)
                var row = ArchivedNotification(
                    uuid: UUID().uuidString,
                    appId: appID,
                    title: "Fixture title \(index)",
                    body: isRedacted ? Self.redactedPlaceholder : "Fixture body \(index)",
                    sender: "sender-\(index)@example.com",
                    deliveredAt: UnixDate(Stubs.epoch.addingTimeInterval(Double(index))),
                    capturedAt: UnixDate(Stubs.epoch),
                    redaction: isRedacted ? .otp : .none,
                    isDeleted: deleted.contains(index)
                )
                try row.insert(db)
                guard let id = row.id else {
                    throw SeedError.missingRowID
                }
                rows.append(SeededRow(id: id, uuid: row.uuid))
            }
            return rows
        }
    }

    private func rowStates(_ ids: [Int64]) throws -> [RowState] {
        try archive().pool.read { db in
            try ids.map { id in
                let row = try XCTUnwrap(try ArchivedNotification.fetchOne(db, key: id))
                return RowState(
                    isRead: row.isRead,
                    isPinned: row.isPinned,
                    isDeleted: row.isDeleted,
                    redaction: row.redaction
                )
            }
        }
    }

    /// A minimal RFC 4180 reader, for parsing back what `CSVWriter` produced — not a
    /// general-purpose CSV library, and not meant to be one. `CSVWriter`'s own
    /// escaping rules (quoting, doubling, the formula guard) are exercised directly
    /// in `CSVWriterTests.swift`; this only has to survive whatever this file's
    /// fixture text actually contains.
    private func csvLines(at url: URL) throws -> [[String]] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return content
            .components(separatedBy: "\r\n")
            .filter { !$0.isEmpty }
            .map(Self.parseCSVLine)
    }
}
