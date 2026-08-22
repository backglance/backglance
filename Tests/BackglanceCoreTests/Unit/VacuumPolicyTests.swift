@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

/// Covers `VacuumPolicy` and the archive maintenance it drives: when a repack is due, who
/// is allowed to ask for one, and what the cheap operations do on a file that cannot
/// support them.
///
/// See docs/operations/MAINTENANCE.md#vacuum-policy.
final class VacuumPolicyTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try Self.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        archive = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Who may repack

    /// The restriction the whole policy hangs on. A `VACUUM` briefly blocks writers, so it
    /// is allowed where a pause is explainable and nowhere else.
    func testOnlyLaunchAndManualMayRepack() {
        XCTAssertTrue(RetentionJob.Trigger.launch.allowsFullVacuum)
        XCTAssertTrue(RetentionJob.Trigger.manual.allowsFullVacuum)
        XCTAssertFalse(RetentionJob.Trigger.timer.allowsFullVacuum, "an unexplained freeze mid-afternoon")
    }

    // MARK: - When one is due

    /// An archive that has never been repacked is due, rather than waiting a month for its
    /// first — which is what gives a file created before this policy existed one at all.
    func testAnArchiveThatHasNeverBeenVacuumedIsDue() {
        XCTAssertTrue(
            VacuumPolicy.default.isFullVacuumDue(space: Self.space(free: 0, of: 100), lastVacuumAt: nil, now: Self.now)
        )
    }

    func testATidyArchiveVacuumedRecentlyIsNotDue() {
        XCTAssertFalse(VacuumPolicy.default.isFullVacuumDue(
            space: Self.space(free: 1, of: 100),
            lastVacuumAt: Self.now.addingTimeInterval(-86_400),
            now: Self.now
        ))
    }

    func testAMonthSinceTheLastOneIsDueEvenWhenTheFileIsTidy() {
        XCTAssertTrue(VacuumPolicy.default.isFullVacuumDue(
            space: Self.space(free: 0, of: 100),
            lastVacuumAt: Self.now.addingTimeInterval(-31 * 86_400),
            now: Self.now
        ))
    }

    /// A file a fifth empty is worth repacking whatever the calendar says — a big prune is
    /// exactly the event that leaves one that way, and waiting a month to act on it is how
    /// a 400 MB file survives a seven-day retention policy.
    func testAFileMostlyFreeSpaceIsDueRegardlessOfTheCalendar() {
        XCTAssertTrue(VacuumPolicy.default.isFullVacuumDue(
            space: Self.space(free: 30, of: 100),
            lastVacuumAt: Self.now.addingTimeInterval(-3_600),
            now: Self.now
        ))
    }

    func testTheThresholdIsExclusive() {
        XCTAssertFalse(VacuumPolicy.default.isFullVacuumDue(
            space: Self.space(free: 20, of: 100),
            lastVacuumAt: Self.now.addingTimeInterval(-3_600),
            now: Self.now
        ))
    }

    /// An empty file has no ratio to speak of. Reported as zero rather than as a division
    /// by zero the caller has to guard.
    func testAnEmptyFileHasNoFreeRatio() {
        XCTAssertEqual(Self.space(free: 0, of: 0).freeRatio, 0)
    }

    // MARK: - Applying it

    func testAPassThatDeletedNothingDoesNoHousekeeping() throws {
        let archive = try makeArchive()

        let outcome = VacuumPolicy.default.apply(to: archive, hardDeleted: false, trigger: .timer, now: Self.now)

        XCTAssertFalse(outcome.optimizedIndex)
        XCTAssertFalse(outcome.incrementalVacuum)
        XCTAssertFalse(outcome.fullVacuum)
    }

    func testAPassThatDeletedSomethingOptimizesTheIndexAndTrimsPages() throws {
        let archive = try makeArchive()

        let outcome = VacuumPolicy.default.apply(to: archive, hardDeleted: true, trigger: .timer, now: Self.now)

        XCTAssertTrue(outcome.optimizedIndex)
        XCTAssertTrue(outcome.incrementalVacuum)
        XCTAssertFalse(outcome.fullVacuum, "the timer may never repack")
    }

    func testLaunchRepacksAnArchiveThatHasNeverBeenVacuumed() throws {
        let archive = try makeArchive()

        let outcome = VacuumPolicy.default.apply(to: archive, hardDeleted: true, trigger: .launch, now: Self.now)

        XCTAssertTrue(outcome.fullVacuum)
    }

    /// And records when, so the next launch does not repack again.
    func testARepackRecordsItsTimeAndTheNextLaunchLeavesItAlone() throws {
        let archive = try makeArchive()
        _ = VacuumPolicy.default.apply(to: archive, hardDeleted: true, trigger: .launch, now: Self.now)
        XCTAssertNotNil(try archive.metaValue(forKey: VacuumPolicy.lastVacuumKey))

        let second = VacuumPolicy.default.apply(to: archive, hardDeleted: true, trigger: .launch, now: Self.now)

        XCTAssertFalse(second.fullVacuum)
    }

    // MARK: - auto_vacuum

    /// 🔒 A new archive can reclaim pages without rewriting itself. The pragma only takes
    /// on a database with no tables yet, which is why it is on the connection rather than
    /// in a migration — and why this is worth asserting rather than assuming.
    func testANewArchiveSupportsIncrementalVacuum() throws {
        XCTAssertTrue(try makeArchive().supportsIncrementalVacuum())
    }

    /// The conversion path for a file created before that was true: a full repack records
    /// the setting, and the cheap operation works from then on.
    func testARepackConvertsAnArchiveThatLackedAutoVacuum() throws {
        let url = try XCTUnwrap(directory).appendingPathComponent("legacy.sqlite")
        try Self.makeLegacyArchiveWithoutAutoVacuum(at: url)
        let archive = try Archive(path: url.path)
        XCTAssertFalse(try archive.supportsIncrementalVacuum(), "the fixture is meant to lack it")

        try archive.vacuum()

        XCTAssertTrue(try archive.supportsIncrementalVacuum())
    }

    // MARK: - Reporting

    func testTheSpaceReportDescribesTheRealFile() throws {
        let archive = try makeArchive()

        let space = try archive.spaceReport()

        XCTAssertGreaterThan(space.pageCount, 0)
        XCTAssertGreaterThan(space.pageSize, 0)
        XCTAssertEqual(space.byteCount, Int64(space.pageCount) * Int64(space.pageSize))
    }

    /// An in-memory archive has no volume to measure, and "cannot measure" must not become
    /// "refuse" — a maintenance routine that failed closed on an unknown would never run.
    func testAnUnmeasurableVolumeDoesNotBlockMaintenance() throws {
        XCTAssertNil(Archive.availableCapacity(forArchiveAt: ":memory:"))
        XCTAssertNoThrow(try Archive(inMemory: true).vacuum())
    }

    // MARK: Private

    private static let now = Date(timeIntervalSince1970: 1_787_236_200)

    private var archive: Archive?
    private var directory: URL?

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VacuumPolicyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func space(free: Int, of pages: Int) -> Archive.SpaceReport {
        Archive.SpaceReport(pageCount: pages, freelistCount: free, pageSize: 4_096)
    }

    /// A database whose tables were created without `auto_vacuum`, which is what every
    /// archive written before this policy looks like.
    private static func makeLegacyArchiveWithoutAutoVacuum(at url: URL) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA auto_vacuum = NONE")
        }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE placeholder (id INTEGER PRIMARY KEY)")
        }
        try queue.close()
    }

    /// A file-backed archive, because every operation here is about bytes on disk and an
    /// in-memory database has none to reclaim.
    private func makeArchive() throws -> Archive {
        let url = try XCTUnwrap(directory).appendingPathComponent("archive.sqlite")
        let archive = try Archive(path: url.path)
        self.archive = archive
        return archive
    }
}
