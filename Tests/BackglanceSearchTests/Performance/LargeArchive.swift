import BackglanceCore
import BackglanceTestSupport
import Foundation
import GRDB

/// Builds — and then reuses — the hundred-thousand-notification archive the
/// latency tests measure against.
///
/// Generated rather than checked in. A 100k-row archive with its FTS index is
/// tens of megabytes, it would have to be regenerated on every schema change,
/// and a binary that large in git is a permanent tax on every clone. The seed
/// is fixed, so the file this produces is the same everywhere; it lives in the
/// system temporary directory and is rebuilt only when it is missing.
///
/// Everything in it is synthetic: numbered fixture text drawn from a seeded
/// ``SplitMix64``, and Apple's own published bundle identifiers. See
/// docs/testing/TESTING.md and
/// docs/deployment/PERFORMANCE_GUIDE.md#search-latency.
enum LargeArchive {
    // MARK: Internal

    static let notificationCount = 100_000

    /// Words the queries search for, with deliberate frequencies.
    ///
    /// `invoice` lands in one row in five hundred; `update` lands in roughly
    /// two in five — a little over forty thousand rows, which is the "very
    /// common term" case
    /// docs/deployment/PERFORMANCE_GUIDE.md#fts-p95-under-50-ms sets the budget
    /// by. A term in *every* row would be a harsher test than anything the
    /// budget was written for, and a fixture that is harsher than reality
    /// measures the fixture rather than the product.
    static let rareTerm = "invoice"
    static let commonTerm = "update"

    /// The archive, built on first use and reused afterwards.
    static func shared() throws -> Archive {
        if let cached {
            return cached
        }
        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try build(at: url)
        }
        let archive = try Archive(path: url.path)
        cached = archive
        return archive
    }

    // MARK: Private

    nonisolated(unsafe) private static var cached: Archive?

    /// Two of these five are the common term, which is what puts it in roughly
    /// forty thousand of the hundred thousand rows.
    private static let vocabulary = ["update", "update", "reminder", "deploy", "reply"]

    private static var fileURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("backglance-archive-100k-v2.sqlite")
    }

    private static func build(at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(path: url.path)
        var random = SplitMix64(seed: 0x5EED_0100)

        let apps = try Stubs.BundleID.all.map { bundleID in
            try archive.upsertApp(bundleID: bundleID, now: Stubs.epoch)
        }

        // One transaction for the lot: a hundred thousand commits would take
        // minutes and measure SQLite's fsync rather than anything we ship.
        try archive.pool.write { db in
            for index in 0 ..< notificationCount {
                let app = apps[index % apps.count]
                guard let appID = app.id else {
                    continue
                }
                var row = ArchivedNotification(
                    uuid: "PERF-\(String(format: "%08d", index))",
                    appId: appID,
                    title: title(index: index, random: &random),
                    body: "Fixture message body \(String(format: "%06d", random.next() % 1_000_000))",
                    sender: index.isMultiple(of: 7) ? "Fixture Sender \(index % 50)" : nil,
                    deliveredAt: UnixDate(Stubs.epoch.addingTimeInterval(-Double(index) * 30)),
                    capturedAt: UnixDate(Stubs.epoch)
                )
                try row.insert(db)
            }
        }
    }

    /// Titles drawn from a small vocabulary, so terms have realistic
    /// frequencies rather than all being either unique or universal.
    ///
    /// `update` appears in two rows in five, `invoice` in one in five hundred.
    private static func title(index: Int, random: inout SplitMix64) -> String {
        let number = String(format: "%06d", random.next() % 1_000_000)
        let word = Self.vocabulary[index % Self.vocabulary.count]
        let rare = index.isMultiple(of: 500) ? " \(rareTerm)" : ""
        return "Fixture \(word) \(number)\(rare)"
    }
}
