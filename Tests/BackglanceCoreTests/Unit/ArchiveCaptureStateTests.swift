@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

final class ArchiveCaptureStateTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - Raw string access

    func testUnwrittenKeyReadsAsNil() throws {
        for key in Archive.CaptureStateKey.allCases {
            XCTAssertNil(try archive.captureState(key), key.rawValue)
        }
    }

    func testValueRoundTrips() throws {
        try archive.setCaptureState("v26", for: .adapterID)
        XCTAssertEqual(try archive.captureState(.adapterID), "v26")
    }

    /// The table is keyed, so a second write has to replace rather than accumulate —
    /// otherwise the upsert would trip the primary key and capture would fail to
    /// record its progress on the second batch.
    func testWritingTwiceReplacesRatherThanDuplicating() throws {
        try archive.setCaptureState("v15", for: .adapterID)
        try archive.setCaptureState("v26", for: .adapterID)

        XCTAssertEqual(try archive.captureState(.adapterID), "v26")
        let rows = try archive.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_state WHERE key = 'adapter_id'")
        }
        XCTAssertEqual(rows, 1)
    }

    func testWritingNilRemovesTheRow() throws {
        try archive.setCaptureState("v26", for: .adapterID)
        try archive.setCaptureState(nil, for: .adapterID)

        XCTAssertNil(try archive.captureState(.adapterID))
        let rows = try archive.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM capture_state")
        }
        XCTAssertEqual(rows, 0)
    }

    func testKeysAreIndependent() throws {
        try archive.setCaptureState("v26", for: .adapterID)
        try archive.setCaptureState("abc123", for: .fingerprint)

        XCTAssertEqual(try archive.captureState(.adapterID), "v26")
        XCTAssertEqual(try archive.captureState(.fingerprint), "abc123")
    }

    func testKeyRawValuesMatchTheDocumentedColumnVocabulary() {
        XCTAssertEqual(
            Set(Archive.CaptureStateKey.allCases.map(\.rawValue)),
            ["cursor", "fingerprint", "adapter_id", "last_import_at"]
        )
    }

    // MARK: - JSON access

    func testCodableValueRoundTrips() throws {
        let cursor = StubCursor(lastRecID: 999, lastDeliveredDate: 1_755_421_200.0)
        try archive.setCaptureStateJSON(cursor, for: .cursor)

        XCTAssertEqual(try archive.captureStateJSON(.cursor, as: StubCursor.self), cursor)
    }

    /// A cursor that will not decode is resumable state, not a launch failure: the
    /// next bootstrap re-reads from the tail. Throwing here would turn a row written
    /// by a different build into an app that cannot start.
    func testCorruptJSONDecodesAsNilRatherThanThrowing() throws {
        try archive.setCaptureState("{not json", for: .cursor)

        XCTAssertNil(try archive.captureStateJSON(.cursor, as: StubCursor.self))
        // The raw value is still readable, so a diagnostics dump can show what is there.
        XCTAssertEqual(try archive.captureState(.cursor), "{not json")
    }

    func testJSONOfTheWrongShapeDecodesAsNil() throws {
        try archive.setCaptureStateJSON(["unrelated": 1], for: .cursor)

        XCTAssertNil(try archive.captureStateJSON(.cursor, as: StubCursor.self))
    }

    // MARK: - Typed conveniences

    func testLastImportDateRoundTrips() throws {
        let date = Date(timeIntervalSince1970: 1_755_421_200)
        try archive.saveLastImport(date)

        let loaded = try XCTUnwrap(archive.lastImportDate())
        XCTAssertEqual(loaded.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.0001)
    }

    /// "Never imported" has to be distinguishable from "imported at the epoch", since
    /// it is what makes first launch different from every launch after it.
    func testLastImportDateIsNilBeforeAnyImport() throws {
        XCTAssertNil(try archive.lastImportDate())
    }

    func testLastImportDateIsNilWhenTheStoredValueIsNotANumber() throws {
        try archive.setCaptureState("yesterday", for: .lastImportAt)

        XCTAssertNil(try archive.lastImportDate())
    }

    func testAdapterIDRoundTrips() throws {
        try archive.saveAdapterID("v14")
        XCTAssertEqual(try archive.adapterID(), "v14")
    }

    // MARK: Private

    /// Stands in for `BackglanceCapture`'s `StoreCursor`, which `BackglanceCore`
    /// cannot see — the archive stores these as opaque JSON precisely so the
    /// dependency only points one way.
    private struct StubCursor: Codable, Hashable {
        var lastRecID: Int64
        var lastDeliveredDate: Double
    }

    private var archive: Archive!
}
