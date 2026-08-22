import Foundation
import GRDB

// MARK: - DiagnosticsExport

/// Everything a bug report needs about this Mac, and nothing a notification said.
///
/// The premise is that a user should be able to send a maintainer a diagnostic bundle without
/// having to trust anybody about what is in it. Two things make that true rather than
/// promised. First, the builder never issues a `SELECT` against a text column — only
/// `COUNT(*)`, `PRAGMA`, and a fixed allow-list of preference keys — so there is no code path
/// by which a title or a body could be assembled into a file. Second, the export is plain
/// JSON and text in a zip the user can open before sending, and the pane says so.
///
/// > 🔒 App identities are anonymised by default. "Which apps notify you" is itself
/// > personal — a list of dating apps, a psychiatrist's booking system, a union's
/// > messenger — so the counts ship as `app-01`, `app-02` in descending order unless the user
/// > opts in, and `manifest.json` records which it was so the reader knows what they are
/// > looking at.
///
/// See docs/operations/MONITORING_LOGGING.md#diagnostics-export.
public enum DiagnosticsExport {
    // MARK: Public

    /// What the user chose in the export sheet.
    public struct Options: Sendable, Equatable {
        // MARK: Lifecycle

        public init(includeAppIdentifiers: Bool = false, logTailLines: Int = 500) {
            self.includeAppIdentifiers = includeAppIdentifiers
            self.logTailLines = logTailLines
        }

        // MARK: Public

        /// Whether `app_counts.json` names apps. Off by default — see the note above.
        public var includeAppIdentifiers: Bool

        /// How much of the file log to include. Enough to hold the run that went wrong.
        public var logTailLines: Int
    }

    /// The facts about this Mac that do not come from the archive.
    ///
    /// A value rather than reads of `Bundle.main` and `ProcessInfo` inline, so a test can
    /// assert on a known environment instead of on whatever machine it runs on.
    public struct Environment: Sendable {
        // MARK: Lifecycle

        public init(
            appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: String = Environment.currentArchitecture,
            defaults: UserDefaults = .standard
        ) {
            self.appVersion = appVersion
            self.appBuild = appBuild
            self.osVersion = osVersion
            self.architecture = architecture
            self.defaults = defaults
        }

        // MARK: Public

        public static var currentArchitecture: String {
            #if arch(arm64)
                "arm64"
            #elseif arch(x86_64)
                "x86_64"
            #else
                "unknown"
            #endif
        }

        public let appVersion: String
        public let appBuild: String
        public let osVersion: String
        public let architecture: String
        public let defaults: UserDefaults
    }

    /// The files, as name → bytes. Written to a directory and zipped by ``write(_:to:)``.
    ///
    /// Returned rather than written directly so the test can read every byte that would ship
    /// without going near the file system, and so the pane can show the file list before the
    /// user picks a destination.
    public static func build(
        archive: Archive,
        options: Options = Options(),
        environment: Environment = Environment(),
        statusHistory: [String] = [],
        logDirectory: URL = FileLogSink.defaultDirectory(),
        now: Date = Date()
    ) throws -> [String: Data] {
        var files: [String: Data] = [:]
        files["manifest.json"] = try json([
            "app_version": environment.appVersion,
            "app_build": environment.appBuild,
            "os_version": environment.osVersion,
            "architecture": environment.architecture,
            "exported_at": ISO8601DateFormatter().string(from: now),
            // Stated in the bundle itself, so a reader never has to guess whether `app-01` is
            // an anonymised name or an app literally called that.
            "contains_app_names": String(options.includeAppIdentifiers),
        ])
        files["adapter.json"] = try json(adapterInfo(archive: archive))
        files["capture_status_history.json"] = try json(["transitions": statusHistory])
        files["app_counts.json"] = try json(appCounts(archive: archive, options: options))
        files["archive_stats.json"] = try json(archiveStats(archive: archive))
        files["settings_snapshot.json"] = try json(settingsSnapshot(environment.defaults))
        files["log_tail.txt"] = Data(logTail(in: logDirectory, lines: options.logTailLines).utf8)
        return files
    }

    /// Writes the files to a temporary directory and zips it.
    ///
    /// `NSFileCoordinator`'s `.forUploading` is the zip: Foundation has no archiver, and
    /// shelling out to `/usr/bin/zip` from a signed app is a subprocess this app has no other
    /// reason to have.
    ///
    /// - Returns: the zip's location, which the caller moves to wherever the user chose.
    public static func write(_ files: [String: Data], named name: String = "Backglance-Diagnostics") throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-\(UUID().uuidString)", isDirectory: true)
        let folder = staging.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (fileName, data) in files {
            try data.write(to: folder.appendingPathComponent(fileName))
        }

        var coordinationError: NSError?
        var result: URL?
        var copyError: (any Error)?
        NSFileCoordinator()
            .coordinate(readingItemAt: folder, options: [.forUploading], error: &coordinationError) { zip in
                let destination = staging.appendingPathComponent("\(name).zip")
                do {
                    try FileManager.default.moveItem(at: zip, to: destination)
                    result = destination
                } catch {
                    copyError = error
                }
            }
        if let error = coordinationError ?? copyError {
            throw ArchiveError.writeFailed(table: "diagnostics", underlying: ArchiveError.detail(from: error))
        }
        guard let result else {
            throw ArchiveError.writeFailed(table: "diagnostics", underlying: "no archive produced")
        }
        return result
    }

    // MARK: Internal

    /// 🔒 The complete list of preference keys that may be exported.
    ///
    /// An allow-list, never a dump of the suite. `UserDefaults` accumulates keys from every
    /// part of the app and from macOS itself, and a future setting holding something personal —
    /// a saved search, a rule pattern, a per-app note — would otherwise be exported the day it
    /// was added, by code nobody revisited.
    static let exportableSettingKeys = [
        "privacy.globalRetention",
        "privacy.redactOTPInAllApps",
        "capture.pausedUntil",
        "capture.importWhilePaused",
        "digest.minimumSessionMinutes",
        "digest.bannerEnabled",
        "search.semanticEnabled",
        "updates.automaticChecks",
        "timeline.groupingMode",
        "timeline.viewMode",
    ]

    // MARK: Private

    private static func json(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try encoder.encode(value)
        } catch {
            throw ArchiveError.writeFailed(table: "diagnostics", underlying: ArchiveError.detail(from: error))
        }
    }

    private static func adapterInfo(archive: Archive) throws -> [String: String] {
        [
            "adapter_id": (try? archive.adapterID()) as? String ?? "none",
            // A hash prefix, which is what the fingerprint already is — a digest of Apple's
            // *schema*, deliberately content-free (docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md).
            "fingerprint": String(((try? archive.captureState(.fingerprint)) as? String ?? "none").prefix(16)),
            "last_import_at": (try? archive.lastImportDate()).flatMap { $0 }
                .map { ISO8601DateFormatter().string(from: $0) } ?? "never",
        ]
    }

    /// Counts per app, anonymised unless the user opted in.
    ///
    /// Sorted descending before the labels are assigned, so `app-01` is the noisiest — which
    /// is the shape of the answer a "why is Backglance slow" report needs, without naming
    /// anything.
    private static func appCounts(archive: Archive, options: Options) throws -> [[String: String]] {
        let apps = try archive.allApps().sorted { $0.notificationCount > $1.notificationCount }
        return apps.enumerated().map { index, app in
            [
                "app": options.includeAppIdentifiers ? app.bundleId : String(format: "app-%02d", index + 1),
                "count": String(app.notificationCount),
            ]
        }
    }

    /// 🔒 Counts and pragmas only. Nothing here reads a text column, which is what makes the
    /// exclusion a property of the code rather than a promise about it.
    private static func archiveStats(archive: Archive) throws -> [String: String] {
        let space = try archive.spaceReport()
        let health = try archive.checkIntegrity(level: .quick)
        let counts = try archive.pool.read { database -> [String: Int] in
            var tallies: [String: Int] = [:]
            for table in ["notifications", "apps", "away_sessions", "digests", "redactions", "rules"] {
                guard try database.tableExists(table) else {
                    continue
                }
                tallies[table] = try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM \(table.quotedDatabaseIdentifier)"
                ) ?? 0
            }
            return tallies
        }

        var stats: [String: String] = [
            "byte_count": String(space.byteCount),
            "page_count": String(space.pageCount),
            "freelist_count": String(space.freelistCount),
            "integrity_ok": String(health.ok),
            "schema_version": (try? archive.metaValue(forKey: "archive_version")) as? String ?? "unknown",
        ]
        for (table, count) in counts {
            stats["rows_\(table)"] = String(count)
        }
        return stats
    }

    private static func settingsSnapshot(_ defaults: UserDefaults) -> [String: String] {
        var snapshot: [String: String] = [:]
        for key in exportableSettingKeys {
            guard let value = defaults.object(forKey: key) else {
                continue
            }
            snapshot[key] = String(describing: value)
        }
        return snapshot
    }

    /// The tail of the file log, which is already content-free by construction.
    private static func logTail(in directory: URL, lines: Int) -> String {
        let url = directory.appendingPathComponent("backglance.log")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lines)
            .joined(separator: "\n")
    }
}
