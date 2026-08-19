@testable import BackglanceCapture
import Foundation
import XCTest

/// These are privacy tests as much as they are correctness tests. `CaptureError` and
/// `DegradedReason` are the two types capture is allowed to log, so what they render is
/// exactly what an `os_log` line at `privacy: .public` and the diagnostics export will
/// contain. Nothing here reads `~/Library`.
final class CaptureErrorTests: XCTestCase {
    // MARK: Internal

    // MARK: - Error to state mapping

    /// Every throwing path in capture has to land on a state the UI can render, or the
    /// engine has nothing to show for a failure but a spinner.
    func testEveryErrorMapsToTheDocumentedDegradedReason() {
        XCTAssertEqual(CaptureError.fullDiskAccessDenied.degradedReason, .noFullDiskAccess)
        XCTAssertEqual(CaptureError.storeNotFound(Self.storeURL).degradedReason, .storeNotFound)
        XCTAssertEqual(CaptureError.snapshotFailed(underlying: "ENOSPC").degradedReason, .readError("ENOSPC"))
        XCTAssertEqual(CaptureError.readFailed("disk I/O error").degradedReason, .readError("disk I/O error"))
        XCTAssertEqual(CaptureError.parseFailed(recID: 42, reason: "empty payload").degradedReason,
                       .readError("rec 42: empty payload"))
    }

    /// `.degraded` exists so a condition already expressed as a state can unwind a tick
    /// without being re-derived on the way out.
    func testDegradedPassesItsReasonThroughUnchanged() {
        let fingerprint = Self.fingerprint
        XCTAssertEqual(CaptureError.degraded(.unknownSchema(fingerprint)).degradedReason,
                       .unknownSchema(fingerprint))
    }

    // MARK: - Log safety

    /// The full store path runs through `~`, which is the user's account name. Logging
    /// it would put a personal identifier in every diagnostics export from a Mac where
    /// the store moved.
    func testStoreNotFoundLogsOnlyTheLastPathComponent() {
        let description = CaptureError.storeNotFound(Self.storeURL).logDescription

        XCTAssertEqual(description, "store not found at db")
        XCTAssertFalse(description.contains("Group Containers"))
        XCTAssertFalse(description.contains(Self.storeURL.path))
    }

    /// A fingerprint is content-free, but only its short form is *stable* — interpolating
    /// the struct itself would put Swift's reflection output in the log, which changes
    /// shape whenever the type gains a field.
    func testUnknownSchemaLogsTheFingerprintShortFormNotAStructDump() {
        let description = CaptureError.degraded(.unknownSchema(Self.fingerprint)).logDescription

        XCTAssertTrue(description.hasPrefix("degraded: unknown schema "))
        XCTAssertTrue(description.contains("7d1ca4f0"), "the 8-character hash prefix identifies the schema")
        XCTAssertTrue(description.contains("os=26.5"))
        XCTAssertFalse(description.contains("StoreFingerprint("), "no reflected struct dump")
        XCTAssertFalse(description.contains("schemaHash:"), "no reflected field labels")
    }

    /// A failed record is identified by its store row id and one of a fixed set of
    /// reasons. If a payload fragment ever reached this string it would be logged
    /// verbatim.
    func testParseFailureLogsTheRecordIDAndAFixedReason() {
        // Six digits, not five: swiftformat groups at 6+ and swiftlint demands a
        // separator at 5+, so a 5-digit literal cannot satisfy both (BACKGLANCE-84).
        XCTAssertEqual(CaptureError.parseFailed(recID: 148_211, reason: "not a property list").logDescription,
                       "parse failed rec 148211: not a property list")
    }

    func testTheRemainingCasesLogTheirDocumentedStrings() {
        XCTAssertEqual(CaptureError.fullDiskAccessDenied.logDescription, "full disk access denied")
        XCTAssertEqual(CaptureError.snapshotFailed(underlying: "ENOSPC").logDescription, "snapshot failed: ENOSPC")
        XCTAssertEqual(CaptureError.readFailed("disk I/O error").logDescription, "read failed: disk I/O error")
    }

    func testDegradedReasonLogDescriptionsAreStable() {
        XCTAssertEqual(DegradedReason.noFullDiskAccess.logDescription, "no full disk access")
        XCTAssertEqual(DegradedReason.storeNotFound.logDescription, "store not found")
        XCTAssertEqual(DegradedReason.readError("EPERM").logDescription, "read error: EPERM")
    }

    // MARK: - User-facing messages

    /// Settings ▸ Capture shows this and nothing else, so every reason needs a sentence —
    /// and it must not leak the detail that makes `logDescription` unsafe for the UI.
    func testEveryDegradedReasonHasASingleSentenceMessageWithNoDiagnosticDetail() {
        let reasons: [DegradedReason] = [
            .noFullDiskAccess,
            .storeNotFound,
            .unknownSchema(Self.fingerprint),
            .readError("disk I/O error"),
        ]

        for reason in reasons {
            let message = reason.userMessage
            XCTAssertFalse(message.isEmpty)
            XCTAssertTrue(message.hasSuffix("."), "\(reason.logDescription): one plain sentence")
            XCTAssertEqual(message.filter { $0 == "." }.count, 1, "\(reason.logDescription): one sentence, not two")
            XCTAssertFalse(message.contains("7d1ca4f0"), "no hashes in the UI")
            XCTAssertFalse(message.contains("disk I/O error"), "no errnos in the UI")
        }
    }

    // MARK: - Status equality

    /// The status drives the menu bar icon through an `AsyncStream` that only yields on
    /// change, so equality is what stops the icon redrawing on every tick.
    func testPausedStatusesCompareByResumeDate() {
        let resumeAt = Date(timeIntervalSince1970: 1_755_436_800)

        XCTAssertEqual(CaptureStatus.paused(until: resumeAt), .paused(until: resumeAt))
        XCTAssertEqual(CaptureStatus.paused(until: nil), .paused(until: nil))
        XCTAssertNotEqual(CaptureStatus.paused(until: resumeAt), .paused(until: nil))
        XCTAssertNotEqual(CaptureStatus.paused(until: nil), .running)
    }

    func testDegradedStatusesCompareByReason() {
        XCTAssertEqual(CaptureStatus.degraded(.noFullDiskAccess), .degraded(.noFullDiskAccess))
        XCTAssertNotEqual(CaptureStatus.degraded(.noFullDiskAccess), .degraded(.storeNotFound))
        XCTAssertNotEqual(CaptureStatus.degraded(.unknownSchema(Self.fingerprint)),
                          CaptureStatus.degraded(.unknownSchema(Self.otherFingerprint)))
        XCTAssertNotEqual(CaptureStatus.degraded(.readError("EPERM")), .degraded(.readError("ENOENT")))
    }

    // MARK: Private

    /// The path shape observed on macOS 11–26, built by hand — never resolved from the
    /// running Mac.
    private static let storeURL = URL(fileURLWithPath:
        "/Users/example/Library/Group Containers/group.com.apple.usernoted/db2/db")

    private static let fingerprint = StoreFingerprint(
        schemaHash: String(repeating: "7d1ca4f0", count: 8),
        dbinfoVersion: "17",
        osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0)
    )

    private static let otherFingerprint = StoreFingerprint(
        schemaHash: String(repeating: "0e2bd315", count: 8),
        dbinfoVersion: "12",
        osVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 1)
    )
}
