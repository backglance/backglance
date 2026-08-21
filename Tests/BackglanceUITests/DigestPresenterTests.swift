@testable import BackglanceCore
import BackglanceTestSupport
@testable import BackglanceUI
import Foundation
import GRDB
import XCTest

/// Covers `DigestPresenter`: which digest (if any) `refresh()` surfaces, that the same
/// `DigestViewModel` instance survives a repeat `refresh()`, and that `dismiss()` — from
/// either the presenter or the card itself — retires the digest for good.
///
/// Runs on `Archive(inMemory: true)`, matching `DigestViewModelTests` and
/// `ArchiveDigestTests` — foreign keys are enforced, so a digest row here is only ever
/// reachable through a real away session.
@MainActor
final class DigestPresenterTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archiveStorage = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archiveStorage = nil
        try super.tearDownWithError()
    }

    // MARK: - refresh()

    func testRefreshWithNoDigestRowsLeavesCurrentNilAndHasDigestFalse() throws {
        let presenter = try makePresenter()

        presenter.refresh()

        XCTAssertNil(presenter.current)
        XCTAssertFalse(presenter.hasDigest)
    }

    func testRefreshSurfacesAPendingDigest() throws {
        let digestID = try insertDigest()
        let presenter = try makePresenter()

        presenter.refresh()

        XCTAssertEqual(presenter.current?.digest.id, digestID)
        XCTAssertTrue(presenter.hasDigest)
    }

    func testADismissedDigestIsNeverSurfaced() throws {
        let digestID = try insertDigest()
        try archive().dismissDigest(digestID, at: base)
        let presenter = try makePresenter()

        presenter.refresh()

        XCTAssertNil(presenter.current)
    }

    func testTheNewestUndismissedDigestWinsWhenTwoExist() throws {
        _ = try insertDigest(createdAt: base)
        let newer = try insertDigest(createdAt: base.addingTimeInterval(600))
        let presenter = try makePresenter()

        presenter.refresh()

        XCTAssertEqual(presenter.current?.digest.id, newer)
    }

    func testRefreshTwiceForTheSameDigestKeepsTheSameViewModelInstance() throws {
        _ = try insertDigest()
        let presenter = try makePresenter()

        presenter.refresh()
        let first = try XCTUnwrap(presenter.current)
        presenter.refresh()
        let second = try XCTUnwrap(presenter.current)

        XCTAssertIdentical(first, second, "rebuilding would drop card state the user is mid-way through")
    }

    func testRefreshAfterANewDigestIsBuiltReplacesTheModel() throws {
        let firstID = try insertDigest(createdAt: base)
        let presenter = try makePresenter()
        presenter.refresh()
        let firstModel = try XCTUnwrap(presenter.current)
        XCTAssertEqual(firstModel.digest.id, firstID)

        let secondID = try insertDigest(createdAt: base.addingTimeInterval(600))
        presenter.refresh()
        let secondModel = try XCTUnwrap(presenter.current)

        XCTAssertEqual(secondModel.digest.id, secondID)
        XCTAssertNotIdentical(firstModel, secondModel)
    }

    // MARK: - dismiss()

    func testDismissClearsCurrentAndWritesDismissedAtInTheArchive() throws {
        let digestID = try insertDigest()
        let clock = TestClock(now: base)
        let presenter = try makePresenter(clock: clock)
        presenter.refresh()
        XCTAssertNotNil(presenter.current)

        presenter.dismiss()

        XCTAssertNil(presenter.current)
        let stored = try XCTUnwrap(try fetchDigest(digestID))
        XCTAssertEqual(stored.dismissedAt?.date, base)
    }

    func testTheCardsOwnDismissAlsoClearsCurrentThroughTheOnDismissedHook() throws {
        _ = try insertDigest()
        let presenter = try makePresenter()
        presenter.refresh()
        let model = try XCTUnwrap(presenter.current)

        model.dismiss()

        XCTAssertNil(presenter.current)
    }

    func testARefreshAfterDismissStillYieldsNil() throws {
        _ = try insertDigest()
        let presenter = try makePresenter()
        presenter.refresh()
        presenter.dismiss()

        presenter.refresh()

        XCTAssertNil(presenter.current, "a dismissed digest never comes back")
    }

    // MARK: Private

    private var archiveStorage: Archive?

    private let base = Date(timeIntervalSince1970: 1_755_600_000)

    private func archive() throws -> Archive {
        try XCTUnwrap(archiveStorage)
    }

    private func makePresenter(clock: TestClock? = nil) throws -> DigestPresenter {
        let clock = clock ?? TestClock(now: base)
        return try DigestPresenter(archive: archive()) { clock.now }
    }

    /// A minimal digest row, backed by a real away session so the foreign key holds.
    /// Returns its id.
    @discardableResult
    private func insertDigest(createdAt: Date? = nil) throws -> Int64 {
        let created = createdAt ?? base
        let session = try archive().insertAwaySession(
            AwaySession(
                startedAt: UnixDate(created.addingTimeInterval(-600)),
                endedAt: UnixDate(created),
                reason: .locked
            )
        )
        return try archive().pool.write { db in
            var digest = try Digest(
                awaySessionId: XCTUnwrap(session.id),
                createdAt: UnixDate(created)
            )
            try digest.insert(db)
            return try XCTUnwrap(digest.id)
        }
    }

    private func fetchDigest(_ id: Int64) throws -> Digest? {
        try archive().pool.read { db in try Digest.fetchOne(db, key: id) }
    }
}
