@testable import BackglanceCapture
import XCTest

/// Placeholder so the `BackglanceCaptureTests` bundle exists and CI has something to run.
/// Replaced by the real suites as `BackglanceCapture` grows.
final class BackglanceCaptureModuleTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertFalse(String(describing: BackglanceCapture.self).isEmpty)
    }
}
