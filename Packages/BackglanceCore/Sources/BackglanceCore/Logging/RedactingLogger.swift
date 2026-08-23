import Foundation
import os

// MARK: - LogSink

/// Somewhere a log line goes besides the unified log.
///
/// Users cannot easily hand anyone a `log show` dump, so Backglance keeps a small plain-text
/// file log as well — ``FileLogSink``, which is what every logger uses by default. The
/// protocol stays because a test wants its own destination, and because the diagnostics
/// export reads the same lines from somewhere it controls.
public protocol LogSink: Sendable {
    func write(level: OSLogType, category: String, message: String)
}

// MARK: - NoLogSink

/// Drops everything. For previews and for tests that only care that a call type-checks.
public struct NoLogSink: LogSink {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public func write(level _: OSLogType, category _: String, message _: String) {}
}

// MARK: - RedactingLogger

/// A logger whose API makes it impossible to hand it a notification.
///
/// 🔒 The rule is not a comment in a style guide; it is what the type system allows. The
/// methods here take either a plain message the caller assembled from non-content values,
/// or a ``NotificationLogRef``, which has no text in it. Overloads that would accept a
/// notification exist solely to be marked unavailable, so the mistake is a compile error
/// with an instruction rather than a leak nobody notices.
///
/// Messages are emitted `privacy: .public` on purpose: by construction they contain only
/// counts, durations, identifiers and error codes. Redaction happened before the string
/// existed. Wanting `.private` here means the value should not have reached this call.
///
/// See docs/operations/MONITORING_LOGGING.md#redactinglogger-content-cannot-reach-a-log-call.
public struct RedactingLogger: Sendable {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - category: the `os.Logger` category, and the third field of each file-log line.
    ///   - sink: where lines go besides the unified log. Defaults to the app's rotating file
    ///     log, which is the copy a user can actually find and send.
    public init(category: String, sink: any LogSink = FileLogSink.shared) {
        self.category = category
        self.sink = sink
        logger = Logger(subsystem: Log.subsystem, category: category)
    }

    // MARK: Public

    public let category: String

    // MARK: Plain messages

    /// `@autoclosure` so the message is not assembled when the level is disabled — a debug
    /// line in the capture loop runs on every tick.
    public func debug(_ message: @autoclosure () -> String) {
        emit(.debug, message())
    }

    public func info(_ message: @autoclosure () -> String) {
        emit(.info, message())
    }

    public func notice(_ message: @autoclosure () -> String) {
        emit(.default, message())
    }

    public func error(_ message: @autoclosure () -> String) {
        emit(.error, message())
    }

    public func fault(_ message: @autoclosure () -> String) {
        emit(.fault, message())
    }

    // MARK: Messages about a notification

    /// `event` is a `StaticString` so it cannot be built out of anything read at runtime.
    public func notice(_ event: StaticString, _ reference: NotificationLogRef) {
        emit(.default, "\(event) \(reference)")
    }

    public func error(_ event: StaticString, _ reference: NotificationLogRef, code: Int? = nil) {
        emit(.error, "\(event) \(reference)" + (code.map { " code=\($0)" } ?? ""))
    }

    // MARK: Unavailable overloads

    @available(*, unavailable, message: "Never log an ArchivedNotification. Use NotificationLogRef(_:bundleID:).")
    public func notice(_: StaticString, _: ArchivedNotification) {}

    @available(*, unavailable, message: "Never log an ArchivedNotification. Use NotificationLogRef(_:bundleID:).")
    public func error(_: StaticString, _: ArchivedNotification, code _: Int? = nil) {}

    // MARK: Private

    private let logger: Logger
    private let sink: any LogSink

    private func emit(_ level: OSLogType, _ text: String) {
        logger.log(level: level, "\(text, privacy: .public)")
        sink.write(level: level, category: category, message: text)
    }
}

// MARK: - Log

/// Every logger in Backglance, declared once.
///
/// One category per concern, so `log stream --predicate 'category == "capture"'` is a
/// useful thing to type when someone reports that capture stopped. The categories are
/// listed in docs/operations/MONITORING_LOGGING.md#subsystem-and-categories.
public enum Log {
    public static let subsystem = "app.backglance.Backglance"

    /// `CaptureEngine` lifecycle, watcher wakes, cursors, batch counts.
    public static let capture = RedactingLogger(category: "capture")

    /// Fingerprints, registry resolution, probe results, degraded reasons.
    public static let adapter = RedactingLogger(category: "adapter")

    /// Parse failures, by `rec_id` and a fixed reason.
    public static let parser = RedactingLogger(category: "parser")

    /// Migrations, integrity checks, retention, checkpoints.
    public static let archive = RedactingLogger(category: "archive")

    /// Query timings and semantic index batches.
    public static let search = RedactingLogger(category: "search")

    /// Away sessions and digests, by count.
    public static let digest = RedactingLogger(category: "digest")

    /// Rule evaluation counts and regex compile errors.
    public static let rules = RedactingLogger(category: "rules")

    /// Popover and window lifecycle, hotkey registration.
    public static let ui = RedactingLogger(category: "ui")

    /// Sparkle checks, downloads and install outcomes.
    public static let updater = RedactingLogger(category: "updater")

    /// `backglance://` route parsing and dispatch failures — the failure kind only, never
    /// the query string or any other value a caller put in the URL
    /// (docs/api/API_DOCUMENTATION.md#error-behavior).
    public static let automation = RedactingLogger(category: "automation")
}
