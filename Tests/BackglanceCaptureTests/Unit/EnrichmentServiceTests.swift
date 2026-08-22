@testable import BackglanceCapture
import Foundation
import XCTest

// MARK: - EnrichmentServiceTests

/// Enrichment is the part of capture that is allowed to come back empty-handed: an app
/// that has been uninstalled has no icon, and that costs the timeline a generic glyph
/// rather than costing the user a notification. These tests are mostly about that — and
/// about the cache doing its one job, which is not asking Launch Services twice.
final class EnrichmentServiceTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnrichmentServiceTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Caching

    func testAnAppsIconIsCachedOnFirstSight() async throws {
        let source = StubIconSource(installed: ["com.example.chat"])
        let service = try EnrichmentService(icons: makeCache(source: source))

        _ = await service.enrich(Self.notification(bundleID: "com.example.chat"))

        let cached = await service.iconURL(forBundleID: "com.example.chat")
        XCTAssertNotNil(cached)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(cached)), StubIconSource.png)
    }

    /// The timeline draws dozens of rows from a handful of apps. Resolving each one
    /// through Launch Services every time is what the cache exists to avoid.
    func testTheIconSourceIsAskedOnlyOncePerApp() async throws {
        let source = StubIconSource(installed: ["com.example.chat"])
        let service = try EnrichmentService(icons: makeCache(source: source))

        for _ in 0 ..< 5 {
            _ = await service.enrich(Self.notification(bundleID: "com.example.chat"))
        }

        XCTAssertEqual(source.requests, ["com.example.chat"])
    }

    // MARK: - Coming back empty-handed

    /// An app the user uninstalled still has notifications in the archive. That is a
    /// glyph problem, not a capture problem.
    func testAnUninstalledAppLeavesNoIconAndNoError() async throws {
        let source = StubIconSource(installed: [])
        let service = try EnrichmentService(icons: makeCache(source: source))

        let enriched = await service.enrich(Self.notification(bundleID: "com.example.gone"))

        let cached = await service.iconURL(forBundleID: "com.example.gone")
        XCTAssertNil(cached)
        XCTAssertEqual(enriched.bundleID, "com.example.gone")
    }

    func testEnrichmentReturnsTheNotificationUnchanged() async throws {
        let service = try EnrichmentService(icons: makeCache(source: StubIconSource(installed: ["com.example.chat"])))
        let notification = Self.notification(bundleID: "com.example.chat")

        let enriched = await service.enrich(notification)

        XCTAssertEqual(enriched, notification)
    }

    // MARK: - App names

    /// The timeline says "Messages", not `com.apple.MobileSMS` — but only because
    /// something asks Launch Services, since Apple's store does not carry the name.
    func testAnAppsDisplayNameIsResolved() async throws {
        let names = StubNameSource(names: ["com.example.chat": "Chatter"])
        let service = try EnrichmentService(icons: makeCache(source: StubIconSource(installed: [])), names: names)

        let resolved = await service.displayName(forBundleID: "com.example.chat")

        XCTAssertEqual(resolved, "Chatter")
    }

    func testAnUninstalledAppHasNoDisplayName() async throws {
        let names = StubNameSource(names: [:])
        let service = try EnrichmentService(icons: makeCache(source: StubIconSource(installed: [])), names: names)

        let resolved = await service.displayName(forBundleID: "com.example.gone")

        XCTAssertNil(resolved)
    }

    /// Capture asks once per archived notification. Without memoized *misses*, an app the
    /// user uninstalled would pay a file-system round trip for every record it ever sent.
    func testTheNameSourceIsAskedOnlyOncePerAppEvenWhenItComesBackEmpty() async throws {
        let names = StubNameSource(names: ["com.example.chat": "Chatter"])
        let service = try EnrichmentService(icons: makeCache(source: StubIconSource(installed: [])), names: names)

        for _ in 0 ..< 3 {
            _ = await service.displayName(forBundleID: "com.example.chat")
            _ = await service.displayName(forBundleID: "com.example.gone")
        }

        XCTAssertEqual(names.requests.sorted(), ["com.example.chat", "com.example.gone"])
    }

    // MARK: - The cache's file names

    /// ⚠️ The bundle id comes from Apple's store, so it is not ours to trust: one
    /// containing a path separator would otherwise write outside the cache directory.
    func testAHostileBundleIDCannotEscapeTheCacheDirectory() throws {
        let directory = try XCTUnwrap(directory)
        let cache = AppIconCache(directory: directory, source: StubIconSource(installed: ["../../etc/passwd"]))

        let url = try XCTUnwrap(cache.ensureIcon(forBundleID: "../../etc/passwd"))

        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertFalse(url.lastPathComponent.contains("/"))
    }

    func testTheCacheDirectoryIsCreatedPrivate() throws {
        let directory = try XCTUnwrap(directory)
        let cache = AppIconCache(directory: directory, source: StubIconSource(installed: ["com.example.chat"]))

        cache.ensureIcon(forBundleID: "com.example.chat")

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
    }

    // MARK: Private

    private var directory: URL?

    private static func notification(bundleID: String) -> ParsedNotification {
        ParsedNotification(
            bundleID: bundleID,
            uuid: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
            title: "Ada",
            deliveredAt: Date(timeIntervalSinceReferenceDate: 774_000_000),
            presented: true
        )
    }

    private func makeCache(source: any AppIconSource) throws -> AppIconCache {
        try AppIconCache(directory: XCTUnwrap(directory), source: source)
    }
}

// MARK: - StubIconSource

/// Stands in for Launch Services, and counts what it was asked.
private final class StubIconSource: AppIconSource, @unchecked Sendable {
    // MARK: Lifecycle

    init(installed: Set<String>) {
        self.installed = installed
    }

    // MARK: Internal

    static let png = Data("not really a png, but bytes are bytes".utf8)

    private(set) var requests: [String] = []

    func iconPNG(forBundleID bundleID: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        requests.append(bundleID)
        return installed.contains(bundleID) ? Self.png : nil
    }

    // MARK: Private

    private let installed: Set<String>
    private let lock = NSLock()
}

// MARK: - StubNameSource

/// Stands in for Launch Services' side of the name lookup, and counts what it was asked.
private final class StubNameSource: AppNameSource, @unchecked Sendable {
    // MARK: Lifecycle

    init(names: [String: String]) {
        self.names = names
    }

    // MARK: Internal

    private(set) var requests: [String] = []

    func name(forBundleID bundleID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        requests.append(bundleID)
        return names[bundleID]
    }

    // MARK: Private

    private let names: [String: String]
    private let lock = NSLock()
}
