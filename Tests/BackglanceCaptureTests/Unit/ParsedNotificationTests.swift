@testable import BackglanceCapture
import Foundation
import XCTest

/// The value type that first holds a notification as text. Two things are worth pinning:
/// that it cannot print itself, and that "is there anything to show" answers the way the
/// parser needs it to.
final class ParsedNotificationTests: XCTestCase {
    // MARK: Internal

    // MARK: - Content-free rendering

    /// 🔒 The whole point of the description overrides. A reflection dump would print the
    /// body straight into whatever log the interpolation landed in.
    func testItNeverPrintsItsOwnContent() {
        let parsed = Self.make(title: "Verification code", body: "Your code is 449021", sender: "Bank")

        for rendering in ["\(parsed)", String(describing: parsed), String(reflecting: parsed), parsed.logDescription] {
            XCTAssertFalse(rendering.contains("449021"), rendering)
            XCTAssertFalse(rendering.contains("Verification"), rendering)
            XCTAssertFalse(rendering.contains("Bank"), rendering)
        }
    }

    /// Lengths are what make a capture bug report actionable without the text.
    func testLogDescriptionCarriesIdentifiersAndLengths() {
        let parsed = Self.make(title: "abc", body: "de", attachments: [AttachmentMeta(type: "public.png", size: 512)])

        let logged = parsed.logDescription

        XCTAssertTrue(logged.contains("app=app.backglance.Fixture"), logged)
        XCTAssertTrue(logged.contains("t=3"), logged)
        XCTAssertTrue(logged.contains("b=2"), logged)
        XCTAssertTrue(logged.contains("atta=1"), logged)
    }

    func testAnAttachmentLogsItsTypeAndSizeOnly() {
        let attachment = AttachmentMeta(type: "public.jpeg", name: "passport-scan.jpg", size: 1_048_576)

        XCTAssertEqual(attachment.logDescription, "public.jpeg bytes=1048576")
    }

    // MARK: - Displayable content

    func testTextMakesARecordDisplayable() {
        XCTAssertTrue(Self.make(title: "Build failed").hasDisplayableContent)
        XCTAssertTrue(Self.make(subtitle: "3 tests").hasDisplayableContent)
        XCTAssertTrue(Self.make(body: "on main").hasDisplayableContent)
    }

    /// An image with no caption is still a notification worth keeping.
    func testAnAttachmentAloneMakesARecordDisplayable() {
        XCTAssertTrue(Self.make(attachments: [AttachmentMeta(type: "public.png")]).hasDisplayableContent)
    }

    /// The store's cleared placeholders. Archiving one puts a blank row in the timeline.
    func testARecordWithNoTextAndNoAttachmentsIsNotDisplayable() {
        XCTAssertFalse(Self.make().hasDisplayableContent)
        XCTAssertFalse(Self.make(title: "", body: "").hasDisplayableContent)
    }

    // MARK: - Defaults

    func testTheEnrichmentFieldsStartEmpty() {
        let parsed = Self.make(title: "Build failed")

        XCTAssertNil(parsed.deepLink)
        XCTAssertTrue(parsed.userInfo.isEmpty)
        XCTAssertTrue(parsed.attachments.isEmpty)
    }

    // MARK: Private

    private static func make(
        title: String? = nil,
        subtitle: String? = nil,
        body: String? = nil,
        sender: String? = nil,
        attachments: [AttachmentMeta] = []
    ) -> ParsedNotification {
        ParsedNotification(
            bundleID: "app.backglance.Fixture",
            uuid: UUID(),
            title: title,
            subtitle: subtitle,
            body: body,
            sender: sender,
            deliveredAt: Date(timeIntervalSinceReferenceDate: 774_000_000),
            presented: true,
            attachments: attachments
        )
    }
}
