@testable import BackglanceUI
import XCTest

// MARK: - UndoToastViewTests

/// Covers only the copy in docs/features/ACTIONS.md#undo-toast ("Deleted 1
/// notification · Undo", pluralized for `n`). Everything else about the view —
/// layout, Reduce Motion, accessibility identifiers — has no pure function to assert
/// against without standing up a hosted SwiftUI hierarchy, which this package's
/// existing view tests (`AccessibilityTests`, `DayTitleTests`) don't do either; those
/// are left to the manual screenshot/VoiceOver pass this task's QA checklist calls
/// for once a host wires the view up.
final class UndoToastViewTests: XCTestCase {
    /// The singular now lives in the catalog's plural variations, which this host-less
    /// bundle cannot see — `Bundle.main` is the test runner, so lookups fall back to
    /// the key. What *is* assertable here is that the count survives into the message;
    /// "Deleted 1 notification" rendering as a singular is `PluralRenderingTests`'
    /// assertion, against the running app.
    func testMessageCarriesTheExactCount() {
        XCTAssertTrue(UndoToastView.message(count: 1).contains("1"))
        XCTAssertTrue(UndoToastView.message(count: 3).contains("3"))
    }

    /// Not a case the toast should ever actually render (the handler skips the toast
    /// entirely when nothing was flipped), but the format string itself should still
    /// resolve to something sane rather than a String Catalog crash if it ever did.
    func testZeroCountDoesNotCrash() {
        XCTAssertTrue(UndoToastView.message(count: 0).contains("0"))
    }
}
