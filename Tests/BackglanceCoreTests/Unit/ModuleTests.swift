@testable import BackglanceCore
import BackglanceTestSupport
import XCTest

/// Placeholder so the `BackglanceCoreTests` bundle exists and CI has something to run.
/// Replaced by the real suites as `BackglanceCore` grows.
final class BackglanceCoreModuleTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertFalse(String(describing: BackglanceCore.self).isEmpty)
    }

    /// The shared support target is reachable and deterministic: same seed, same sequence.
    func testSharedTestSupportIsDeterministic() {
        var first = SplitMix64(seed: 0x5EED_0001)
        var second = SplitMix64(seed: 0x5EED_0001)
        XCTAssertEqual(first.next(), second.next())
    }
}
