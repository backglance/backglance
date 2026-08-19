@testable import BackglanceCapture
import BackglanceCore
import Foundation
import XCTest

/// The first-launch import is the one moment a person sits and watches Backglance work.
/// Everything after it happens in the background a handful of records at a time; this runs
/// once, over everything the store still holds, while an onboarding screen shows a
/// progress bar.
///
/// The budget is ten seconds for ten thousand records
/// (docs/deployment/PERFORMANCE_GUIDE.md#import-performance). It is deliberately loose —
/// the point is to catch an import that has become quadratic or that lost its batching,
/// not to police a few hundred milliseconds on a busy machine.
final class ImportPerformanceTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportPerformanceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: XCTUnwrap(directory), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        watcher?.stop()
        watcher = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    func testTenThousandRecordsImportWithinTheBudget() async throws {
        let directory = try XCTUnwrap(directory)
        let storeURL = directory.appendingPathComponent("db")
        try MiniatureStore.makeFile(
            at: storeURL,
            rows: (1 ... Self.recordCount).map { MiniatureStore.notification(recID: Int64($0), body: "Body \($0)") }
        )

        let archive = try Archive(inMemory: true)
        let watcher = StoreWatcher(location: directory.appendingPathComponent("unused"), debounce: 0.01)
        self.watcher = watcher
        let engine = CaptureEngine(archive: archive, watcher: watcher) { storeURL }
        await engine.start()

        let started = Date()
        let summary = try await engine.importExisting()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(summary.archived, Self.recordCount)
        XCTAssertLessThan(
            elapsed,
            Self.budget,
            "importing \(Self.recordCount) records took \(String(format: "%.1f", elapsed))s, budget \(Self.budget)s"
        )
    }

    // MARK: Private

    /// Roughly a very heavy week: the system prunes its store long before this.
    private static let recordCount = 10_000

    /// Seconds. See PERFORMANCE_GUIDE.md.
    private static let budget: TimeInterval = 10

    private var watcher: StoreWatcher?
    private var directory: URL?
}
