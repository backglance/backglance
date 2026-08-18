@testable import BackglanceSearch
import XCTest

/// Placeholder so the `BackglanceSearchTests` bundle exists and CI has something to run.
/// Replaced by the real suites as `BackglanceSearch` grows.
final class BackglanceSearchModuleTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertFalse(String(describing: BackglanceSearch.self).isEmpty)
    }
}
