@testable import BackglanceCapture
import BackglanceTestSupport
import Foundation
import XCTest

/// ⚠️ `RecordParser` decodes a binary plist Apple never promised us, written by whatever
/// app posted the notification. It must be impossible to crash with a store record —
/// corrupt, truncated, oversized, wrongly typed, or simply from a macOS nobody has seen.
/// A crash here takes the menu bar app down on every poll, since the same record is read
/// again on the next tick.
///
/// The contract these tests hold the parser to is narrow and absolute: **every failure is
/// a `CaptureError.parseFailed`, identified by `rec_id` and a fixed reason.** Any other
/// error type is a bug, and so is a crash, a hang, or an unbounded allocation.
///
/// Seeds are constants so a failure is reproducible: the assertion message carries the
/// seed and the iteration. Change a seed only to add a case, and say so in the commit.
final class RecordParserFuzzTests: XCTestCase {
    // MARK: Internal

    // MARK: - Valid input

    /// The property that makes the rest meaningful: a well-formed payload always parses,
    /// and parses to what it said.
    func testAWellFormedPayloadFromAnySeedParsesToItsOwnContent() throws {
        for seed in UInt64(1) ... 500 {
            var rng = SplitMix64(seed: seed)
            let payload = Self.wellFormedPayload(&rng)
            let data = try Self.plist(payload)

            let parsed = try RecordParser().parse(Self.record(data, recID: Int64(seed)))

            let request = try XCTUnwrap(payload["req"] as? [String: Any])
            XCTAssertEqual(parsed.title, request["titl"] as? String, "seed \(seed)")
            XCTAssertEqual(parsed.body, request["body"] as? String, "seed \(seed)")
            XCTAssertEqual(parsed.threadID, request["thre"] as? String, "seed \(seed)")
            XCTAssertEqual(parsed.bundleID, "com.example.demo", "seed \(seed)")
        }
    }

    // MARK: - Mutations

    func testFlippedBytesNeverProduceAnythingButAParseFailure() throws {
        var rng = SplitMix64(seed: 0x5EED_0001)
        let base = try Self.plist(Self.wellFormedPayload(&rng))

        for iteration in 0 ..< 3_000 {
            var bytes = [UInt8](base)
            for _ in 0 ... rng.int(below: 8) {
                let index = rng.int(below: bytes.count)
                // The low bit guarantees the byte actually changes.
                bytes[index] ^= UInt8(truncatingIfNeeded: rng.next() | 1)
            }

            Self.assertParsesOrFailsCleanly(Data(bytes), "flip iteration \(iteration)")
        }
    }

    /// A snapshot taken mid-write, or a row the store was still filling in.
    func testTruncationAtEveryLengthNeverProducesAnythingButAParseFailure() throws {
        var rng = SplitMix64(seed: 0x5EED_0002)
        let base = try Self.plist(Self.wellFormedPayload(&rng))

        for length in 0 ..< base.count {
            Self.assertParsesOrFailsCleanly(base.prefix(length), "truncated to \(length) bytes")
        }
    }

    func testAnEmptyPayloadIsRejectedAsNotAPropertyList() {
        XCTAssertThrowsError(try RecordParser().parse(Self.record(Data()))) { error in
            XCTAssertEqual(Self.reason(of: error), "not a property list")
        }
    }

    func testRandomGarbageNeverProducesAnythingButAParseFailure() {
        var rng = SplitMix64(seed: 0x5EED_0003)

        for iteration in 0 ..< 1_000 {
            let length = rng.int(below: 512)
            let bytes = (0 ..< length).map { _ in UInt8(truncatingIfNeeded: rng.next()) }

            Self.assertParsesOrFailsCleanly(Data(bytes), "garbage iteration \(iteration)")
        }
    }

    /// Well-formed plists whose *values* are the wrong shape — an app posting a number
    /// where a title belongs, or a string where the request dictionary belongs.
    func testWronglyTypedValuesAreToleratedOrRejectedButNeverFatal() throws {
        let payloads: [[String: Any]] = [
            ["app": 42, "date": "not a date", "req": ["titl": 1, "body": [1, 2, 3]]],
            ["app": "com.example.demo", "date": Self.delivered, "req": "a string, not a dictionary"],
            ["app": "com.example.demo", "date": Self.delivered, "req": ["titl": Data([0xFF, 0x00])]],
            ["app": ["nested": "dictionary"], "date": Self.delivered, "req": [:] as [String: Any]],
            ["req": ["body": [String: Any]()]],
            ["date": Self.delivered],
        ]

        for (index, payload) in payloads.enumerated() {
            try Self.assertParsesOrFailsCleanly(Self.plist(payload), "wrongly typed case \(index)")
        }
    }

    // MARK: - Resource exhaustion

    /// Nesting past the guard's limit is refused by the guard, with the depth it reached.
    func testNestingPastTheGuardsLimitIsRefusedByDepth() throws {
        var inner: Any = "leaf"
        for _ in 0 ..< 12 {
            inner = ["d": inner]
        }
        let data = try Self.plist(["app": "com.example.demo", "date": Self.delivered, "req": ["usda": inner]])

        XCTAssertThrowsError(try RecordParser().parse(Self.record(data))) { error in
            XCTAssertEqual(Self.reason(of: error), "payload too deep: 9")
        }
    }

    /// Absurd nesting never reaches the guard at all: `PropertyListSerialization` refuses
    /// to build the graph first. Worth pinning as the outer of two independent defences —
    /// neither one may be removed on the assumption that the other catches it.
    func testAbsurdNestingIsRefusedByTheDecoderBeforeTheGuardSeesIt() throws {
        var inner: Any = "leaf"
        for _ in 0 ..< 2_000 {
            inner = ["d": inner]
        }
        let data = try Self.plist(["app": "com.example.demo", "date": Self.delivered, "req": ["usda": inner]])

        XCTAssertThrowsError(try RecordParser().parse(Self.record(data))) { error in
            XCTAssertEqual(Self.reason(of: error), "not a property list")
        }
    }

    /// A ten-megabyte payload must be refused on size, before anything is decoded. The
    /// timing assertion is the point: decoding it first would stall the capture actor.
    func testATenMegabytePayloadIsRefusedBeforeDecoding() throws {
        let body = String(repeating: "x", count: 10 * 1_024 * 1_024)
        let data = try Self.plist(["app": "com.example.demo", "date": Self.delivered, "req": ["body": body]])
        XCTAssertGreaterThan(data.count, 10 * 1_024 * 1_024)

        let started = Date()
        XCTAssertThrowsError(try RecordParser().parse(Self.record(data))) { error in
            XCTAssertEqual(Self.reason(of: error), "payload too large: \(data.count) bytes")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05, "the size check must precede decoding")
    }

    // MARK: Private

    private static let delivered = Date(timeIntervalSinceReferenceDate: 774_000_000)

    /// ⚠️ Shaped like what has been observed in the store, with every value drawn from the
    /// seed. Nothing here is copied from a real notification.
    private static func wellFormedPayload(_ rng: inout SplitMix64) -> [String: Any] {
        let request: [String: Any] = [
            "titl": "Title \(rng.int(below: 1_000))",
            "subt": "Subtitle \(rng.int(below: 1_000))",
            "body": "Body text \(rng.int(below: 100_000)) lorem ipsum",
            "iden": rng.uuid().uuidString,
            "cate": "cat.\(rng.int(below: 10))",
            "thre": "thread-\(rng.int(below: 50))",
            "usda": ["k": "v", "url": "https://example.com/\(rng.int(below: 100))"] as [String: Any],
        ]
        return [
            "app": "com.example.demo",
            "date": Date(timeIntervalSinceReferenceDate: Double(700_000_000 + rng.int(below: 100_000_000))),
            "req": request,
        ]
    }

    /// Parsed, or refused the one way the parser is allowed to refuse. Anything else —
    /// another error type, a crash — is the failure this whole suite exists to catch.
    private static func assertParsesOrFailsCleanly(
        _ data: Data,
        _ context: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try RecordParser().parse(record(data))
        } catch let error as CaptureError {
            guard case .parseFailed = error else {
                return XCTFail("\(context()): wrong CaptureError case: \(error.logDescription)", file: file, line: line)
            }
        } catch {
            XCTFail("\(context()): unexpected error type \(type(of: error))", file: file, line: line)
        }
    }

    private static func reason(of error: Error) -> String? {
        guard case let .parseFailed(_, reason)? = error as? CaptureError else {
            return nil
        }
        return reason
    }

    private static func plist(_ payload: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
    }

    private static func record(_ plistData: Data, recID: Int64 = 1) -> RawStoreRecord {
        RawStoreRecord(
            recID: recID,
            appIdentifier: "com.example.demo",
            uuid: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
            plistData: plistData,
            deliveredDate: delivered,
            requestDate: nil,
            presented: true,
            style: nil
        )
    }
}
