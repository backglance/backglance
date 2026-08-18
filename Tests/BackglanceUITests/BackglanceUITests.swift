@testable import BackglanceUI
import XCTest

/// Placeholder so the `BackglanceUITests` bundle exists and CI has something to run.
/// Replaced by the real suites as `BackglanceUI` grows.
final class BackglanceUIModuleTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertFalse(String(describing: BackglanceUI.self).isEmpty)
    }
}
