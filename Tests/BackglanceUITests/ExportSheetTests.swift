import BackglanceCore
@testable import BackglanceUI
import Foundation
import XCTest

// MARK: - ExportSheetTests

/// Covers ``ExportSheet``'s derivable strings — the singular/plural title and the default
/// filename — per docs/features/ACTIONS.md#select-and-export. ``ExportSheet`` itself has no
/// other logic worth a unit test: it neither touches `NSSavePanel` nor `ExportService`, only
/// reports a chosen ``ExportFormat`` through a callback, so there is nothing else here for a
/// host-less test to assert against.
final class ExportSheetTests: XCTestCase {
    // MARK: Internal

    // MARK: - title(count:)

    func testTitleIsSingularForOneNotification() {
        XCTAssertEqual(ExportSheet.title(count: 1), "Export 1 Notification")
    }

    func testTitleIsPluralForMultipleNotifications() {
        XCTAssertEqual(ExportSheet.title(count: 3), "Export 3 Notifications")
    }

    /// Zero is not a state the sheet is ever shown in (item 10's condition is "selection ≥ 1"),
    /// but the phrasing function itself should still make a reasonable choice rather than crash
    /// or read "Export 0 Notification".
    func testTitleIsPluralForZero() {
        XCTAssertEqual(ExportSheet.title(count: 0), "Export 0 Notifications")
    }

    // MARK: - defaultFilename(for:day:)

    func testDefaultFilenameForCSV() {
        XCTAssertEqual(ExportSheet.defaultFilename(for: .csv, day: Self.day), "Backglance-export-2026-08-17.csv")
    }

    func testDefaultFilenameForJSON() {
        XCTAssertEqual(ExportSheet.defaultFilename(for: .json, day: Self.day), "Backglance-export-2026-08-17.json")
    }

    // MARK: Private

    /// 2026-08-17, noon in the system's own default calendar/timezone — matching, not
    /// overriding, `ExportSheet`'s own formatter, which also reads the default timezone.
    /// Noon keeps a rounding error from ever crossing a day boundary, which is the failure
    /// mode a midnight timestamp would risk depending on the timezone of the machine
    /// running the suite.
    private static let day: Date = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "2026-08-17 12:00") ?? Date()
    }()
}
