@testable import BackglanceCore
import XCTest

/// Placeholder so the `BackglanceCoreTests` bundle exists and CI has something to run.
/// Replaced by the real suites as `BackglanceCore` grows.
final class BackglanceCoreModuleTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertFalse(String(describing: BackglanceCore.self).isEmpty)
    }
}
