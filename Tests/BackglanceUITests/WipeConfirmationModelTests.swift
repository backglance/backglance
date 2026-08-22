import BackglanceCore
@testable import BackglanceUI
import Foundation
import XCTest

/// The two gates in front of the one action that cannot be undone. What matters here is
/// mostly what does *not* happen: a mistyped word, a cancelled prompt, or a second click
/// while the first is still running must all leave the archive exactly as it was.
@MainActor
final class WipeConfirmationModelTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - The typed word

    func testTheWordIsAcceptedRegardlessOfCaseOrSurroundingSpace() throws {
        let model = try makeModel()

        for typed in ["wipe", "WIPE", "Wipe", "  wipe\n"] {
            model.typed = typed
            XCTAssertTrue(model.isConfirmationWordTyped, "rejected \"\(typed)\"")
        }
    }

    /// 🔒 The Turkish rule. A locale-sensitive fold of "WIPE" in a Turkish locale does not
    /// produce "wipe", which would leave a Turkish user unable to confirm.
    func testTheWordIsFoldedWithoutALocale() throws {
        let model = try makeModel()
        let turkish = Locale(identifier: "tr_TR")
        model.typed = "WIPE"

        XCTAssertTrue(model.isConfirmationWordTyped)
        XCTAssertNotEqual("WIPE".lowercased(with: turkish), "wipe", "the trap this guards")
    }

    func testAnythingElseIsRejected() throws {
        let model = try makeModel()

        for typed in ["", "wip", "wipes", "delete", "wipe archive"] {
            model.typed = typed
            XCTAssertFalse(model.isConfirmationWordTyped, "accepted \"\(typed)\"")
        }
    }

    func testTheButtonStaysDisabledUntilTheWordMatches() throws {
        let model = try makeModel()

        XCTAssertFalse(model.canWipe)
        model.typed = "wipe"
        XCTAssertTrue(model.canWipe)
    }

    /// Without an archive there is nothing to wipe, and a button that does nothing when
    /// pressed is worse than one that is visibly unavailable.
    func testWithoutAnArchiveTheButtonIsNeverEnabled() {
        let model = WipeConfirmationModel(archive: nil, biometrics: StubGate(isAvailable: false))
        model.typed = "wipe"

        XCTAssertFalse(model.canWipe)
    }

    func testConfirmingWithoutTheWordDeletesNothing() async throws {
        let archive = try XCTUnwrap(archive)
        let model = try makeModel()
        try seed(archive)
        model.typed = "delete"

        await model.confirm()

        XCTAssertEqual(model.failure, .confirmationMismatch)
        XCTAssertFalse(model.didWipe)
        try XCTAssertEqual(count(in: archive), 1)
    }

    // MARK: - Touch ID

    /// 🔒 A cancelled or failed prompt deletes nothing. The wipe runs after both gates, not
    /// between them.
    func testAFailedPromptDeletesNothing() async throws {
        let archive = try XCTUnwrap(archive)
        let gate = StubGate(isAvailable: true, result: .failure(StubError.cancelled))
        let model = WipeConfirmationModel(archive: archive, biometrics: gate)
        try seed(archive)
        model.typed = "wipe"

        await model.confirm()

        XCTAssertEqual(model.failure, .biometricsFailed)
        XCTAssertFalse(model.didWipe)
        try XCTAssertEqual(count(in: archive), 1)
    }

    /// A Mac with no Secure Enclave, or a clamshell with an external keyboard. The typed
    /// word is the only gate, and the wipe still works — the alternative is a Mac that
    /// cannot be wiped at all.
    func testAMacWithoutTouchIDCanStillWipe() async throws {
        let archive = try XCTUnwrap(archive)
        let gate = StubGate(isAvailable: false)
        let model = WipeConfirmationModel(archive: archive, biometrics: gate)
        try seed(archive)
        model.typed = "wipe"

        await model.confirm()

        XCTAssertFalse(model.asksForBiometrics)
        XCTAssertEqual(gate.authenticationCount, 0, "nothing to ask")
        XCTAssertTrue(model.didWipe)
        try XCTAssertEqual(count(in: archive), 0)
    }

    func testAPassedPromptWipes() async throws {
        let archive = try XCTUnwrap(archive)
        let gate = StubGate(isAvailable: true)
        let model = WipeConfirmationModel(archive: archive, biometrics: gate)
        try seed(archive)
        model.typed = "wipe"

        await model.confirm()

        XCTAssertEqual(gate.authenticationCount, 1)
        XCTAssertNil(model.failure)
        XCTAssertTrue(model.didWipe)
        try XCTAssertEqual(count(in: archive), 0)
    }

    // MARK: - Around the wipe

    /// Capture writes to the archive being destroyed, so it stops first — and starts again
    /// afterwards, because a failed wipe is a reason to tell the user, not a reason to leave
    /// their Mac quietly not capturing.
    func testCaptureIsPausedBeforeTheWipeAndResumedAfter() async throws {
        let archive = try XCTUnwrap(archive)
        let events = EventLog()
        let model = WipeConfirmationModel(
            archive: archive,
            biometrics: StubGate(isAvailable: false),
            pauseCapture: { await events.append("pause") },
            resumeCapture: { await events.append("resume") }
        )
        model.typed = "wipe"

        await model.confirm()
        try await Task.sleep(for: .milliseconds(50))

        let recorded = await events.entries
        XCTAssertEqual(recorded, ["pause", "resume"])
    }

    func testCaptureIsNotPausedWhenAGateRejects() async throws {
        let archive = try XCTUnwrap(archive)
        let events = EventLog()
        let model = WipeConfirmationModel(
            archive: archive,
            biometrics: StubGate(isAvailable: true, result: .failure(StubError.cancelled)),
            pauseCapture: { await events.append("pause") },
            resumeCapture: { await events.append("resume") }
        )
        model.typed = "wipe"

        await model.confirm()

        let recorded = await events.entries
        XCTAssertTrue(recorded.isEmpty, "\(recorded)")
    }

    /// A wipe that could not remove everything still happened. The sheet has to report the
    /// leftovers *and* treat the archive as gone, because it is.
    func testAnIncompleteWipeIsStillAWipe() async throws {
        let model = try makeModel()
        model.typed = "wipe"

        await model.confirm()
        // The in-memory archive removes no files, so this is asserted on the mapping rather
        // than reproduced: `.incomplete` is the one failure that leaves `didWipe` true.
        XCTAssertTrue(model.didWipe)
        XCTAssertNil(model.failure)
        XCTAssertEqual(
            WipeConfirmationError.incomplete(remaining: ["icons"]).userMessage,
            String(localized: "Backglance was wiped, but some files couldn’t be removed. See the log for details.")
        )
    }

    func testResetClearsTheFieldAndTheLastOutcome() async throws {
        let model = try makeModel()
        model.typed = "delete"
        model.forgetPerAppSettings = true
        await model.confirm()

        model.reset()

        XCTAssertEqual(model.typed, "")
        XCTAssertFalse(model.forgetPerAppSettings)
        XCTAssertNil(model.failure)
        XCTAssertFalse(model.didWipe)
    }

    // MARK: Private

    /// Records calls in order, across the actor hops the closures make.
    private actor EventLog {
        private(set) var entries: [String] = []

        func append(_ entry: String) {
            entries.append(entry)
        }
    }

    private struct StubGate: BiometricGate {
        // MARK: Internal

        var isAvailable: Bool
        var result: Result<Void, StubError> = .success(())

        var authenticationCount: Int {
            counter.value
        }

        func authenticate(reason _: String) async throws {
            counter.increment()
            try result.get()
        }

        // MARK: Private

        private let counter = Counter()
    }

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

    private enum StubError: Error {
        case cancelled
    }

    private var archive: Archive?

    private func makeModel() throws -> WipeConfirmationModel {
        try WipeConfirmationModel(archive: XCTUnwrap(archive), biometrics: StubGate(isAvailable: false))
    }

    private func seed(_ archive: Archive) throws {
        let now = Date()
        let app = try archive.upsertApp(bundleID: "com.example.app", now: now)
        let notification = try ArchivedNotification(
            uuid: UUID().uuidString,
            appId: XCTUnwrap(app.id),
            title: "Aurora Bank",
            body: "Lunch at one?",
            deliveredAt: UnixDate(now),
            capturedAt: UnixDate(now),
            storeRecId: 1
        )
        _ = try archive.insertOrUpdate(notification)
    }

    private func count(in archive: Archive) throws -> Int {
        try archive.pool.read { db in try ArchivedNotification.fetchCount(db) }
    }
}
