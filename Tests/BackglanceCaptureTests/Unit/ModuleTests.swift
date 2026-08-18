@testable import BackglanceCapture
import BackglanceTestSupport
import XCTest

/// Placeholder so the `BackglanceCaptureTests` bundle exists and CI has something to run.
/// Replaced by the real suites as `BackglanceCapture` grows.
final class BackglanceCaptureModuleTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertFalse(String(describing: BackglanceCapture.self).isEmpty)
    }

    /// The shared support target is reachable and deterministic: same seed, same sequence.
    func testSharedTestSupportIsDeterministic() {
        var first = SplitMix64(seed: 0x5EED_0001)
        var second = SplitMix64(seed: 0x5EED_0001)
        XCTAssertEqual(first.next(), second.next())
    }
}
