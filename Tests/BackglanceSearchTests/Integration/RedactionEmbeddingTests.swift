import BackglanceCore
@testable import BackglanceSearch
import BackglanceTestSupport
import Foundation
import XCTest

// MARK: - RedactionEmbeddingTests

/// 🔒 Privacy Invariant #2 for the one store that is not a copy of the text: the
/// embeddings.
///
/// `RedactionInvariantTests` follows a code through capture into the archive file and
/// proves the digits are not in it. It cannot cover this leg, because semantic indexing is
/// opt-in and never runs during capture — so the vectors it would have to scan for do not
/// exist yet at that point. This is the other half: take a row that has already been
/// through `OTPRedactor`, index it, and then look at the file again.
///
/// A vector is not text, which is exactly why it is worth checking. `SemanticIndex` builds
/// the string it embeds from the *archived* fields, and the assertion here is that nothing
/// on the way — the queue, the batch, the `embeddings` row — kept the original string
/// beside the vector it produced.
///
/// The code is generated from a seeded `SplitMix64` at run time, never written into this
/// file (docs/testing/TESTING.md#redaction-rule-tests).
final class RedactionEmbeddingTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = try Self.temporaryDirectory()
        self.directory = directory
        // File-backed rather than in-memory, because the assertion is about bytes on disk
        // and an in-memory database has none.
        let url = directory.appendingPathComponent("archive.sqlite")
        archiveURL = url
        archive = try Archive(path: url.path)
    }

    override func tearDownWithError() throws {
        archive = nil
        archiveURL = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Indexing a redacted notification

    /// 🔒 Index everything, then scan the archive file: the digits are in none of it.
    ///
    /// The scan covers the database, the FTS index and the write-ahead log as well as the
    /// `embeddings` table, because they share one file — which is the point. A test that
    /// only queried `embeddings` would miss a copy left in a table nobody thought to look
    /// at.
    func testIndexingARedactedNotificationLeavesNoCodeInTheArchiveFile() async throws {
        let archive = try XCTUnwrap(archive)
        let code = Self.syntheticCode()
        let redacted = try seedRedactedNotification(code: code)
        // The redactor has to have fired, or this test proves nothing about it.
        XCTAssertFalse(redacted.contains(code), "the redactor did not remove the code")

        let index = SemanticIndex(archive: archive)
        let available = await index.isAvailable
        await EmbeddingIndexer(archive: archive, index: index, batchSize: 2).runToCompletion()
        try XCTSkipUnless(available, "no on-device sentence model on this runner")

        XCTAssertFalse(try archive.embeddings().isEmpty, "nothing was indexed, so nothing was checked")
        for url in try Self.archiveFiles(at: XCTUnwrap(archiveURL)) {
            let bytes = try Data(contentsOf: url)
            XCTAssertNil(
                bytes.firstRange(of: Data(code.utf8)),
                "a code survived in \(url.lastPathComponent)"
            )
        }
    }

    /// The string that gets embedded is assembled from the archived fields, so a redacted
    /// row can only ever offer the placeholder. Stated as a test because it is the reason
    /// the indexer needs no redaction logic of its own — and the reason it would quietly
    /// stop being true if anyone rebuilt `embeddableText` from the parsed notification.
    func testTheTextOfferedForEmbeddingIsTheRedactedText() throws {
        let archive = try XCTUnwrap(archive)
        let code = Self.syntheticCode()
        _ = try seedRedactedNotification(code: code)

        let pending = try archive.notificationsMissingEmbeddings(limit: 10)

        XCTAssertFalse(pending.isEmpty)
        for row in pending {
            let text = SemanticIndex.embeddableText(title: row.title, subtitle: row.subtitle, body: row.body)
            XCTAssertFalse(text.contains(code), "the embeddable text carries a code")
            XCTAssertTrue(text.contains("[code redacted]"), "the placeholder should be what is embedded")
        }
    }

    // MARK: Private

    private var archive: Archive?
    private var archiveURL: URL?
    private var directory: URL?

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RedactionEmbeddingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Six digits from the seeded generator. Never a literal, so this file can be read by
    /// anyone without them having read a code.
    private static func syntheticCode() -> String {
        var rng = SplitMix64(seed: 20_260_822)
        let digits = String(rng.next() % 1_000_000)
        return String(repeating: "0", count: 6 - digits.count) + digits
    }

    private static func archiveFiles(at url: URL) throws -> [URL] {
        [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Inserts one notification whose body has been through the real redactor.
    ///
    /// - Returns: the body as archived.
    private func seedRedactedNotification(code: String) throws -> String {
        let archive = try XCTUnwrap(archive)
        let result = OTPRedactor.default.redact(OTPRedactor.Content(
            title: "Bank",
            body: "Your verification code is \(code)"
        ))
        XCTAssertNotNil(result.event, "the redactor should have fired on a keyword and a code")

        let app = try archive.upsertApp(bundleID: "com.apple.MobileSMS", now: Date())
        var row = try ArchivedNotification(
            uuid: UUID().uuidString,
            appId: XCTUnwrap(app.id),
            title: result.content.title,
            body: result.content.body,
            deliveredAt: UnixDate(Date()),
            capturedAt: UnixDate(Date())
        )
        row.redaction = .otp
        try archive.insertOrUpdate(row, redaction: result.event)
        return try XCTUnwrap(result.content.body)
    }
}
