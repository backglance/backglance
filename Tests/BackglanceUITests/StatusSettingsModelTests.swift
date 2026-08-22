import BackglanceCore
@testable import BackglanceUI
import Foundation
import XCTest

/// The pane that answers "is this working". Capture fails silently — nothing arrives to say
/// the store schema changed — so what matters here is that every answer is read fresh, and
/// that the expensive one is not read at all until asked for.
@MainActor
final class StatusSettingsModelTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - Reading

    func testLoadReadsCaptureHealthAndTheArchive() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive, count: 4)
        let health = CaptureHealth(
            status: .running,
            adapterID: "StoreAdapterV26",
            fingerprint: "9f2c4b1a",
            lastTickAt: Date(),
            lastTickRecords: 14
        )
        let model = makeModel(health: health, fda: .granted)

        await model.load()

        XCTAssertEqual(model.health.adapterID, "StoreAdapterV26")
        XCTAssertEqual(model.health.lastTickRecords, 14)
        XCTAssertEqual(model.fdaState, .granted)
        XCTAssertEqual(model.summary.notificationCount, 4)
        XCTAssertGreaterThan(model.summary.byteCount, 0)
    }

    /// 🔒 `PRAGMA integrity_check` reads the whole file. Running it on every appearance would
    /// make opening Settings slow in proportion to how much the user has archived.
    func testLoadDoesNotRunTheIntegrityCheck() async {
        let model = makeModel()

        await model.load()

        XCTAssertNil(model.summary.integrityOK, "not checked is not the same as checked and fine")
    }

    func testTheIntegrityCheckRunsWhenAsked() async throws {
        let archive = try XCTUnwrap(archive)
        try seed(archive)
        let model = makeModel()

        await model.runIntegrityCheck()

        let integrityOK = try XCTUnwrap(model.summary.integrityOK)
        XCTAssertTrue(integrityOK)
        XCTAssertNotNil(model.summary.checkedAt)
    }

    /// Every value can change while this window is open — a grant in System Settings, a macOS
    /// update that degrades capture — so nothing is cached past a load.
    func testEveryLoadAsksAgain() async {
        let counter = Counter()
        let read: @Sendable () async -> CaptureHealth = {
            counter.increment()
            return CaptureHealth()
        }
        let model = StatusSettingsModel(archive: nil, readCaptureHealth: read)

        await model.load()
        await model.load()

        XCTAssertEqual(counter.value, 2)
    }

    // MARK: - Without an archive

    /// A preview, or a launch whose archive would not open: the buttons are unavailable rather
    /// than present and inert.
    func testWithoutAnArchiveTheChecksAreUnavailable() async {
        let model = StatusSettingsModel(archive: nil)

        await model.load()

        XCTAssertFalse(model.canRunChecks)
        XCTAssertNil(model.summary.integrityOK)
        XCTAssertEqual(model.summary.notificationCount, 0)
    }

    // MARK: - The export

    /// 🔒 Off by default. Which apps notify you is itself personal, and the option has to be
    /// taken deliberately rather than left on from a previous session's convenience.
    func testAppNamesAreLeftOutOfTheExportUnlessAsked() async throws {
        var requested: [DiagnosticsExport.Options] = []
        let save: @Sendable (DiagnosticsExport.Options) async -> URL? = { options in
            await MainActor.run { requested.append(options) }
            return URL(fileURLWithPath: "/tmp/Backglance-Diagnostics.zip")
        }
        let model = try StatusSettingsModel(archive: XCTUnwrap(archive), saveDiagnostics: save)

        await model.exportDiagnostics()
        model.includeAppIdentifiers = true
        await model.exportDiagnostics()

        XCTAssertEqual(requested.map(\.includeAppIdentifiers), [false, true])
    }

    func testTheSavedLocationIsRemembered() async throws {
        let destination = URL(fileURLWithPath: "/tmp/Backglance-Diagnostics.zip")
        let save: @Sendable (DiagnosticsExport.Options) async -> URL? = { _ in destination }
        let model = try StatusSettingsModel(archive: XCTUnwrap(archive), saveDiagnostics: save)

        await model.exportDiagnostics()

        XCTAssertEqual(model.lastExport, destination)
    }

    /// A cancelled save panel leaves nothing behind to report.
    func testCancellingTheSavePanelRecordsNothing() async throws {
        let save: @Sendable (DiagnosticsExport.Options) async -> URL? = { _ in nil }
        let model = try StatusSettingsModel(archive: XCTUnwrap(archive), saveDiagnostics: save)

        await model.exportDiagnostics()

        XCTAssertNil(model.lastExport)
    }

    // MARK: Private

    private final class Counter: @unchecked Sendable {
        // MARK: Internal

        var value: Int {
            lock.withLock { count }
        }

        func increment() {
            lock.withLock { count += 1 }
        }

        // MARK: Private

        private let lock = NSLock()
        private var count = 0
    }

    private var archive: Archive?

    private func makeModel(
        health: CaptureHealth = CaptureHealth(),
        fda: FullDiskAccessDisplayState = .denied
    ) -> StatusSettingsModel {
        let readHealth: @Sendable () async -> CaptureHealth = { health }
        let readFDA: @Sendable () -> FullDiskAccessDisplayState = { fda }
        return StatusSettingsModel(archive: archive, readCaptureHealth: readHealth, readFullDiskAccess: readFDA)
    }

    private func seed(_ archive: Archive, count: Int = 1) throws {
        let now = Date()
        let app = try archive.upsertApp(bundleID: "com.example.app", now: now)
        for index in 0 ..< count {
            let notification = try ArchivedNotification(
                uuid: UUID().uuidString,
                appId: XCTUnwrap(app.id),
                title: "Aurora Bank",
                body: "Lunch at one?",
                deliveredAt: UnixDate(now),
                capturedAt: UnixDate(now),
                storeRecId: Int64(index + 1)
            )
            _ = try archive.insertOrUpdate(notification)
        }
    }
}
