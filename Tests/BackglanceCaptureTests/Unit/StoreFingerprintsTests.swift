@testable import BackglanceCapture
import Foundation
import XCTest

/// This list is what stands between "we recognise this store" and "we are guessing", so
/// the tests are about trust: that the bundled resource is actually in the bundle, that
/// what it says reaches the adapters, and that a hash never appears from anywhere else.
final class StoreFingerprintsTests: XCTestCase {
    // MARK: Internal

    // MARK: - The bundled resource

    func testTheResourceIsInTheBundleAndDecodes() throws {
        let url = try XCTUnwrap(
            StoreFingerprints.resourceURL,
            "KnownFingerprints.json is missing from the BackglanceCapture bundle"
        )

        let decoded = try StoreFingerprints.decode(Data(contentsOf: url))

        XCTAssertEqual(Set(decoded.keys), ["v14", "v15", "v26"])
    }

    /// Every hash in the file has to be a 64-character SHA-256 in hex. A truncated or
    /// pasted-in value would never match anything, which would look like a macOS change
    /// rather than the typo it is.
    func testEveryBundledHashIsAWellFormedSHA256() {
        for adapter in StoreAdapterRegistry.adapters {
            for hash in StoreFingerprints.hashes(forAdapter: adapter.adapterID) {
                XCTAssertEqual(hash.count, 64, "\(adapter.adapterID): \(hash)")
                XCTAssertTrue(hash.allSatisfy(\.isHexDigit), "\(adapter.adapterID): \(hash)")
                XCTAssertEqual(hash, hash.lowercased(), "\(adapter.adapterID): \(hash)")
            }
        }
    }

    /// Two adapters claiming one hash would make resolution depend on registration order
    /// for a store both say they understand.
    func testNoHashIsClaimedByTwoAdapters() {
        var seen: [String: String] = [:]

        for adapter in StoreAdapterRegistry.adapters {
            for hash in StoreFingerprints.hashes(forAdapter: adapter.adapterID) {
                XCTAssertNil(seen[hash], "\(hash) claimed by both \(seen[hash] ?? "") and \(adapter.adapterID)")
                seen[hash] = adapter.adapterID
            }
        }
    }

    func testAnUnknownAdapterIDHasNoHashes() {
        XCTAssertTrue(StoreFingerprints.hashes(forAdapter: "v99").isEmpty)
    }

    // MARK: - Decoding

    func testDecodingReadsHashesPerAdapterID() throws {
        let json = Data("""
        {"version": 1, "adapters": {"v26": ["\(Self.hash("a"))", "\(Self.hash("b"))"], "v14": []}}
        """.utf8)

        let decoded = try StoreFingerprints.decode(json)

        XCTAssertEqual(decoded["v26"], [Self.hash("a"), Self.hash("b")])
        XCTAssertEqual(decoded["v14"], [])
    }

    /// A file whose shape we do not understand must not decode to "no known hashes"
    /// quietly at the parse level — the loader decides what to do about a failure, and it
    /// records one loudly in development.
    func testAFileOfTheWrongShapeThrows() {
        XCTAssertThrowsError(try StoreFingerprints.decode(Data(#"{"version": 1, "fingerprints": []}"#.utf8)))
    }

    // MARK: - What the adapters see

    func testAdaptersReadTheirOwnEntries() {
        XCTAssertEqual(StoreAdapterV14.knownSchemaHashes, StoreFingerprints.hashes(forAdapter: "v14"))
        XCTAssertEqual(StoreAdapterV15.knownSchemaHashes, StoreFingerprints.hashes(forAdapter: "v15"))
        XCTAssertEqual(StoreAdapterV26.knownSchemaHashes, StoreFingerprints.hashes(forAdapter: "v26"))
    }

    // MARK: Private

    private static func hash(_ character: String) -> String {
        String(repeating: character, count: 64)
    }
}
