import BackglanceCore
import BackglanceTestSupport
@testable import BackglanceUI
import Foundation
import XCTest

// MARK: - ExportSelectionTests

/// Covers `NotificationActionHandler.exportSelection(_:format:)` — see
/// docs/features/ACTIONS.md#select-and-export. Every case goes through
/// ``FakeSavePanelPresenter``: nothing here is allowed to open a real `NSSavePanel`, the same
/// discipline ``OpenActionTests`` already holds `NSWorkspace` to via ``FakeAppLauncher``.
@MainActor
final class ExportSelectionTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
        panel = FakeSavePanelPresenter()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportSelectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        handler = nil
        panel = nil
        archive = nil
        tempDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Cancel

    /// docs/features/ACTIONS.md's edge-case table: "Export cancelled in the save panel" is not
    /// an error, and nothing is logged. This proves the stronger half of that — nothing is
    /// *written* either, because ``NotificationActionHandler/exportSelection(_:format:)`` never
    /// reaches ``ExportService`` at all when the panel returns `nil`.
    func testCancelledPanelWritesNoFileAndThrowsNothing() async throws {
        let panel = try XCTUnwrap(panel)
        panel.result = nil
        let id = try insertNotification(title: "Build finished")

        try await makeHandler().exportSelection([id], format: .csv)

        XCTAssertEqual(panel.calls.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: XCTUnwrap(tempDirectory).path), [])
    }

    /// The suggested name and content type the panel is asked to present, so a regression that
    /// silently stops asking for the right extension is caught here rather than only visually.
    func testCancelledPanelStillReceivesTheSuggestedNameAndFormat() async throws {
        let panel = try XCTUnwrap(panel)
        panel.result = nil
        let id = try insertNotification(title: "Build finished")

        try await makeHandler().exportSelection([id], format: .json)

        let call = try XCTUnwrap(panel.calls.first)
        XCTAssertTrue(call.suggestedName.hasSuffix(".json"))
        XCTAssertTrue(call.suggestedName.hasPrefix("Backglance-export-"))
        XCTAssertEqual(call.format, .json)
    }

    // MARK: - Confirm: CSV

    func testConfirmedPanelWritesACSVFileWithTheSelectedRow() async throws {
        let panel = try XCTUnwrap(panel)
        let destination = try XCTUnwrap(tempDirectory).appendingPathComponent("out.csv")
        panel.result = destination
        let id = try insertNotification(title: "Build finished", body: "All 42 tests passed")

        try await makeHandler().exportSelection([id], format: .csv)

        let contents = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(contents.contains("Build finished"))
        XCTAssertTrue(contents.contains("All 42 tests passed"))
        XCTAssertTrue(contents.hasPrefix(ExportService.csvHeader.compactMap { $0 }.joined(separator: ",")))
    }

    // MARK: - Confirm: JSON

    func testConfirmedPanelWritesAJSONFileWithTheSelectedRow() async throws {
        let panel = try XCTUnwrap(panel)
        let destination = try XCTUnwrap(tempDirectory).appendingPathComponent("out.json")
        panel.result = destination
        let id = try insertNotification(title: "Build finished", body: "All 42 tests passed")

        try await makeHandler().exportSelection([id], format: .json)

        let data = try Data(contentsOf: destination)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        let row = try XCTUnwrap(decoded?.first)
        XCTAssertEqual(row["title"] as? String, "Build finished")
        XCTAssertEqual(row["body"] as? String, "All 42 tests passed")
    }

    /// Only the ids passed in are exported, even when the archive holds other rows —
    /// ``ExportRequest/selection(_:format:)`` is an explicit id list, not a date range.
    func testOnlyTheSelectedIdsAreExported() async throws {
        let panel = try XCTUnwrap(panel)
        let destination = try XCTUnwrap(tempDirectory).appendingPathComponent("out.csv")
        panel.result = destination
        let wanted = try insertNotification(title: "Wanted")
        _ = try insertNotification(title: "Not selected")

        try await makeHandler().exportSelection([wanted], format: .csv)

        let contents = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(contents.contains("Wanted"))
        XCTAssertFalse(contents.contains("Not selected"))
    }

    // MARK: - Write failure

    /// A destination whose parent directory does not exist is what forces
    /// `FileManager.createFile` to fail without needing real filesystem permission tricks —
    /// `ExportService.export` maps that to `ExportError.io`, which this handler must in turn map
    /// to `ActionError.exportFailed`, per docs/features/ACTIONS.md's edge-case table ("Export
    /// destination unwritable").
    func testWriteFailureSurfacesAsExportFailed() async throws {
        let panel = try XCTUnwrap(panel)
        let destination = try XCTUnwrap(tempDirectory)
            .appendingPathComponent("does-not-exist", isDirectory: true)
            .appendingPathComponent("out.csv")
        panel.result = destination
        let id = try insertNotification(title: "Build finished")

        do {
            try await makeHandler().exportSelection([id], format: .csv)
            XCTFail("expected .exportFailed")
        } catch {
            guard case let .exportFailed(reason) = error as? ActionError else {
                XCTFail("expected .exportFailed, got \(error)")
                return
            }
            XCTAssertFalse(reason.isEmpty)
        }
    }

    // MARK: Private

    private var archive: Archive?
    private var panel: FakeSavePanelPresenter?
    private var handler: NotificationActionHandler?
    private var tempDirectory: URL?

    private func makeHandler() throws -> NotificationActionHandler {
        let archive = try XCTUnwrap(archive)
        let handler = try NotificationActionHandler(
            archive: archive,
            exportService: ExportService(archive: archive),
            savePanel: XCTUnwrap(panel)
        )
        self.handler = handler
        return handler
    }

    private func insertNotification(title: String, body: String? = nil) throws -> Int64 {
        let archive = try XCTUnwrap(archive)
        let app = try archive.upsertApp(bundleID: Stubs.BundleID.slack, now: Stubs.epoch)
        let appID = try XCTUnwrap(app.id)
        let inserted = try archive.insert(ArchivedNotification(
            uuid: UUID().uuidString,
            appId: appID,
            title: title,
            body: body,
            deliveredAt: UnixDate(Stubs.epoch),
            capturedAt: UnixDate(Stubs.epoch)
        ))
        return try XCTUnwrap(inserted.id)
    }
}

// MARK: - FakeSavePanelPresenter

/// Records every call it receives and returns a scripted `URL?` — nothing here ever reaches a
/// real `NSSavePanel`. See ``SavePanelPresenting``.
@MainActor
final class FakeSavePanelPresenter: SavePanelPresenting {
    struct Call: Equatable {
        let suggestedName: String
        let format: ExportFormat
    }

    private(set) var calls: [Call] = []

    /// Scripted return for every `runModal` call. `nil` (the default) simulates the user
    /// cancelling the panel.
    var result: URL?

    func runModal(suggestedName: String, format: ExportFormat) -> URL? {
        calls.append(Call(suggestedName: suggestedName, format: format))
        return result
    }
}
