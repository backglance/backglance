@testable import BackglanceCapture
import Foundation
import XCTest

/// The parser reads keys nobody documented, so the tests are written as a record of what
/// the store has actually been observed to contain — the short keys, the long-form
/// spellings, the rows that are not notifications at all — plus the rules that keep a bad
/// row from becoming a bad archive entry.
final class RecordParserTests: XCTestCase {
    // MARK: Internal

    // MARK: - Key mapping

    func testTheShortKeysInsideReqAreRead() throws {
        let request: [String: Any] = [
            "titl": "Ada",
            "subt": "Mobile",
            "body": "Landing at six",
            "thre": "chat-9",
            "cate": "MessageReceived",
        ]

        let raw = try Self.record(payload: ["app": "com.apple.MobileSMS", "req": request])

        let parsed = try RecordParser().parse(raw)

        XCTAssertEqual(parsed.bundleID, "com.apple.MobileSMS")
        XCTAssertEqual(parsed.title, "Ada")
        XCTAssertEqual(parsed.subtitle, "Mobile")
        XCTAssertEqual(parsed.body, "Landing at six")
        XCTAssertEqual(parsed.threadID, "chat-9")
        XCTAssertEqual(parsed.category, "MessageReceived")
    }

    /// A macOS that spells a key out should cost nothing.
    func testLongFormKeysAreAcceptedToo() throws {
        let request: [String: Any] = [
            "title": "Build failed",
            "subtitle": "main",
            "body": "3 tests",
            "threadIdentifier": "ci-42",
            "category": "BuildStatus",
        ]

        let raw = try Self.record(payload: ["req": request])

        let parsed = try RecordParser().parse(raw)

        XCTAssertEqual(parsed.title, "Build failed")
        XCTAssertEqual(parsed.subtitle, "main")
        XCTAssertEqual(parsed.threadID, "ci-42")
        XCTAssertEqual(parsed.category, "BuildStatus")
    }

    /// Some rows put the fields at the top level instead of under `req`.
    func testFieldsAtTheTopLevelAreReadWhenThereIsNoReqDictionary() throws {
        let raw = try Self.record(payload: ["titl": "Reminder", "body": "Standup in 5"])

        let parsed = try RecordParser().parse(raw)

        XCTAssertEqual(parsed.title, "Reminder")
        XCTAssertEqual(parsed.body, "Standup in 5")
    }

    /// Helper processes and iPhone Mirroring post on behalf of another bundle, and the
    /// payload is the one that knows which.
    func testThePayloadsBundleIDWinsOverTheJoinedAppRow() throws {
        let raw = try Self.record(payload: ["app": "com.apple.iphonemirroring", "req": ["titl": "Ada"]])

        XCTAssertEqual(try RecordParser().parse(raw).bundleID, "com.apple.iphonemirroring")
    }

    func testTheJoinedAppRowIsUsedWhenThePayloadDoesNotSay() throws {
        let raw = try Self.record(payload: ["req": ["titl": "Ada"]])

        XCTAssertEqual(try RecordParser().parse(raw).bundleID, "app.backglance.Fixture")
    }

    // MARK: - Dates

    func testTheRowsDeliveredDateIsPreferred() throws {
        let raw = try Self.record(
            payload: ["req": ["titl": "Ada"], "date": Self.delivered.addingTimeInterval(-900)],
            deliveredDate: Self.delivered
        )

        XCTAssertEqual(try RecordParser().parse(raw).deliveredAt, Self.delivered)
    }

    func testThePayloadDateIsUsedWhenTheRowHasNone() throws {
        let raw = try Self.record(payload: ["req": ["titl": "Ada"], "date": Self.delivered], deliveredDate: nil)

        XCTAssertEqual(try RecordParser().parse(raw).deliveredAt, Self.delivered)
    }

    /// The payload sometimes carries Cocoa reference seconds rather than a date object.
    func testAPayloadDateGivenAsANumberIsRead() throws {
        let raw = try Self.record(
            payload: ["req": ["titl": "Ada"], "date": Self.delivered.timeIntervalSinceReferenceDate],
            deliveredDate: nil
        )

        XCTAssertEqual(try RecordParser().parse(raw).deliveredAt, Self.delivered)
    }

    func testTheRequestDateIsTheLastResort() throws {
        let raw = try Self.record(
            payload: ["req": ["titl": "Ada"]],
            deliveredDate: nil,
            requestDate: Self.delivered
        )

        XCTAssertEqual(try RecordParser().parse(raw).deliveredAt, Self.delivered)
    }

    /// No timestamp is ever invented. A guessed one would file the notification under the
    /// wrong day permanently, and an archive whose order is not real is not worth having.
    func testARecordWithNoDateAnywhereIsRejected() throws {
        let raw = try Self.record(payload: ["req": ["titl": "Ada"]], deliveredDate: nil)

        XCTAssertThrowsError(try RecordParser().parse(raw)) { error in
            XCTAssertEqual(Self.reason(of: error), "no delivered date")
        }
    }

    // MARK: - Rejections

    func testDataThatIsNotAPropertyListIsRejected() throws {
        let raw = Self.record(plistData: Data("this is not a plist".utf8))

        XCTAssertThrowsError(try RecordParser().parse(raw)) { error in
            XCTAssertEqual(Self.reason(of: error), "not a property list")
        }
    }

    func testAPropertyListThatIsNotADictionaryIsRejected() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["a", "b"], format: .binary, options: 0)
        let raw = Self.record(plistData: data)

        XCTAssertThrowsError(try RecordParser().parse(raw)) { error in
            XCTAssertEqual(Self.reason(of: error), "root is not a dictionary")
        }
    }

    /// Cleared placeholders and bookkeeping rows. Nothing a person could read.
    func testAPayloadWithNoTextAndNoAttachmentsIsRejected() throws {
        let raw = try Self.record(payload: ["req": ["cate": "Bookkeeping"]])

        XCTAssertThrowsError(try RecordParser().parse(raw)) { error in
            XCTAssertEqual(Self.reason(of: error), "empty payload")
        }
    }

    func testAnEmptyStringIsTreatedAsAbsent() throws {
        let raw = try Self.record(payload: ["req": ["titl": "", "body": ""]])

        XCTAssertThrowsError(try RecordParser().parse(raw)) { error in
            XCTAssertEqual(Self.reason(of: error), "empty payload")
        }
    }

    /// 🔒 A rejection reason is one of a fixed set. Nothing from the payload may reach an
    /// error, a log line, or the diagnostics export.
    func testARejectionCarriesTheRecordIDAndNothingFromThePayload() throws {
        let raw = try Self.record(payload: ["req": ["cate": "Bookkeeping"]], recID: 471)

        XCTAssertThrowsError(try RecordParser().parse(raw)) { error in
            guard let captureError = error as? CaptureError else {
                return XCTFail("expected a CaptureError")
            }
            XCTAssertEqual(captureError.logDescription, "parse failed rec 471: empty payload")
            XCTAssertFalse(captureError.logDescription.contains("Bookkeeping"))
        }
    }

    // MARK: - Attachments

    func testAttachmentMetadataIsReadAndTheBytesAreNot() throws {
        let attachments: [[String: Any]] = [
            ["type": "public.jpeg", "name": "sunset.jpg", "size": 3_145_728],
            ["UTI": "public.png", "identifier": "chart.png"],
            [:],
        ]

        let raw = try Self.record(payload: ["req": ["titl": "Photo", "atta": attachments]])

        let parsed = try RecordParser().parse(raw)

        XCTAssertEqual(parsed.attachments.count, 3)
        XCTAssertEqual(parsed.attachments[0], AttachmentMeta(type: "public.jpeg", name: "sunset.jpg", size: 3_145_728))
        XCTAssertEqual(parsed.attachments[1], AttachmentMeta(type: "public.png", name: "chart.png"))
        XCTAssertEqual(parsed.attachments[2], AttachmentMeta(type: "unknown"))
    }

    /// An image with no caption is still worth archiving.
    func testAnAttachmentAloneIsEnoughToArchive() throws {
        let raw = try Self.record(payload: ["req": ["atta": [["type": "public.png"]]]])

        XCTAssertEqual(try RecordParser().parse(raw).attachments.count, 1)
    }

    // MARK: - userInfo

    func testUserInfoIsFlattenedToStringsAndBlobsAreDropped() throws {
        let userInfo: [String: Any] = [
            "conversation": "chat-9",
            "unread": 3,
            "link": "messages://open?id=9",
            "nested": ["a": "b"],
            "blob": Data([0x00, 0x01]),
        ]

        let raw = try Self.record(payload: ["req": ["titl": "Ada", "usda": userInfo]])

        let parsed = try RecordParser().parse(raw)

        XCTAssertEqual(parsed.userInfo["conversation"], "chat-9")
        XCTAssertEqual(parsed.userInfo["unread"], "3")
        XCTAssertEqual(parsed.userInfo["link"], "messages://open?id=9")
        XCTAssertNil(parsed.userInfo["nested"])
        XCTAssertNil(parsed.userInfo["blob"])
    }

    /// The resolver fills this in later; the parser must not invent one.
    func testTheDeepLinkIsLeftToEnrichment() throws {
        let raw = try Self.record(payload: ["req": ["titl": "Ada", "usda": ["link": "messages://open?id=9"]]])

        XCTAssertNil(try RecordParser().parse(raw).deepLink)
    }

    // MARK: - Sender

    func testAnAppThatDeclaresASenderIsTakenAtItsWord() throws {
        let raw = try Self.record(payload: ["req": ["titl": "#general", "usda": ["sender": "Ada Lovelace"]]])

        XCTAssertEqual(try RecordParser().parse(raw).sender, "Ada Lovelace")
    }

    /// Messages and Mail put the correspondent in the title.
    func testMessagesAndMailFallBackToTheTitle() throws {
        for bundleID in ["com.apple.MobileSMS", "com.apple.mail"] {
            let raw = try Self.record(payload: ["app": bundleID, "req": ["titl": "Ada", "body": "Landing at six"]])

            XCTAssertEqual(try RecordParser().parse(raw).sender, "Ada", bundleID)
        }
    }

    /// A wrong sender is worse than none, so no other bundle is guessed at.
    func testNoOtherAppGetsASenderGuessedFromItsTitle() throws {
        let raw = try Self.record(payload: ["app": "com.example.ci", "req": ["titl": "Build failed"]])

        XCTAssertNil(try RecordParser().parse(raw).sender)
    }

    // MARK: Private

    private static let delivered = Date(timeIntervalSinceReferenceDate: 774_000_000)

    private static func reason(of error: Error) -> String? {
        guard case let .parseFailed(_, reason)? = error as? CaptureError else {
            return nil
        }
        return reason
    }

    private static func record(
        payload: [String: Any],
        recID: Int64 = 1,
        deliveredDate: Date? = RecordParserTests.delivered,
        requestDate: Date? = nil
    ) throws -> RawStoreRecord {
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
        return record(plistData: data, recID: recID, deliveredDate: deliveredDate, requestDate: requestDate)
    }

    private static func record(
        plistData: Data,
        recID: Int64 = 1,
        deliveredDate: Date? = RecordParserTests.delivered,
        requestDate: Date? = nil
    ) -> RawStoreRecord {
        RawStoreRecord(
            recID: recID,
            appIdentifier: "app.backglance.Fixture",
            uuid: UUID(),
            plistData: plistData,
            deliveredDate: deliveredDate,
            requestDate: requestDate,
            presented: true,
            style: 0
        )
    }
}
