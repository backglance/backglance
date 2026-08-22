@testable import BackglanceCapture
import BackglanceCore
import Foundation
import XCTest

// MARK: - CaptureExclusionTests

/// 🔒 Privacy Invariant #3, at the one place it can actually be broken: the pipeline.
///
/// `ExclusionListTests` covers *what* is excluded. This file covers *when* the question is
/// asked, which is the half that matters — a list that is correct and consulted after the
/// parse has already turned a password manager's notification into strings in memory.
///
/// Split out of `CaptureEnginePipelineTests` because it had grown past the file-length
/// limit, and because these belong together: every test here is a variation on "did the
/// check run early enough, against the right list".
///
/// See docs/features/PRIVACY_CONTROLS.md#where-exclusion-happens.
final class CaptureExclusionTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        let archive = try Archive(inMemory: true)
        let directory = try Self.temporaryDirectory()

        self.archive = archive
        self.directory = directory
        storeURL = directory.appendingPathComponent("db")
    }

    override func tearDownWithError() throws {
        watcher?.stop()
        watcher = nil
        archive = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Where the check runs

    /// 🔒 The invariant: exclusion runs on the store row, before the payload is decoded.
    /// The payload here names an app that *is* allowed — so if the check ran after the
    /// parse, this notification would be archived.
    func testAnExcludedAppsPayloadIsNeverDecoded() async throws {
        let archive = try XCTUnwrap(archive)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [
            MiniatureStore.notification(
                recID: 1,
                bundleID: "com.example.passwords",
                payloadBundleID: "com.example.chat"
            ),
        ])
        let exclusions = DenyList(["com.example.passwords"])
        let engine = try makeEngine(exclusions: exclusions)

        try archive.captureFromTheStartOfTheStore()

        await engine.start()
        await engine.tick(reason: .manual)

        let count = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(exclusions.asked.first, "com.example.passwords")
    }

    /// 🔒 The strongest form of the ordering claim, and the one that cannot pass by
    /// accident.
    ///
    /// The excluded record's payload is bytes the parser cannot decode. If the parse ran
    /// first, the record would be counted `failed`; only a check that ran *before* it can
    /// count `excluded`. Asserting on nothing being archived — which the test above does —
    /// would hold either way, because a record that fails to parse is not archived either.
    func testAnExcludedRecordIsCountedExcludedRatherThanFailedToParse() async throws {
        let archive = try XCTUnwrap(archive)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [
            Self.undecodable(recID: 1, bundleID: "com.example.passwords"),
        ])
        let engine = try makeEngine(exclusions: DenyList(["com.example.passwords"]))

        try archive.captureFromTheStartOfTheStore()

        await engine.start()
        await engine.tick(reason: .manual)

        let totals = await engine.metrics.totals
        XCTAssertEqual(totals.excluded, 1)
        XCTAssertEqual(totals.failed, 0, "the payload was decoded, so the check ran after the parse")
    }

    /// The control for the test above. The same undecodable payload, from an app that is
    /// *not* excluded, is counted `failed` — which is what makes the `excluded` count
    /// there evidence about ordering rather than evidence that the payload was fine.
    func testTheSameUndecodablePayloadIsCountedFailedWhenTheAppIsAllowed() async throws {
        let archive = try XCTUnwrap(archive)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [
            Self.undecodable(recID: 1, bundleID: "com.example.chat"),
        ])
        let engine = try makeEngine()

        try archive.captureFromTheStartOfTheStore()

        await engine.start()
        await engine.tick(reason: .manual)

        let totals = await engine.metrics.totals
        XCTAssertEqual(totals.failed, 1)
        XCTAssertEqual(totals.excluded, 0)
    }

    /// Helper processes and iPhone Mirroring post on behalf of another bundle, so the
    /// payload's own app has to be checked too — that is the app the user excluded.
    func testAnAppExcludedByThePayloadsOwnBundleIDIsAlsoSkipped() async throws {
        let archive = try XCTUnwrap(archive)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [
            MiniatureStore.notification(
                recID: 1,
                bundleID: "com.apple.iphonemirroring",
                payloadBundleID: "com.example.passwords"
            ),
        ])
        let engine = try makeEngine(exclusions: DenyList(["com.example.passwords"]))

        try archive.captureFromTheStartOfTheStore()

        await engine.start()
        await engine.tick(reason: .manual)

        let count = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        XCTAssertEqual(count, 0)
    }

    // MARK: - The shipped list

    /// 🔒 The real list, not a stub. A password manager is excluded on an archive nobody
    /// has configured — which is the case that matters, because it is every user's first
    /// launch.
    func testTheShippedExclusionListSkipsAPasswordManagerWithNoConfiguration() async throws {
        let archive = try XCTUnwrap(archive)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [
            MiniatureStore.notification(recID: 1, bundleID: "com.1password.1password"),
            MiniatureStore.notification(recID: 2, bundleID: "com.example.chat"),
        ])
        let engine = try makeEngine(exclusions: ArchiveExclusionList(archive: archive))

        try archive.captureFromTheStartOfTheStore()

        await engine.start()
        await engine.tick(reason: .manual)

        let stored = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        XCTAssertEqual(stored, 1)
        let totals = await engine.metrics.totals
        XCTAssertEqual(totals.excluded, 1)
    }

    /// 🔒 A default the user switched off is archived again. The exclusion list is a
    /// starting position, not a policy, and a capture path that ignored the row would make
    /// the pane's toggle a lie.
    func testADefaultTheUserSwitchedOffIsArchivedAgain() async throws {
        let archive = try XCTUnwrap(archive)
        try MiniatureStore.makeFile(at: XCTUnwrap(storeURL), rows: [
            MiniatureStore.notification(recID: 1, bundleID: "com.1password.1password"),
        ])
        try archive.setExcluded(false, bundleID: "com.1password.1password")
        let engine = try makeEngine(exclusions: ArchiveExclusionList(archive: archive))

        try archive.captureFromTheStartOfTheStore()

        await engine.start()
        await engine.tick(reason: .manual)

        let stored = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        XCTAssertEqual(stored, 1)
    }

    /// The list is reloaded at the top of each tick, so excluding an app takes effect on
    /// the next notification rather than the next launch.
    func testExcludingAnAppBetweenTicksTakesEffectOnTheNextTick() async throws {
        let archive = try XCTUnwrap(archive)
        let storeURL = try XCTUnwrap(storeURL)
        try MiniatureStore.makeFile(at: storeURL, rows: [
            MiniatureStore.notification(recID: 1, bundleID: "com.example.chat"),
        ])
        let engine = try makeEngine(exclusions: ArchiveExclusionList(archive: archive))

        try archive.captureFromTheStartOfTheStore()
        await engine.start()
        await engine.tick(reason: .manual)

        try archive.setExcluded(true, bundleID: "com.example.chat")
        try MiniatureStore.append(
            [MiniatureStore.notification(recID: 2, bundleID: "com.example.chat")],
            to: storeURL
        )
        await engine.tick(reason: .manual)

        let stored = try await archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
        XCTAssertEqual(stored, 1, "the second notification arrived after the app was excluded")
    }

    // MARK: Private

    private var archive: Archive?
    private var watcher: StoreWatcher?
    private var directory: URL?
    private var storeURL: URL?

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureExclusionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A record whose payload is not a property list, so the parser is guaranteed to fail
    /// on it if it ever gets the chance.
    private static func undecodable(recID: Int64, bundleID: String) -> MiniatureStore.Row {
        var row = MiniatureStore.Row(recID: recID)
        row.bundleID = bundleID
        row.payload = Data("not a property list".utf8)
        return row
    }

    private func makeEngine(exclusions: any AppExclusionList = AllowAllApps()) throws -> CaptureEngine {
        let directory = try XCTUnwrap(directory)
        let storeURL = try XCTUnwrap(storeURL)
        let watcher = StoreWatcher(location: directory.appendingPathComponent("unused"), debounce: 0.01)
        self.watcher = watcher

        return try CaptureEngine(
            archive: XCTUnwrap(archive),
            watcher: watcher,
            exclusions: exclusions
        ) { storeURL }
    }
}

// MARK: - DenyList

/// An exclusion list that remembers what it was asked about, so a test can prove *when*
/// the question was put.
private final class DenyList: AppExclusionList, @unchecked Sendable {
    // MARK: Lifecycle

    init(_ excluded: Set<String>) {
        self.excluded = excluded
    }

    // MARK: Internal

    private(set) var asked: [String] = []

    func allows(_ bundleID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        asked.append(bundleID)
        return !excluded.contains(bundleID)
    }

    // MARK: Private

    private let excluded: Set<String>
    private let lock = NSLock()
}
