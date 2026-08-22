@testable import BackglanceCore
import Foundation
import os
import XCTest

/// 🔒 Privacy Invariant #1, tested where it actually breaks.
///
/// The interesting failure is not someone deliberately logging a body — that is a compile
/// error. It is `"\(notification)"` in a hurry, which without a `description` makes Swift
/// reflect the struct and print every stored property, title and body included. These tests
/// assert that every way of turning a notification into a string produces no content.
final class LogLeakTests: XCTestCase {
    // MARK: Internal

    /// Every string conversion Swift offers for a value, on the type that holds the most
    /// content in the app.
    func testNoStringConversionOfANotificationRevealsItsContent() {
        let notification = Self.notification()

        let renderings = [
            "\(notification)",
            String(describing: notification),
            String(reflecting: notification),
            notification.description,
            notification.debugDescription,
            notification.logDescription,
        ]

        for rendering in renderings {
            for secret in Self.secrets {
                XCTAssertFalse(rendering.contains(secret), "\"\(secret)\" leaked into: \(rendering)")
            }
        }
    }

    /// What it does say is what a bug report needs: something to correlate with, which app,
    /// and how long each field was.
    func testWhatItSaysInsteadIsUsefulAndContentFree() {
        let notification = Self.notification()

        let rendering = notification.logDescription

        XCTAssertTrue(rendering.contains("app=7"), rendering)
        XCTAssertTrue(rendering.contains("b=\(Self.body.count)"), "the length, not the body: \(rendering)")
        XCTAssertTrue(rendering.hasPrefix(String(notification.uuid.prefix(8))), rendering)
    }

    /// An interpolated *collection* of notifications reflects its elements, so a batch is the
    /// same accident at scale — one `logger.debug("\(batch)")` and the whole tick is on disk.
    func testACollectionOfNotificationsAlsoRevealsNothing() {
        let batch = [Self.notification(), Self.notification()]

        let rendering = "\(batch)"

        for secret in Self.secrets {
            XCTAssertFalse(rendering.contains(secret), "\"\(secret)\" leaked from a batch")
        }
    }

    /// The reference is the intended path, and it has nowhere to put text by construction.
    func testTheReferenceCarriesNothingButCountsAndIdentifiers() {
        let notification = Self.notification()

        let reference = NotificationLogRef(notification, bundleID: "com.example.bank")

        for secret in Self.secrets {
            XCTAssertFalse("\(reference)".contains(secret))
        }
        XCTAssertEqual(reference.length, Self.title.count + Self.subtitle.count + Self.body.count)
    }

    /// A logger with a sink of its own, so what would have been written is inspectable rather
    /// than only visible in Console.
    func testNothingContentBearingReachesASink() {
        let sink = RecordingSink()
        let logger = RedactingLogger(category: "tests", sink: sink)
        let notification = Self.notification()

        logger.notice("archived", NotificationLogRef(notification, bundleID: "com.example.bank"))
        logger.error("insert failed", NotificationLogRef(notification, bundleID: "com.example.bank"), code: 19)

        let written = sink.messages.joined(separator: "\n")
        XCTAssertEqual(sink.messages.count, 2)
        for secret in Self.secrets {
            XCTAssertFalse(written.contains(secret), "\"\(secret)\" reached the sink")
        }
        XCTAssertTrue(written.contains("code=19"), "an error code is not content: \(written)")
    }

    // MARK: Private

    private final class RecordingSink: LogSink, @unchecked Sendable {
        // MARK: Internal

        var messages: [String] {
            lock.withLock { stored }
        }

        func write(level _: OSLogType, category _: String, message: String) {
            lock.withLock { stored.append(message) }
        }

        // MARK: Private

        private let lock = NSLock()
        private var stored: [String] = []
    }

    private static let title = "Aurora Bank"
    private static let subtitle = "Security"
    private static let body = "Your verification code is 314159"
    private static let sender = "+90 555 000 11 22"

    /// Every distinct piece of content the type can hold. If a rendering contains any of
    /// them, the invariant is broken.
    private static let secrets = [title, subtitle, body, sender, "314159"]

    private static func notification() -> ArchivedNotification {
        ArchivedNotification(
            uuid: UUID().uuidString,
            appId: 7,
            title: title,
            subtitle: subtitle,
            body: body,
            sender: sender,
            deliveredAt: UnixDate(Date()),
            capturedAt: UnixDate(Date())
        )
    }
}
