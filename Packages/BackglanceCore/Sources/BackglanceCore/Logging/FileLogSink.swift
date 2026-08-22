import Foundation
import os

// MARK: - LogLevel

/// The five levels, ordered, so a threshold can be compared against.
///
/// A parallel to `OSLogType` rather than a use of it, because `OSLogType` is a C enum whose
/// raw values are not ordered by severity — `.info` is 1 and `.debug` is 2, so "at least
/// info" cannot be written as a comparison on it.
public enum LogLevel: Int, Comparable, CaseIterable, Sendable {
    case debug = 0
    case info
    case notice
    case error
    case fault

    // MARK: Lifecycle

    /// Parses `BACKGLANCE_LOG_LEVEL`. An unrecognised value is `nil`, so the caller keeps the
    /// default rather than silently logging everything.
    public init?(name: String) {
        guard let match = Self.allCases.first(where: { $0.name == name.lowercased() }) else {
            return nil
        }
        self = match
    }

    public init(_ type: OSLogType) {
        self = switch type {
        case .debug: .debug
        case .info: .info
        case .error: .error
        case .fault: .fault
        default: .notice
        }
    }

    // MARK: Public

    /// What appears in the file, and what the environment variable accepts.
    public var name: String {
        switch self {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - FileLogSink

/// A small rotating plain-text log beside the unified one.
///
/// It exists because of a support problem, not a technical one: unified logging is the better
/// sink in every respect except that nobody can hand you one. Asking a user to run `log show`
/// with the right predicate and a time window, then send the result, is asking most people to
/// give up. `~/Library/Logs/Backglance/backglance.log` is a file they can find in Finder.
///
/// > 🔒 It carries exactly what `os.Logger` carries, because both are fed the same already
/// > assembled string from ``RedactingLogger`` — the one place log text is built, out of
/// > counts, identifiers and error codes. There is no second formatting path here that could
/// > be given something richer. The file is `0600` in a `0700` directory, which is the same
/// > posture as the archive.
///
/// Five files of two megabytes: enough to hold the run where something went wrong plus the
/// few before it, small enough that a user can attach one to an email without thinking about
/// it, and bounded so a debug level left on overnight cannot fill a disk.
///
/// See docs/operations/MONITORING_LOGGING.md#the-file-log.
public final class FileLogSink: LogSink, @unchecked Sendable {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - directory: where the files live. Defaults to `~/Library/Logs/Backglance/`.
    ///   - minimumLevel: the threshold. Defaults to `BACKGLANCE_LOG_LEVEL`, then `notice`.
    ///   - maximumFileSize: bytes before rotating.
    ///   - keptFiles: how many files exist at most, the live one included.
    public init(
        directory: URL = FileLogSink.defaultDirectory(),
        minimumLevel: LogLevel = FileLogSink.configuredLevel(),
        maximumFileSize: Int = 2 * 1_024 * 1_024,
        keptFiles: Int = 5
    ) {
        self.directory = directory
        self.minimumLevel = minimumLevel
        self.maximumFileSize = maximumFileSize
        self.keptFiles = max(1, keptFiles)
    }

    deinit {
        try? handle?.close()
    }

    // MARK: Public

    /// The app's file log.
    ///
    /// A shared instance because rotation is a whole-directory operation: two sinks over the
    /// same files would rename out from under each other. Nothing forces its use — the
    /// initializer is public so tests get their own directory — but there is only ever one in
    /// the app.
    public static let shared = FileLogSink()

    public let minimumLevel: LogLevel

    /// The live file. The rotated ones sit beside it as `backglance.1.log` … `backglance.4.log`.
    public var currentFile: URL {
        directory.appendingPathComponent("backglance.log")
    }

    /// `~/Library/Logs/Backglance/`, or wherever `BACKGLANCE_LOG_DIR` points.
    ///
    /// The override exists for the test plan, which sets it so that a `swift test` run does
    /// not append to the log of whoever is running it — a suite that writes into the
    /// developer's own support directory is a suite that makes their diagnostics export
    /// meaningless. It is honoured in release builds too, and safely so: it moves where lines
    /// are written, never what may be written, and every other rule in this file still
    /// applies to the destination.
    public static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["BACKGLANCE_LOG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Backglance", isDirectory: true)
    }

    /// `BACKGLANCE_LOG_LEVEL`, or `notice`.
    ///
    /// Honoured in release builds too, unlike `BACKGLANCE_STORE_PATH`: turning up a user's own
    /// log level to diagnose their own problem is a support affordance, and the file it writes
    /// to is subject to every other rule in this file. It cannot be made to log content.
    public static func configuredLevel(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LogLevel {
        environment["BACKGLANCE_LOG_LEVEL"].flatMap(LogLevel.init(name:)) ?? .notice
    }

    /// One line: an ISO-8601 timestamp, the level, the category, the message.
    ///
    /// Timestamps are UTC with milliseconds. A support log whose times are in the reporter's
    /// local zone and the reader's local zone is a log where "this happened before that" takes
    /// arithmetic to establish.
    public static func line(level: LogLevel, category: String, message: String, at date: Date) -> String {
        // Newlines would let one message look like several entries, which matters for a
        // format anything might grep.
        let flattened = message.replacingOccurrences(of: "\n", with: " ")
        return "\(timestamp.string(from: date)) \(level.name) \(category) \(flattened)"
    }

    public func write(level: OSLogType, category: String, message: String) {
        write(level: LogLevel(level), category: category, message: message, at: Date())
    }

    /// The testable seam: the same write, with the clock passed in.
    public func write(level: LogLevel, category: String, message: String, at date: Date) {
        guard level >= minimumLevel else {
            return
        }
        let line = Self.line(level: level, category: category, message: message, at: date) + "\n"
        guard let data = line.data(using: .utf8) else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        // Every failure here is silent on purpose. A log sink that throws — or worse, that
        // logs about failing to log — turns a full disk or a revoked home directory into a
        // second problem on top of the first, in the middle of whatever the caller was doing.
        guard var handle = openedHandle() else {
            return
        }
        // Rotate *before* writing rather than after, so that a live `backglance.log` always
        // exists once anything has been logged. Rotating afterwards leaves the directory with
        // only numbered files until the next message, which is a confusing thing to hand
        // someone who has been asked to send their log.
        if written >= maximumFileSize {
            rotate()
            guard let reopened = openedHandle() else {
                return
            }
            handle = reopened
        }
        try? handle.write(contentsOf: data)
        written += data.count
    }

    // MARK: Private

    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private let directory: URL
    private let maximumFileSize: Int
    private let keptFiles: Int

    /// Serialises writes and rotation. Log calls come from every actor in the app, and a
    /// rotation halfway through someone else's write would interleave two lines.
    private let lock = NSLock()

    private var handle: FileHandle?
    private var written = 0

    /// The open file, creating the directory and file if this is the first write.
    ///
    /// Lazy rather than opened at init, so a Backglance that never logs above the threshold
    /// never creates a file — and so building the shared instance cannot touch the disk.
    private func openedHandle() -> FileHandle? {
        if let handle {
            return handle
        }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let path = currentFile.path
        if !fileManager.fileExists(atPath: path) {
            fileManager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        } else {
            // A file left behind by an older build, or by a stray umask, is tightened rather
            // than trusted.
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        guard let opened = try? FileHandle(forWritingTo: currentFile) else {
            return nil
        }
        written = (try? opened.seekToEnd()).map(Int.init) ?? 0
        handle = opened
        return opened
    }

    /// Shifts every file down one and starts a new live file.
    ///
    /// Oldest first, so nothing is overwritten before it has been moved. The one beyond
    /// `keptFiles` is deleted rather than kept "just in case": an unbounded log is how a
    /// forgotten `BACKGLANCE_LOG_LEVEL=debug` fills a disk.
    private func rotate() {
        let fileManager = FileManager.default
        try? handle?.close()
        handle = nil
        written = 0

        for index in stride(from: keptFiles - 1, through: 1, by: -1) {
            let source = index == 1 ? currentFile : rotatedFile(index - 1)
            let destination = rotatedFile(index)
            guard fileManager.fileExists(atPath: source.path) else {
                continue
            }
            try? fileManager.removeItem(at: destination)
            try? fileManager.moveItem(at: source, to: destination)
        }
    }

    private func rotatedFile(_ index: Int) -> URL {
        directory.appendingPathComponent("backglance.\(index).log")
    }
}
