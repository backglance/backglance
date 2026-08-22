import AppKit
import BackglanceCore
import BackglanceTestSupport
@testable import BackglanceUI
import Foundation
import XCTest

// MARK: - CopyActionTests

/// Covers the ⌘C / ⌥⌘C text format in docs/features/ACTIONS.md#copy and the
/// concealed-marker guarantee in
/// docs/security/SECURITY.md#concealed-pasteboard-copies. Every test that writes
/// to a pasteboard uses a private named one (`NSPasteboard(name:)`), never
/// `.general`, per docs/features/ACTIONS.md#testing-approach — nothing here is
/// allowed to touch the developer's real clipboard.
@MainActor
final class CopyActionTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("app.backglance.tests.\(UUID().uuidString)"))
    }

    override func tearDownWithError() throws {
        pasteboard?.releaseGlobally()
        handler = nil
        pasteboard = nil
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - Text format: title and body

    func testTitleAndBodyJoinedWithEmDash() throws {
        let id = try insertNotification(title: "Build finished", body: "All 42 tests passed")

        try makeHandler().copy(ids: [id], includeAppAndTimestamp: false)

        XCTAssertEqual(copiedText(), "Build finished — All 42 tests passed")
    }

    func testTitleOnlyCopiesJustTheTitleWithNoDanglingDash() throws {
        let id = try insertNotification(title: "Build finished", body: nil)

        try makeHandler().copy(ids: [id], includeAppAndTimestamp: false)

        XCTAssertEqual(copiedText(), "Build finished")
    }

    func testBodyOnlyCopiesJustTheBodyWithNoDanglingDash() throws {
        let id = try insertNotification(title: nil, body: "All 42 tests passed")

        try makeHandler().copy(ids: [id], includeAppAndTimestamp: false)

        XCTAssertEqual(copiedText(), "All 42 tests passed")
    }

    func testWhitespaceOnlyTitleIsDroppedLikeANilTitle() throws {
        let id = try insertNotification(title: "   ", body: "All 42 tests passed")

        try makeHandler().copy(ids: [id], includeAppAndTimestamp: false)

        XCTAssertEqual(copiedText(), "All 42 tests passed")
    }

    func testWhitespaceOnlyBodyIsDroppedLikeANilBody() throws {
        let id = try insertNotification(title: "Build finished", body: "\n\t ")

        try makeHandler().copy(ids: [id], includeAppAndTimestamp: false)

        XCTAssertEqual(copiedText(), "Build finished")
    }

    func testNeitherTitleNorBodyCopiesAnEmptyLine() throws {
        let id = try insertNotification(title: nil, body: nil)

        try makeHandler().copy(ids: [id], includeAppAndTimestamp: false)

        XCTAssertEqual(copiedText(), "")
    }

    // MARK: - Text format: app and timestamp (⌥⌘C)

    func testAppAndTimestampFormExactShape() throws {
        let delivered = Stubs.date(minutesAgo: 37)
        let id = try insertNotification(
            title: "Build finished",
            body: "All 42 tests passed",
            deliveredAt: delivered,
            bundleID: Stubs.BundleID.slack
        )

        try makeHandler().copy(ids: [id], includeAppAndTimestamp: true)

        let expected = "\(Stubs.BundleID.slack) · \(Self.expectedStamp(for: delivered))\n" +
            "Build finished — All 42 tests passed"
        XCTAssertEqual(copiedText(), expected)
    }

    // MARK: - Multi-select

    func testMultiSelectJoinsBlocksWithABlankLineInGivenOrder() throws {
        let first = try insertNotification(title: "First", body: "one")
        let second = try insertNotification(title: "Second", body: "two")

        // Order given is [second, first] — the copy must preserve exactly that,
        // not re-sort by id or delivery time.
        try makeHandler().copy(ids: [second, first], includeAppAndTimestamp: false)

        XCTAssertEqual(copiedText(), "Second — two\n\nFirst — one")
    }

    // MARK: - Redaction

    func testRedactedPlaceholderIsCopiedVerbatim() throws {
        let id = try insertNotification(
            title: nil,
            body: "Your code is [code redacted]",
            bundleID: Stubs.BundleID.messages,
            redaction: .otp
        )

        try makeHandler().copy(ids: [id], includeAppAndTimestamp: false)

        XCTAssertEqual(copiedText(), "Your code is [code redacted]")
    }

    // MARK: - Concealed marker

    /// The assertion docs/security/SECURITY.md#concealed-pasteboard-copies
    /// promises exists: every copy — ⌘C, ⌥⌘C, single or multi-select — leaves
    /// `org.nspasteboard.ConcealedType` on the pasteboard, so a clipboard
    /// manager that honors the convention skips recording it.
    func testConcealedMarkerIsPresentAfterEveryCopy() throws {
        let id = try insertNotification(title: "Build finished", body: "All 42 tests passed")

        try makeHandler().copy(ids: [id], includeAppAndTimestamp: false)

        let pasteboard = try XCTUnwrap(pasteboard)
        XCTAssertEqual(pasteboard.types?.contains(PasteboardCopier.concealedType), true)
    }

    func testConcealedMarkerIsPresentForTheAppAndTimestampForm() throws {
        let id = try insertNotification(title: "Build finished", body: "All 42 tests passed")

        try makeHandler().copy(ids: [id], includeAppAndTimestamp: true)

        let pasteboard = try XCTUnwrap(pasteboard)
        XCTAssertEqual(pasteboard.types?.contains(PasteboardCopier.concealedType), true)
    }

    // MARK: - Pasteboard failure

    func testPasteboardRefusingTheWriteSurfacesPasteboardFailure() throws {
        let id = try insertNotification(title: "Build finished", body: "All 42 tests passed")
        let handler = try NotificationActionHandler(
            archive: XCTUnwrap(archive),
            pasteboard: RefusingPasteboard()
        )

        XCTAssertThrowsError(try handler.copy(ids: [id], includeAppAndTimestamp: false)) { error in
            XCTAssertEqual(error as? ActionError, .pasteboardFailure)
        }
    }

    // MARK: - notFound propagation

    func testMissingIDPropagatesNotFound() throws {
        XCTAssertThrowsError(try makeHandler().copy(ids: [999], includeAppAndTimestamp: false)) { error in
            XCTAssertEqual(error as? ActionError, .notFound(notificationID: 999))
        }
    }

    // MARK: Private

    private var archive: Archive?
    private var pasteboard: NSPasteboard?
    private var handler: NotificationActionHandler?

    /// Builds the same fixed-format, `en_US_POSIX`-locale stamp `CopyAction`
    /// does, so the test asserts against a value computed the same way rather
    /// than a hand-typed string — both this and `CopyAction`'s own formatter
    /// leave `timeZone` at the system default, so the two agree on any machine
    /// without either one being pinned to a specific zone.
    private static func expectedStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func makeHandler() throws -> NotificationActionHandler {
        let handler = try NotificationActionHandler(
            archive: XCTUnwrap(archive),
            pasteboard: XCTUnwrap(pasteboard)
        )
        self.handler = handler
        return handler
    }

    private func copiedText() -> String? {
        pasteboard?.string(forType: .string)
    }

    /// Inserts a notification from `bundleID`, returning its id. `deliveredAt`
    /// defaults to `Stubs.epoch` — fine for every test except the
    /// app-and-timestamp one, which passes an explicit value.
    private func insertNotification(
        title: String?,
        body: String?,
        deliveredAt: Date = Stubs.epoch,
        bundleID: String = Stubs.BundleID.slack,
        redaction: ArchivedNotification.Redaction = .none
    ) throws -> Int64 {
        let archive = try XCTUnwrap(archive)
        let app = try archive.upsertApp(bundleID: bundleID, now: Stubs.epoch)
        let appID = try XCTUnwrap(app.id)
        let inserted = try archive.insert(ArchivedNotification(
            uuid: UUID().uuidString,
            appId: appID,
            title: title,
            body: body,
            deliveredAt: UnixDate(deliveredAt),
            capturedAt: UnixDate(deliveredAt),
            redaction: redaction
        ))
        return try XCTUnwrap(inserted.id)
    }
}

// MARK: - RefusingPasteboard

/// A ``PasteboardWriting`` conformance that refuses every write, so
/// ``ActionError/pasteboardFailure`` can be exercised without needing a real
/// pasteboard to lose a race it cannot be made to lose from a single-threaded
/// test. See ``PasteboardWriting``'s doc comment.
private final class RefusingPasteboard: PasteboardWriting {
    func clearContents() -> Int {
        0
    }

    func declareTypes(_: [NSPasteboard.PasteboardType], owner _: Any?) -> Int {
        0
    }

    func setString(_: String, forType _: NSPasteboard.PasteboardType) -> Bool {
        false
    }
}
