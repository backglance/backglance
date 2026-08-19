import BackglanceCapture
import Foundation
import GRDB

// FixtureGenerator fills a synthetic system-store fixture: it inserts app and record rows
// into a database `Scripts/make_fixture.sh` has already created from a captured schema,
// then writes `expected.json` and `manifest.json` beside it.
//
// 🔒 It never reads `~/Library`. Every value it writes comes from a seeded generator, so a
// fixture is reproducible from its manifest and contains no personal data — no real
// address, phone number or one-time code. See docs/testing/TESTING.md#why-fixtures-are-synthetic.
//
// An executable rather than a shell script because hand-building a binary plist in bash is
// not something anyone should maintain.

let generatorVersion = "1.0.0"

// MARK: - Arguments

struct Arguments {
    /// `--print-fingerprint --db <path>`: report a database's schema hash and stop.
    ///
    /// Exists so `Scripts/verify_fixture.sh` can check a fixture's manifest without
    /// reimplementing ``StoreFingerprinter``'s normalization in bash. One space apart
    /// would be a different hash, and a different hash reads as "macOS changed the
    /// store" — so there is exactly one implementation, and the script calls it.
    var printFingerprintOnly = false

    var osMajor: Int
    var databaseURL: URL
    var expectedURL: URL
    var manifestURL: URL
    var sourceManifestURL: URL?
    var seed: UInt64?
    var records: Int?
    var build: String

    /// The `dbinfo` version value the fixture should carry.
    ///
    /// Apple's store keeps a version-like value in its own `dbinfo` table, and
    /// ``StoreFingerprint`` reads it — so a fixture without one leaves that part of the
    /// fingerprint untested. Synthetic like everything else here; the manifest records
    /// what was written so the harness can check it came back.
    var dbinfoVersion: String?

    /// Overrides the manifest's `notes`. The default claims the schema was captured with
    /// `sqlite3 .schema` on that macOS, which is only true when it was — a fixture built
    /// from a reconstructed schema has to say so.
    var notes: String?

    /// The `--print-fingerprint` form, which needs a database and nothing else.
    static func fingerprintOnly(databaseURL: URL) -> Arguments {
        Arguments(
            printFingerprintOnly: true,
            osMajor: 0,
            databaseURL: databaseURL,
            expectedURL: URL(fileURLWithPath: "/dev/null"),
            manifestURL: URL(fileURLWithPath: "/dev/null"),
            sourceManifestURL: nil,
            seed: nil,
            records: nil,
            build: "unknown",
            dbinfoVersion: nil,
            notes: nil
        )
    }

    static func parse(_ arguments: [String]) throws -> Arguments {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--") else {
                throw GeneratorError.usage("unexpected argument: \(key)")
            }
            let name = String(key.dropFirst(2))

            // The only boolean flag; everything else takes a value.
            if name == "print-fingerprint" {
                flags.insert(name)
                index += 1
                continue
            }
            guard index + 1 < arguments.count else {
                throw GeneratorError.usage("--\(name) needs a value")
            }
            values[name] = arguments[index + 1]
            index += 2
        }

        func required(_ name: String) throws -> String {
            guard let value = values[name] else {
                throw GeneratorError.usage("missing --\(name)")
            }
            return value
        }

        if flags.contains("print-fingerprint") {
            return try fingerprintOnly(databaseURL: URL(fileURLWithPath: required("db")))
        }

        return try Arguments(
            osMajor: Int(required("os")) ?? { throw GeneratorError.usage("--os must be a number") }(),
            databaseURL: URL(fileURLWithPath: required("db")),
            expectedURL: URL(fileURLWithPath: required("expected")),
            manifestURL: URL(fileURLWithPath: required("manifest")),
            sourceManifestURL: values["source-manifest"].map { URL(fileURLWithPath: $0) },
            seed: values["seed"].flatMap { UInt64($0) },
            records: values["records"].flatMap { Int($0) },
            build: values["build"] ?? "unknown",
            dbinfoVersion: values["dbinfo-version"],
            notes: values["notes"]
        )
    }
}

// MARK: - GeneratorError

enum GeneratorError: Error, CustomStringConvertible {
    case usage(String)
    case noAdapter(Int)

    // MARK: Internal

    var description: String {
        switch self {
        case let .usage(detail):
            """
            \(detail)

            usage: FixtureGenerator --os <major> --db <store.db> --expected <expected.json> \
            --manifest <manifest.json> [--source-manifest <manifest.json>] [--seed <int>] \
            [--records <n>] [--build <build>] [--dbinfo-version <value>] [--notes <text>]
                   FixtureGenerator --print-fingerprint --db <store.db>
            """

        case let .noAdapter(major):
            "no adapter claims macOS \(major); add one before generating its fixture"
        }
    }
}

// MARK: - Generation

/// Inserts the app rows, then the records, in one transaction.
///
/// The `app` table is filled from the bundle ids the content generator actually used, so
/// the fixture has no rows nothing points at — the join the adapter runs would not notice,
/// but a person reading the fixture would wonder.
func writeStore(
    _ notifications: [GeneratedNotification],
    dbinfoVersion: String,
    to url: URL
) throws {
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
        // The store keeps its own version marker, and the fingerprint reads it. A fixture
        // without one would leave that part of the fingerprint untested.
        try db.execute(
            sql: "INSERT OR REPLACE INTO dbinfo (key, value) VALUES ('compatibleVersion', ?)",
            arguments: [dbinfoVersion]
        )

        var appIDs: [String: Int64] = [:]
        for bundleID in notifications.map(\.bundleID).uniqued() {
            let appID = Int64(appIDs.count + 1)
            appIDs[bundleID] = appID
            try db.execute(
                sql: "INSERT INTO app (app_id, identifier) VALUES (?, ?)",
                arguments: [appID, bundleID]
            )
        }

        for notification in notifications {
            try db.execute(
                sql: """
                INSERT INTO record (rec_id, app_id, uuid, data, request_date, delivered_date, presented, style)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0)
                """,
                arguments: [
                    notification.recID,
                    appIDs[notification.bundleID],
                    Data(notification.uuid.rawBytes),
                    notification.payload(),
                    notification.deliveredAt.timeIntervalSinceReferenceDate - 1,
                    notification.deliveredAt.timeIntervalSinceReferenceDate,
                    notification.presented ? 1 : 0,
                ]
            )
        }
    }
}

/// The fingerprint of the fixture we just filled.
///
/// Computed with the app's own ``StoreFingerprint``, so the hash in a manifest and the
/// hash capture computes at runtime can never disagree about normalisation.
func fingerprint(of url: URL) throws -> StoreFingerprint {
    var configuration = Configuration()
    configuration.readonly = true
    let queue = try DatabaseQueue(path: url.path, configuration: configuration)
    return try queue.read { db in try StoreFingerprint.compute(in: db) }
}

// MARK: - Main

do {
    let arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))

    if arguments.printFingerprintOnly {
        let computed = try fingerprint(of: arguments.databaseURL)
        FileHandle.standardOutput.write(Data("\(computed.schemaHash) \(computed.dbinfoVersion ?? "-")\n".utf8))
        exit(EXIT_SUCCESS)
    }

    let source = arguments.sourceManifestURL
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(FixtureManifest.self, from: $0) }

    let seed = arguments.seed ?? source?.seed ?? 20_260_817
    let records = arguments.records ?? source?.recordCount ?? 250

    guard
        let adapter = StoreAdapterRegistry.adapters.first(where: {
            $0.supportedOSRange.contains(arguments.osMajor)
        })
    else {
        throw GeneratorError.noAdapter(arguments.osMajor)
    }

    // A fixed end date rather than "now": a fixture regenerated tomorrow must be identical
    // to one generated today, or its expected.json would churn on every run.
    let endingAt = Date(timeIntervalSince1970: 1_755_421_200)
    let notifications = SeededContent.notifications(count: records, seed: seed, endingAt: endingAt)

    try writeStore(
        notifications,
        dbinfoVersion: arguments.dbinfoVersion ?? "\(arguments.osMajor)",
        to: arguments.databaseURL
    )
    let computed = try fingerprint(of: arguments.databaseURL)

    let expected = ExpectedFile(
        notifications: notifications.map(\.expectation),
        cursor: ExpectedCursor(
            lastRecID: notifications.last?.recID ?? 0,
            lastDeliveredDate: notifications.last?.deliveredAt.timeIntervalSince1970 ?? 0
        )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(expected).write(to: arguments.expectedURL, options: .atomic)

    let manifest = FixtureManifest(
        osVersion: source?.osVersion ?? "\(arguments.osMajor).0",
        build: arguments.build,
        // Fixed rather than `Date()`: regenerating a fixture must produce the same bytes,
        // and a timestamp that moved would make every regeneration a diff.
        createdAt: source?.createdAt ?? "2026-08-19T00:00:00Z",
        generatorVersion: generatorVersion,
        schemaSHA256: computed.schemaHash,
        dbinfoVersion: computed.dbinfoVersion,
        adapterID: adapter.adapterID,
        seed: seed,
        recordCount: notifications.count,
        notes: arguments.notes ?? source?.notes ?? """
        Synthetic. Schema captured with sqlite3 .schema on macOS \(arguments.osMajor); \
        all rows generated from the seed. Never a copy of a real store.
        """
    )
    try encoder.encode(manifest).write(to: arguments.manifestURL, options: .atomic)

    // stdout rather than a Logger: this tool's caller is Scripts/make_fixture.sh, and a
    // shell script reads a pipe, not the unified log.
    let summary = "wrote \(notifications.count) records, schema \(computed.schemaHash.prefix(12)), "
        + "adapter \(adapter.adapterID)\n"
    FileHandle.standardOutput.write(Data(summary.utf8))
} catch {
    FileHandle.standardError.write(Data("FixtureGenerator: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}

// MARK: - Helpers

extension UUID {
    /// The 16 raw bytes, as the store keeps them.
    var rawBytes: [UInt8] {
        withUnsafeBytes(of: uuid) { Array($0) }
    }
}

extension Array where Element: Hashable {
    /// Order-preserving deduplication.
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
