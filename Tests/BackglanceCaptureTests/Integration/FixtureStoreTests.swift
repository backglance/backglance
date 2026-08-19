@testable import BackglanceCapture
import BackglanceTestSupport
import Foundation
import GRDB
import XCTest

// MARK: - FixtureManifest

/// `manifest.json` — what a fixture claims about itself.
///
/// Every claim here is checked rather than trusted: the fingerprint is recomputed from
/// `store.db`, the adapter is resolved rather than looked up, and the record count is
/// compared with what the adapter actually reads.
struct FixtureManifest: Decodable {
    enum CodingKeys: String, CodingKey {
        case osVersion = "os_version"
        case build
        case createdAt = "created_at"
        case generatorVersion = "generator_version"
        case schemaSHA256 = "schema_sha256"
        case dbinfoVersion = "dbinfo_version"
        case adapterID = "adapter_id"
        case seed
        case recordCount = "record_count"
        case notes
    }

    var osVersion: String
    var build: String
    var createdAt: String
    var generatorVersion: String
    var schemaSHA256: String
    var dbinfoVersion: String?
    var adapterID: String
    var seed: UInt64
    var recordCount: Int
    var notes: String

    var osMajor: Int {
        Int(osVersion.split(separator: ".").first ?? "0") ?? 0
    }
}

// MARK: - ExpectedNotification

/// One entry of `expected.json`: what the adapter and the parser must produce.
struct ExpectedNotification: Decodable, Equatable {
    var bundleID: String
    var uuid: String
    var title: String?
    var subtitle: String?
    var body: String?
    var sender: String?
    var threadID: String?
    var category: String?

    /// Unix seconds — the store keeps Cocoa reference seconds, and converting them is one
    /// of the things this file exists to check.
    var deliveredAt: Double
    var presented: Bool
    var userInfo: [String: String]
    var attachments: [ExpectedAttachment]
}

// MARK: - ExpectedAttachment

struct ExpectedAttachment: Decodable, Equatable {
    var type: String
    var name: String?
    var size: Int?
}

// MARK: - ExpectedCursor

struct ExpectedCursor: Decodable, Equatable {
    var lastRecID: Int64
    var lastDeliveredDate: Double
}

// MARK: - ExpectedFile

struct ExpectedFile: Decodable {
    var notifications: [ExpectedNotification]
    var cursor: ExpectedCursor
}

// MARK: - FixtureStoreTests

/// ⚠️ The one test that says whether Backglance can still read the store it was built for.
///
/// Every other capture test uses a database the test itself wrote, which proves the code
/// is self-consistent and nothing more. These run against the checked-in fixtures — a
/// store shaped like the real one for each supported macOS — and assert the whole chain
/// end to end: the fingerprint is what the manifest says, the registry resolves the
/// adapter the manifest names, the probe passes, every record parses, and each one parses
/// to exactly what `expected.json` records.
///
/// When a macOS update changes the store, this is the test that goes red, and the process
/// for what to do next is in docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md. Do not
/// "fix" it by relaxing an assertion.
class FixtureStoreTests: XCTestCase {
    // MARK: Internal

    /// Restricts the run to one fixture directory. `nil` runs all of them.
    class var only: String? {
        nil
    }

    // MARK: - The whole chain, per fixture

    func testEveryFixtureFingerprintsToWhatItsManifestClaims() throws {
        try forEachFixture { fixture in
            let fingerprint = try fixture.queue.read { db in try StoreFingerprint.compute(in: db) }

            XCTAssertEqual(fingerprint.schemaHash, fixture.manifest.schemaSHA256, fixture.name)
            XCTAssertEqual(fingerprint.dbinfoVersion, fixture.manifest.dbinfoVersion, fixture.name)
        }
    }

    /// A hash the fixtures produced is a hash `KnownFingerprints.json` carries — that is
    /// the whole basis on which an exact match is trusted at runtime.
    func testEveryFixtureResolvesToTheAdapterItsManifestNames() throws {
        try forEachFixture { fixture in
            let fingerprint = try fixture.queue.read { db in try StoreFingerprint.compute(in: db) }

            let resolved = StoreAdapterRegistry.resolve(fingerprint: fingerprint)
            XCTAssertEqual(resolved?.adapterID, fixture.manifest.adapterID, fixture.name)
            XCTAssertTrue(
                StoreFingerprints.hashes(forAdapter: fixture.manifest.adapterID).contains(fingerprint.schemaHash),
                "\(fixture.name): the fixture's hash is missing from KnownFingerprints.json"
            )
        }
    }

    func testEveryFixtureProbesCleanWithTheCountItsManifestClaims() throws {
        try forEachFixture { fixture in
            let result = try fixture.queue.read { db in try fixture.adapter.probe(db) }

            XCTAssertEqual(result, .ok(recordCount: fixture.manifest.recordCount), fixture.name)
        }
    }

    /// The fingerprint is exact and the probe passes, so resolution must be a match rather
    /// than the best-effort fallback — the state Settings shows a note for.
    func testEveryFixtureResolvesAsAMatchRatherThanAFallback() throws {
        try forEachFixture { fixture in
            let resolution = try fixture.queue.read { db in
                try StoreAdapterRegistry.resolve(fingerprint: StoreFingerprint.compute(in: db), probing: db)
            }

            guard case let .matched(adapter) = resolution else {
                return XCTFail("\(fixture.name): expected .matched, got \(resolution.logDescription)")
            }
            XCTAssertEqual(adapter.adapterID, fixture.manifest.adapterID, fixture.name)
        }
    }

    /// The one that would catch a parser regression: every record, compared field by field
    /// with what the generator recorded — not with what the parser produced.
    func testEveryFixtureParsesToItsExpectedNotifications() throws {
        try forEachFixture { fixture in
            let parsed = try fixture.parseAll()

            XCTAssertEqual(parsed.count, fixture.expected.notifications.count, fixture.name)
            for (index, expected) in fixture.expected.notifications.enumerated() where index < parsed.count {
                let actual = parsed[index]
                let context = "\(fixture.name) rec \(index + 1)"

                XCTAssertEqual(actual.bundleID, expected.bundleID, context)
                XCTAssertEqual(actual.uuid.uuidString, expected.uuid, context)
                XCTAssertEqual(actual.title, expected.title, context)
                XCTAssertEqual(actual.subtitle, expected.subtitle, context)
                XCTAssertEqual(actual.body, expected.body, context)
                XCTAssertEqual(actual.sender, expected.sender, context)
                XCTAssertEqual(actual.threadID, expected.threadID, context)
                XCTAssertEqual(actual.category, expected.category, context)
                XCTAssertEqual(actual.presented, expected.presented, context)
                XCTAssertEqual(actual.userInfo, expected.userInfo, context)
                XCTAssertEqual(
                    actual.attachments.map { ExpectedAttachment(type: $0.type, name: $0.name, size: $0.size) },
                    expected.attachments,
                    context
                )
                XCTAssertEqual(
                    actual.deliveredAt.timeIntervalSince1970,
                    expected.deliveredAt,
                    accuracy: 0.001,
                    context
                )
            }
        }
    }

    /// Where a full read leaves the cursor — the value a relaunch resumes from.
    func testEveryFixtureLeavesTheCursorWhereExpected() throws {
        try forEachFixture { fixture in
            var cursor = StoreCursor.start
            while true {
                let batch = try fixture.queue.read { db in try fixture.adapter.records(after: cursor, in: db) }
                guard let last = batch.last else {
                    break
                }
                cursor = fixture.adapter.cursor(for: last)
            }

            XCTAssertEqual(cursor.lastRecID, fixture.expected.cursor.lastRecID, fixture.name)
            XCTAssertEqual(
                cursor.lastDeliveredDate?.timeIntervalSince1970 ?? 0,
                fixture.expected.cursor.lastDeliveredDate,
                accuracy: 0.001,
                fixture.name
            )
        }
    }

    /// 🔒 A fixture is committed to a public repository. Its manifest has to say what it is
    /// before anyone reads a line of it.
    func testEveryFixtureDeclaresItselfSynthetic() throws {
        try forEachFixture { fixture in
            XCTAssertTrue(fixture.manifest.notes.hasPrefix("Synthetic."), fixture.name)
        }
    }

    // MARK: Private

    /// One fixture, loaded.
    private struct Fixture {
        var name: String
        var manifest: FixtureManifest
        var expected: ExpectedFile
        var adapter: any StoreAdapter
        var queue: DatabaseQueue

        /// Every record, read in batches and parsed, the way a first-launch import does.
        func parseAll() throws -> [ParsedNotification] {
            let parser = RecordParser()
            var cursor = StoreCursor.start
            var parsed: [ParsedNotification] = []

            while true {
                let batch = try queue.read { db in try adapter.records(after: cursor, in: db) }
                guard let last = batch.last else {
                    break
                }
                try parsed.append(contentsOf: batch.map { try parser.parse($0) })
                cursor = adapter.cursor(for: last)
            }
            return parsed
        }
    }

    private static var root: URL? {
        Fixtures.exists(Fixtures.systemStore) ? Fixtures.systemStore : nil
    }

    /// Runs `body` for every fixture the class covers, failing if there are none: a
    /// harness that silently tests nothing is worse than no harness.
    private func forEachFixture(_ body: (Fixture) throws -> Void) throws {
        let root = try XCTUnwrap(Self.root, "SystemStore fixtures are missing from the test bundle")
        let directories = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("macOS") }
            .filter { Self.only == nil || $0.lastPathComponent == Self.only }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertFalse(directories.isEmpty, "no fixtures found under \(root.path)")
        for directory in directories {
            try body(load(directory))
        }
    }

    private func load(_ directory: URL) throws -> Fixture {
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(
            FixtureManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        )
        let expected = try decoder.decode(
            ExpectedFile.self,
            from: Data(contentsOf: directory.appendingPathComponent("expected.json"))
        )

        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(
            path: directory.appendingPathComponent("store.db").path,
            configuration: configuration
        )

        let adapter = try XCTUnwrap(
            StoreAdapterRegistry.adapters.first { $0.adapterID == manifest.adapterID },
            "no adapter with id \(manifest.adapterID)"
        )

        return Fixture(
            name: directory.lastPathComponent,
            manifest: manifest,
            expected: expected,
            adapter: adapter,
            queue: queue
        )
    }
}

// MARK: - FixtureMacOS14Tests

/// One fixture at a time, so `-only-testing` and `Scripts/verify_fixture.sh --os 14` can
/// target it. The assertions are the base class's.
///
/// Not `final`: `only` is a `class var` because it is overridden, and that is the whole
/// mechanism these three subclasses exist for.
class FixtureMacOS14Tests: FixtureStoreTests {
    override class var only: String? {
        "macOS14"
    }
}

// MARK: - FixtureMacOS15Tests

class FixtureMacOS15Tests: FixtureStoreTests {
    override class var only: String? {
        "macOS15"
    }
}

// MARK: - FixtureMacOS26Tests

class FixtureMacOS26Tests: FixtureStoreTests {
    override class var only: String? {
        "macOS26"
    }
}
