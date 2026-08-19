@testable import BackglanceCapture
import Foundation
import XCTest

/// ⚠️ The payloads these tests build are what a hostile app can put in the system store:
/// an enormous blob, a deeply nested array, a dictionary with more keys than any
/// notification has. Backglance has to refuse each of them without stalling, allocating
/// without bound, or recursing off the stack — and has to say so in a way that carries no
/// payload.
final class PlistGuardTests: XCTestCase {
    // MARK: Internal

    // MARK: - Ordinary payloads

    func testAnOrdinaryPayloadDecodes() throws {
        let data = try Self.plist(["req": ["titl": "Ada", "body": "Landing at six"]])

        let decoded = try PlistGuard().decode(data)

        XCTAssertEqual((decoded["req"] as? [String: Any])?["titl"] as? String, "Ada")
    }

    // MARK: - Limits

    /// Checked before decoding: the point is not to build the object graph at all.
    func testAPayloadOverTheSizeCapIsRefusedWithoutDecoding() {
        let oversized = Data(repeating: 0x62, count: 65 * 1_024)

        XCTAssertThrowsError(try PlistGuard().decode(oversized)) { error in
            XCTAssertEqual(error as? PlistGuardError, .tooLarge(bytes: 66_560))
        }
    }

    func testDeepNestingIsRefused() throws {
        var nested: Any = "leaf"
        for _ in 0 ..< 40 {
            nested = [nested]
        }
        let data = try Self.plist(["req": nested])

        XCTAssertThrowsError(try PlistGuard().decode(data)) { error in
            guard case .tooDeep? = error as? PlistGuardError else {
                return XCTFail("expected .tooDeep, got \(String(describing: error))")
            }
        }
    }

    func testAnOversizedCollectionIsRefused() throws {
        let wide = (0 ..< 600).reduce(into: [String: Any]()) { $0["k\($1)"] = "v" }
        let data = try Self.plist(["usda": wide])

        XCTAssertThrowsError(try PlistGuard().decode(data)) { error in
            XCTAssertEqual(error as? PlistGuardError, .collectionTooLarge(count: 600))
        }
    }

    func testAnOversizedStringIsRefused() throws {
        let data = try Self.plist(["body": String(repeating: "a", count: 20_000)])

        XCTAssertThrowsError(try PlistGuard().decode(data)) { error in
            XCTAssertEqual(error as? PlistGuardError, .stringTooLong(length: 20_000))
        }
    }

    /// Keys are strings too, and a payload can be hostile in its keys alone.
    func testAnOversizedKeyIsRefused() throws {
        let data = try Self.plist([String(repeating: "k", count: 20_000): "v"])

        XCTAssertThrowsError(try PlistGuard().decode(data)) { error in
            XCTAssertEqual(error as? PlistGuardError, .stringTooLong(length: 20_000))
        }
    }

    func testTheLimitsAreConfigurable() throws {
        let data = try Self.plist(["req": ["titl": "Ada"]])
        let strict = PlistGuard(limits: PlistGuardLimits(maxDepth: 1))

        XCTAssertThrowsError(try strict.decode(data)) { error in
            XCTAssertEqual(error as? PlistGuardError, .tooDeep(depth: 2))
        }
    }

    // MARK: - Types

    /// A property list cannot contain one, but the rule exists for the day something else
    /// hands us an object graph.
    func testAnUnsupportedTypeIsRefused() {
        XCTAssertThrowsError(try PlistGuard().validate(NSObject(), depth: 1)) { error in
            XCTAssertEqual(error as? PlistGuardError, .unsupportedType("NSObject"))
        }
    }

    /// 🔒 An NSKeyedArchiver payload inside `userInfo` stays opaque bytes. Backglance never
    /// unarchives it — instantiating classes named by untrusted data is how this goes
    /// wrong — and `RecordParser` drops non-string values when it flattens `userInfo`.
    func testAnArchivedObjectStaysOpaqueData() throws {
        let archived = try NSKeyedArchiver.archivedData(withRootObject: ["a": "b"], requiringSecureCoding: true)
        let data = try Self.plist(["req": ["titl": "Ada", "usda": ["payload": archived]]])

        let decoded = try PlistGuard().decode(data)
        let request = try XCTUnwrap(decoded["req"] as? [String: Any])
        let userInfo = try XCTUnwrap(request["usda"] as? [String: Any])

        XCTAssertTrue(userInfo["payload"] is Data)
    }

    // MARK: - Reporting

    /// 🔒 Every rejection is reported as a shape — a count, a depth, a length — because
    /// these strings reach the file log and the diagnostics export.
    func testRejectionsAreReportedAsShapesNotContent() {
        let descriptions = [
            PlistGuardError.tooLarge(bytes: 2_097_152).logDescription,
            PlistGuardError.notAPropertyList.logDescription,
            PlistGuardError.notADictionary.logDescription,
            PlistGuardError.tooDeep(depth: 9).logDescription,
            PlistGuardError.collectionTooLarge(count: 100_000).logDescription,
            PlistGuardError.stringTooLong(length: 20_000).logDescription,
            PlistGuardError.unsupportedType("NSObject").logDescription,
        ]

        XCTAssertEqual(descriptions, [
            "payload too large: 2097152 bytes",
            "not a property list",
            "root is not a dictionary",
            "payload too deep: 9",
            "collection too large: 100000",
            "string too long: 20000",
            "unsupported type: NSObject",
        ])
    }

    // MARK: - Through the parser

    /// The guard runs first, and its reason becomes the parse failure's reason, still by
    /// `rec_id` only.
    func testTheParserRefusesAHostileRecordByShape() throws {
        let raw = RawStoreRecord(
            recID: 88,
            appIdentifier: "app.backglance.Fixture",
            uuid: UUID(),
            plistData: Data(repeating: 0x62, count: 65 * 1_024),
            deliveredDate: Date(timeIntervalSinceReferenceDate: 774_000_000),
            requestDate: nil,
            presented: true,
            style: 0
        )

        XCTAssertThrowsError(try RecordParser().parse(raw)) { error in
            XCTAssertEqual(
                (error as? CaptureError)?.logDescription,
                "parse failed rec 88: payload too large: 66560 bytes"
            )
        }
    }

    // MARK: Private

    private static func plist(_ payload: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
    }
}
