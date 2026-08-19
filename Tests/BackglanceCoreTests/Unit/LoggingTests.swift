@testable import BackglanceCore
import Foundation
import os
import XCTest

// MARK: - LoggingTests

/// 🔒 Privacy Invariant #1 — notification content never reaches a log — is supposed to be
/// enforced by the shape of these types rather than by anyone remembering it. These tests
/// check the parts a compiler cannot: that a reference carries no text, and that what the
/// logger emits is what the caller assembled and nothing more.
final class LoggingTests: XCTestCase {
    // MARK: Internal

    // MARK: - What may be logged about a notification

    func testAReferenceCarriesAnIdentifierABundleIDAndALength() {
        let notification = ArchivedNotification(
            uuid: "6F1E2C1C-0D8A-4B7E-9C3F-5A2B1D4E6F8A",
            appId: 1,
            title: "Verification code",
            subtitle: "Bank",
            body: "Your code is 449021",
            deliveredAt: UnixDate(Self.delivered),
            capturedAt: UnixDate(Self.delivered)
        )

        let reference = NotificationLogRef(notification, bundleID: "com.example.bank")

        XCTAssertEqual(reference.bundleID, "com.example.bank")
        XCTAssertEqual(reference.length, 17 + 4 + 19)
        XCTAssertEqual(reference.description, "notif(id=6F1E2C1C app=com.example.bank len=40)")
    }

    /// The whole point: whatever a reference is rendered into, none of the notification
    /// comes with it.
    func testAReferenceNeverRendersContent() {
        let notification = ArchivedNotification(
            uuid: "6F1E2C1C-0D8A-4B7E-9C3F-5A2B1D4E6F8A",
            appId: 1,
            title: "Verification code",
            body: "Your code is 449021",
            deliveredAt: UnixDate(Self.delivered),
            capturedAt: UnixDate(Self.delivered)
        )

        let reference = NotificationLogRef(notification, bundleID: "com.example.bank")

        for rendering in ["\(reference)", String(describing: reference), String(reflecting: reference)] {
            XCTAssertFalse(rendering.contains("449021"), rendering)
            XCTAssertFalse(rendering.contains("Verification"), rendering)
        }
    }

    /// A row that has not been inserted has no id yet, and saying so beats inventing one.
    func testAReferenceToAnUnsavedNotificationSaysSo() {
        let reference = NotificationLogRef(id: "unsaved", bundleID: "com.example.chat", length: 0)

        XCTAssertEqual(reference.description, "notif(id=unsaved app=com.example.chat len=0)")
    }

    // MARK: - What the logger emits

    func testAMessageReachesTheSinkWithItsCategory() {
        let sink = RecordingSink()
        let logger = RedactingLogger(category: "capture", sink: sink)

        logger.notice("tick manual: 3/40 archived")

        XCTAssertEqual(sink.lines, [Line(category: "capture", message: "tick manual: 3/40 archived")])
    }

    func testAMessageAboutANotificationCarriesOnlyItsReference() {
        let sink = RecordingSink()
        let logger = RedactingLogger(category: "parser", sink: sink)
        let reference = NotificationLogRef(id: "6F1E2C1C", bundleID: "com.example.bank", length: 40)

        logger.error("archive failed", reference, code: 19)

        XCTAssertEqual(
            sink.lines.first?.message,
            "archive failed notif(id=6F1E2C1C app=com.example.bank len=40) code=19"
        )
    }

    /// A debug line runs on every capture tick, so the message must not be assembled when
    /// nobody is listening — which is what the autoclosure is for.
    func testADebugMessageIsNotAssembledUntilItIsNeeded() {
        let sink = RecordingSink()
        let logger = RedactingLogger(category: "capture", sink: sink)
        var assembled = 0

        for _ in 0 ..< 3 {
            logger.debug(Self.counting(&assembled))
        }

        XCTAssertEqual(assembled, sink.lines.count, "the message was built exactly as often as it was emitted")
    }

    // MARK: - The categories

    func testEveryDocumentedCategoryExists() {
        let categories = [
            Log.capture, Log.adapter, Log.parser, Log.archive,
            Log.search, Log.digest, Log.rules, Log.ui, Log.updater,
        ].map(\.category)

        XCTAssertEqual(
            categories,
            ["capture", "adapter", "parser", "archive", "search", "digest", "rules", "ui", "updater"]
        )
        XCTAssertEqual(Log.subsystem, "app.backglance.Backglance")
    }

    // MARK: Private

    private static let delivered = Date(timeIntervalSinceReferenceDate: 774_000_000)

    private static func counting(_ count: inout Int) -> String {
        count += 1
        return "assembled"
    }
}

// MARK: - Line

private struct Line: Equatable {
    var category: String
    var message: String
}

// MARK: - RecordingSink

/// Stands in for the file log, which arrives with the diagnostics export.
private final class RecordingSink: LogSink, @unchecked Sendable {
    // MARK: Internal

    private(set) var lines: [Line] = []

    func write(level _: OSLogType, category: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(Line(category: category, message: message))
    }

    // MARK: Private

    private let lock = NSLock()
}
