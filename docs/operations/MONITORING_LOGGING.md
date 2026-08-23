# Monitoring & Logging

Last Updated: 2026-08-18

This document describes how Backglance logs, what it refuses to log, how a user or developer reads those logs, what the "Export Diagnostics…" bundle contains and provably excludes, and which health indicators the app shows in its own UI. Backglance has no server side, so "monitoring" here means *local* observability only: unified logging (`os.Logger`), a small rotating file log, and status surfaces inside the app. There is no telemetry, no analytics SDK, and no crash-reporting service. The one rule that overrides every other rule in this file: **notification content never appears in a log** — not titles, not bodies, not senders, not thread IDs, not deep links.

## Table of Contents

- [Principles](#principles)
- [Log Levels](#log-levels)
- [Structured Local Logging](#structured-local-logging)
  - [Subsystem and Categories](#subsystem-and-categories)
  - [Privacy Annotations](#privacy-annotations)
  - [The File Log](#the-file-log)
- [RedactingLogger: Content Cannot Reach a Log Call](#redactinglogger-content-cannot-reach-a-log-call)
  - [Type-Level Design](#type-level-design)
  - [Implementation](#implementation)
  - [SwiftLint Rule](#swiftlint-rule)
- [Viewing Logs](#viewing-logs)
- [Diagnostics Export](#diagnostics-export)
  - [What the Export Contains](#what-the-export-contains)
  - [What the Export Provably Excludes](#what-the-export-provably-excludes)
  - [The Code That Builds It](#the-code-that-builds-it)
  - [The Test That Guards It](#the-test-that-guards-it)
  - [Reviewing the Zip Before Sending](#reviewing-the-zip-before-sending)
- [Health Indicators in the UI](#health-indicators-in-the-ui)
- [Crash Logs Without a Crash Reporter](#crash-logs-without-a-crash-reporter)
- [What "Zero Telemetry" Means Operationally](#what-zero-telemetry-means-operationally)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Principles

1. **Local only.** Logs are written to the unified logging system and to `~/Library/Logs/Backglance/backglance.log`. Nothing leaves the Mac unless the user manually attaches a file to a bug report.
2. **No content, ever.** Log lines may mention *that* a notification was captured, *which app* it came from (bundle ID), *how long* the body was, and *what went wrong*. They may not mention *what it said*. This is enforced by types (a `ParsedNotification` cannot be passed to the logger) and by a lint rule, not by reviewer vigilance.
3. **Useful to a solo developer.** The point of a log is to reconstruct a capture failure on a macOS release the developer has not seen. Adapter IDs, fingerprints, `ProbeResult` cases, and record counts are what matter; content is noise that also happens to be a privacy liability.
4. **Same rules for diagnostics export.** The zip a user sends is built from the same redacted sources and is tested to contain no archive text.

> 🔒 **Security:** The system store Backglance reads is ⚠️ undocumented and lives under Full Disk Access. Logging its raw rows would leak other apps' notification content into a world-readable-by-admin log. The `RawStoreRecord.plistData` blob is therefore never logged either — only its byte length and `recID`.

## Log Levels

Backglance uses the five `OSLogType` levels. Pick the level by *who needs to see it and when*, not by how excited the author is.

| Level | `os.Logger` call | Persisted by unified logging? | Written to file log at default level? | Use for |
|---|---|---|---|---|
| Debug | `logger.debug(...)` | No (memory only, unless `log config` enables) | No | Poll ticks, cursor values, per-batch timings during development |
| Info | `logger.info(...)` | Memory, flushed to disk on error | No | Adapter resolved, capture started/paused/resumed, migration applied, retention job summary |
| Notice (default) | `logger.notice(...)` | Yes | Yes | State changes a user might ask about: FDA granted/revoked, degraded mode entered/left, digest shown, update installed |
| Error | `logger.error(...)` | Yes | Yes | Recoverable failure: probe returned `.missingTables`, one record failed to parse, icon fetch failed |
| Fault | `logger.fault(...)` | Yes | Yes | Invariant broken: archive integrity check failed, migration threw, snapshot copy failed twice in a row |

Rules of thumb:

- One `notice` per state transition, not one per poll. A healthy Backglance at default level writes a handful of lines per day.
- `error` means "the app kept working but you should know". `fault` means "the developer would want to be paged if there were anyone to page".
- Never raise a level to make something visible in the file log; instead run with `BACKGLANCE_LOG_LEVEL=debug` (see [The File Log](#the-file-log)).

## Structured Local Logging

### Subsystem and Categories

All loggers share the subsystem `app.backglance.Backglance` and one of these categories:

| Category | Owner module | What it covers |
|---|---|---|
| `capture` | `BackglanceCapture` | `CaptureEngine` lifecycle, `StoreWatcher` events, cursors, batch counts |
| `adapter` | `BackglanceCapture` | Fingerprint computation, `StoreAdapterRegistry.resolve`, `ProbeResult`, degraded reasons |
| `parser` | `BackglanceCapture` | `RecordParser` failures (key missing, wrong type) — by `recID` and key name only |
| `archive` | `BackglanceCore` | Migrations, integrity checks, retention job, vacuum, WAL checkpoints |
| `search` | `BackglanceSearch` | FTS/hybrid query timings, semantic index batches |
| `digest` | `BackglanceCore` | Away session start/end with reason, digest built/shown/dismissed with item counts |
| `rules` | `BackglanceCore` | Rules evaluated (count, matched rule IDs), regex compile errors |
| `ui` | `Backglance` (app) | Popover open/close timings, window lifecycle, hotkey registration results |
| `updater` | `Backglance` (app) | Sparkle appcast checks, download, install outcomes |
| `automation` | `Backglance` (app) | `backglance://` route parse/dispatch failures, by failure kind only (docs/api/API_DOCUMENTATION.md#error-behavior) |

The loggers are declared once, in `BackglanceCore/Logging/Log.swift`, and imported everywhere:

```swift
import os

public enum Log {
    public static let subsystem = "app.backglance.Backglance"

    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let adapter = Logger(subsystem: subsystem, category: "adapter")
    public static let parser  = Logger(subsystem: subsystem, category: "parser")
    public static let archive = Logger(subsystem: subsystem, category: "archive")
    public static let search  = Logger(subsystem: subsystem, category: "search")
    public static let digest  = Logger(subsystem: subsystem, category: "digest")
    public static let rules   = Logger(subsystem: subsystem, category: "rules")
    public static let ui      = Logger(subsystem: subsystem, category: "ui")
    public static let updater = Logger(subsystem: subsystem, category: "updater")
    public static let automation = Logger(subsystem: subsystem, category: "automation")
}
```

### Privacy Annotations

Unified logging redacts interpolated values as `<private>` unless they are marked `privacy: .public`. Backglance's policy is:

- `.public` is allowed **only** for values that are not content: counts, durations, byte lengths, bundle IDs, adapter IDs, fingerprint hashes, `ProbeResult` case names, error codes, macOS versions, table names.
- Everything else stays at the default (`.private`). In practice this means the string interpolation of a `ParsedNotification` field is never written, because the type system does not let you get one into a log call in the first place (see below).

```swift
// ✅ Non-content values, safe to make public
Log.adapter.notice("Adapter resolved id=\(adapterID, privacy: .public) fingerprint=\(fp.schemaHash.prefix(12), privacy: .public) records=\(count, privacy: .public)")

// ✅ Duration and error code
Log.archive.error("Integrity check failed code=\(code, privacy: .public) after \(ms, privacy: .public) ms")

// ❌ Never — even if you think it is redacted, do not write it
// Log.capture.debug("captured \(parsed.title ?? "")")
```

> ❌ **Don't:** use `privacy: .public` on any `String` that originated in the system store or the archive, including `category` and `userInfo` keys. Category strings are app-defined and occasionally contain identifiers.

### The File Log

Unified logging is the primary sink, but users cannot easily hand you a `log show` dump, so Backglance also keeps a small plain-text file log:

| Property | Value |
|---|---|
| Path | `~/Library/Logs/Backglance/backglance.log`, or `$BACKGLANCE_LOG_DIR/backglance.log` |
| Rotation | 5 files × 2 MB (`backglance.log`, `backglance.1.log` … `backglance.4.log`); oldest deleted |
| Default level | `notice` and above |
| Override | Environment variable `BACKGLANCE_LOG_LEVEL` = `debug` \| `info` \| `notice` \| `error` \| `fault` |
| Format | `2026-08-17T09:12:44.318Z notice capture Adapter resolved id=StoreAdapterV26 records=143` |
| Permissions | file `0600`, directory `0700` |

Setting the override for a launched app:

```bash
# Quit Backglance first, then relaunch with debug file logging
osascript -e 'quit app "Backglance"'
launchctl setenv BACKGLANCE_LOG_LEVEL debug
open -a Backglance

# Later, back to default
launchctl unsetenv BACKGLANCE_LOG_LEVEL
```

The file sink receives the same *already-formatted* messages as `os.Logger`, and it never sees `.private` values (they are formatted as `<private>` before reaching the sink). The `FileLogSink` is fed from the `RedactingLogger` described next, so there is only one place where log strings are assembled.

Two details worth stating, because both are easy to get backwards:

- **Rotation happens before a write, not after.** Rotating after the write that crossed the
  limit leaves the directory holding only numbered files until the next message arrives — a
  confusing thing to hand someone who has just been asked to send you `backglance.log`. Checking
  the size first means a live file always exists once anything has been logged.
- **Nothing is created until the first message above the threshold.** A quiet Backglance leaves
  no file at all, and building the shared sink does not touch the disk.

`BACKGLANCE_LOG_DIR` moves the directory. It exists for the test plan, which sets it so a test
run does not append to the log of whoever is running it — a suite that writes into the
developer's own support directory makes their diagnostics export meaningless. It is honoured in
release builds too, and safely: it changes *where* lines are written, never what may be written.

## RedactingLogger: Content Cannot Reach a Log Call

### Type-Level Design

The rule "no content in logs" is not a comment; it is a compile error. Backglance code does not call `os.Logger` with notification types directly. Instead:

- `ParsedNotification` and `ArchivedNotification` **do** conform to `CustomStringConvertible` and `CustomDebugStringConvertible`, with a content-free `logDescription` — a uuid prefix, the app, and the field *lengths*. This is the opposite of the obvious rule, and the obvious rule is a leak: with no `description`, `"\(notification)"` does not fail and does not produce an opaque `Type(...)` — Swift reflects the struct and prints every stored property, `title`, `subtitle`, `body` and `sender` included. Withholding the conformance does not prevent the accident, it maximises the damage. A content-free description turns the same slip into a harmless line. `LogLeakTests` asserts it across `"\()"`, `String(describing:)`, `String(reflecting:)`, `description`, `debugDescription` and an interpolated array — collections reflect their elements, so one careless `"\(batch)"` is the same accident for a whole tick.
- Every log call site that wants to say something about a notification must pass a `NotificationLogRef`, a three-field struct built *from* the notification that carries only `id`, `bundleID`, and `length` (total character count of title + subtitle + body). There is no initializer that lets you smuggle text into it.
- `RedactingLogger` is the only logger type exposed by `Log`; its methods accept `LogMessage` (a tiny value type) rather than free-form `String` interpolation for anything involving a notification.

### Implementation

```swift
// BackglanceCore/Logging/NotificationLogRef.swift
import Foundation

/// The *only* thing about a notification that may be logged.
/// Built from a notification; carries no text.
public struct NotificationLogRef: Sendable, CustomStringConvertible {
    public let id: String        // archive uuid, or "unsaved" before insert
    public let bundleID: String
    public let length: Int       // characters of title+subtitle+body, for size diagnostics

    public init(_ n: ParsedNotification) {
        self.id = n.uuid.uuidString
        self.bundleID = n.bundleID
        self.length = (n.title?.count ?? 0) + (n.subtitle?.count ?? 0) + (n.body?.count ?? 0)
    }

    public init(_ n: ArchivedNotification, bundleID: String) {
        self.id = n.uuid
        self.bundleID = bundleID
        self.length = (n.title?.count ?? 0) + (n.subtitle?.count ?? 0) + (n.body?.count ?? 0)
    }

    public var description: String {
        "notif(id=\(id.prefix(8)) app=\(bundleID) len=\(length))"
    }
}
```

```swift
// BackglanceCore/Logging/RedactingLogger.swift
import Foundation
import os

/// A logger whose API makes it impossible to hand it a notification.
/// You can only pass a `NotificationLogRef` (no content) or plain non-content values.
public struct RedactingLogger: Sendable {
    private let logger: Logger
    private let category: String
    private let file: FileLogSink

    init(category: String, file: FileLogSink = .shared) {
        self.logger = Logger(subsystem: Log.subsystem, category: category)
        self.category = category
        self.file = file
    }

    // MARK: - Plain messages (no notification involved)

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

    // MARK: - Messages about a notification (reference only)

    public func notice(_ event: StaticString, _ ref: NotificationLogRef) {
        emit(.default, "\(event) \(ref.description)")
    }
    public func error(_ event: StaticString, _ ref: NotificationLogRef, code: Int? = nil) {
        let suffix = code.map { " code=\($0)" } ?? ""
        emit(.error, "\(event) \(ref.description)\(suffix)")
    }

    // MARK: - Unavailable overloads: make misuse a compile error with a clear message

    @available(*, unavailable, message: "Never log a ParsedNotification. Use NotificationLogRef(n).")
    public func notice(_ event: StaticString, _ n: ParsedNotification) {}
    @available(*, unavailable, message: "Never log an ArchivedNotification. Use NotificationLogRef(n, bundleID:).")
    public func notice(_ event: StaticString, _ n: ArchivedNotification) {}
    @available(*, unavailable, message: "Never log a ParsedNotification. Use NotificationLogRef(n).")
    public func error(_ event: StaticString, _ n: ParsedNotification, code: Int? = nil) {}
    @available(*, unavailable, message: "Never log an ArchivedNotification. Use NotificationLogRef(n, bundleID:).")
    public func error(_ event: StaticString, _ n: ArchivedNotification, code: Int? = nil) {}

    // MARK: - Sink

    private func emit(_ type: OSLogType, _ text: String) {
        // Values interpolated by callers are already plain Strings assembled by the caller;
        // the caller-side policy (privacy annotations) applies to os_log formatting only.
        // The file sink receives exactly the same string.
        logger.log(level: type, "\(text, privacy: .public)")
        file.write(level: type, category: category, text)
    }
}
```

The `Log` enum from earlier is then simply:

```swift
public enum Log {
    public static let subsystem = "app.backglance.Backglance"
    public static let capture = RedactingLogger(category: "capture")
    public static let adapter = RedactingLogger(category: "adapter")
    public static let parser  = RedactingLogger(category: "parser")
    public static let archive = RedactingLogger(category: "archive")
    public static let search  = RedactingLogger(category: "search")
    public static let digest  = RedactingLogger(category: "digest")
    public static let rules   = RedactingLogger(category: "rules")
    public static let ui      = RedactingLogger(category: "ui")
    public static let updater = RedactingLogger(category: "updater")
    public static let automation = RedactingLogger(category: "automation")
}
```

Usage at the parser boundary — success and error paths:

```swift
// BackglanceCapture/Parsing/RecordParser.swift — the parser has no error type of its
// own: it throws CaptureError.parseFailed(recID:reason:), where `reason` is one of a
// small fixed set of strings ("empty payload", "no delivered date", or a PlistGuard
// shape such as "payload over 64 KB"). Never a fragment of the payload.
throw CaptureError.parseFailed(recID: raw.recID, reason: "no delivered date")

// BackglanceCapture/Engine/CaptureEngine.swift — where it is logged, once per record,
// by rec_id and the fixed reason.
do {
    let parsed = try parser.parse(raw)
    Log.parser.debug("parsed rec=\(raw.recID) bytes=\(raw.plistData.count) app=\(raw.appIdentifier)")
    …
} catch let error as CaptureError {
    Log.capture.error("skip rec \(raw.recID): \(error.logDescription)")   // logDescription is content-free
    return .failed
} catch {
    Log.capture.error("rec \(raw.recID): \(String(describing: type(of: error)))")
    return .failed
}
```

A bad record is counted, not narrated: `ArchiveOutcome.failed` goes into the tick's tally, and the tally is what the summary line carries.

> ℹ️ **Info:** `emit` marks the assembled string `.public` because by construction it contains only non-content values; the redaction happens *before* the string exists, at the type level. If you find yourself wanting `.private` inside `RedactingLogger`, the value should not be reaching it at all.

### SwiftLint Rule

The lint rules are the belt to the type system's braces. Four of them, in `.swiftlint.yml`,
all `severity: error` so `swiftlint --strict` fails the build:

| Rule | Catches |
|---|---|
| `no_notification_content_in_logs` | a content *field* in a log call — `Log.capture.error("\(n.body)")` |
| `no_string_describing_notification` | `String(describing:)` / `String(reflecting:)` on a notification-shaped name |
| `no_notification_interpolation_in_logs` | the whole value dropped into a message — `Log.capture.debug("saw \(notification)")` |
| `no_silencing_privacy_rules` | a `swiftlint:disable` naming any of the above, or the Turkish-locale rule |

The last one is the one worth explaining. A `disable` comment on a privacy rule is how an
invariant becomes a suggestion: the line that needed silencing is exactly the line worth
reading, and the reviewer who would have read it sees a passing build instead. If one of these
fires and the code is genuinely fine, the fix is to make the code not look like a leak, or to
change the rule in a commit that says why.

**A custom rule is a regex, and a regex that matches nothing passes silently and forever.**
This repository has already had that happen: an earlier `no_notification_content_in_logs`
keyed on the literal `logger.`, which no call site in Backglance uses, so it matched nothing
and the invariant went unenforced while every run reported zero violations. A green
`swiftlint --strict` is evidence that the code is clean *or* that the rules are dead, and
nothing distinguishes the two.

`Scripts/verify_lint_rules.sh` is what distinguishes them. It writes a deliberately bad file
per rule — a body interpolated into a log line, a notification stringified, a whole value
dropped into a message, a Turkish-breaking fold, a disable comment on a privacy rule — and
fails if SwiftLint lets any of them through:

```console
$ Scripts/verify_lint_rules.sh
Verifying the privacy lint rules reject what they are supposed to reject:
  ok       no_notification_content_in_logs
  ok       no_string_describing_notification
  ok       no_notification_interpolation_in_logs
  ok       no_locale_sensitive_case_folding
  ok       no_silencing_privacy_rules

All privacy lint rules are live.
```

Note the cases are written *outside* a `Tests/` path on purpose: every privacy rule sets
`excluded: ".*Tests.*"`, so a fixture placed under `Tests/` would be skipped and the check
would pass without proving anything. CI runs the script beside `swiftlint --strict`
(see [`../deployment/CI_CD.md`](../deployment/CI_CD.md)); the pre-commit hook does not, because
it costs a second per commit and the rules do not change often.

## Viewing Logs

Unified logging, live:

```bash
# Everything from Backglance, all categories, including debug/info held in memory
log stream --predicate 'subsystem == "app.backglance.Backglance"' --level debug --style compact

# Only capture + adapter, useful when diagnosing an OS-break morning
log stream --predicate 'subsystem == "app.backglance.Backglance" AND (category == "capture" OR category == "adapter")' --level info
```

Historical, from the persisted store:

```bash
# Last 2 hours
log show --predicate 'subsystem == "app.backglance.Backglance"' --last 2h --style syslog

# A specific window, errors and faults only
log show --predicate 'subsystem == "app.backglance.Backglance" AND messageType >= error' \
  --start '2026-08-17 08:00:00' --end '2026-08-17 10:00:00'
```

The file log:

```bash
tail -f ~/Library/Logs/Backglance/backglance.log
grep -h ' adapter ' ~/Library/Logs/Backglance/backglance*.log | tail -50
```

> 💡 **Tip:** `Console.app` works too — search for `app.backglance.Backglance` in the search field and enable *Action ▸ Include Info Messages* / *Include Debug Messages*.

## Diagnostics Export

Settings ▸ Advanced ▸ **Export Diagnostics…** writes a zip to a location the user chooses (default `~/Desktop/Backglance-Diagnostics-2026-08-17.zip`) and then reveals it in Finder. It is intended to be attached to a GitHub issue. Nothing is uploaded automatically.

### What the Export Contains

| File in zip | Content | Content-free? |
|---|---|---|
| `manifest.json` | App version + build, macOS version, architecture, export timestamp, `contains_app_names: false` (or `true` if opted in) | Yes |
| `adapter.json` | Adapter ID in use, `StoreFingerprint.schemaHash` (SHA-256 hex, first 16 chars) and `dbinfoVersion`, last `ProbeResult` case name and record count | Yes |
| `capture_status_history.json` | Last 200 `CaptureStatus` transitions with timestamps and `DegradedReason` case names | Yes |
| `app_counts.json` | Per-app notification counts. **By default apps are `app-01`, `app-02`… (hashed order)**; the user may tick "Include app bundle identifiers" in the export sheet | Yes |
| `archive_stats.json` | Archive file size, page count, free page count, `PRAGMA integrity_check` result string, archive schema version, row counts per table | Yes |
| `log_tail.txt` | Last 500 lines from `backglance.log` (already content-free) | Yes |
| `settings_snapshot.json` | Non-secret settings from the `app.backglance.Backglance` `UserDefaults` suite (retention default, digest threshold, poll interval, hotkey, updater enabled, semantic search enabled) | Yes |

### What the Export Provably Excludes

| Excluded | Why you can trust it |
|---|---|
| Notification titles, subtitles, bodies, senders, thread IDs, deep links, `userInfo` | The builder never opens a `SELECT` on `notifications` text columns; only `COUNT(*)` and `PRAGMA` queries run. Guarded by `DiagnosticsExportTests.testExportContainsNoArchiveText` |
| Raw system store rows or `plistData` | The export has no reference to `BackglanceCapture` store reading; it consumes only `CaptureStatus` history and the cached fingerprint |
| App names or bundle IDs | Excluded unless the user opts in; opt-in is recorded in `manifest.json` so the reader knows |
| Rule patterns | Rules can contain personal keywords; only rule *count* and *kind* histogram are exported |
| Saved searches (v1.x) | Same reason; only count |
| Redaction originals | Never exist anywhere (redaction happens in memory before insert) |
| Keychain items, SQLCipher key, Sparkle keys | Not read by the builder |
| Crash reports | Not collected; user attaches manually (see below) |

### The Code That Builds It

`DiagnosticsExport.build(archive:options:environment:statusHistory:logDirectory:now:)` returns
the bundle as `[String: Data]` — file name to bytes — and `write(_:named:)` stages those to a
directory and zips it. Returning the bytes rather than writing them straight out is what lets
`DiagnosticsExportTests` read *every byte that would ship* without going near a file system,
and it lets the pane list the files before the user picks a destination.

```swift
public enum DiagnosticsExport {
    public struct Options: Sendable, Equatable {
        public var includeAppIdentifiers: Bool   // default false
        public var logTailLines: Int             // default 500
    }

    /// Facts about this Mac that do not come from the archive. A value rather than inline
    /// reads of `Bundle.main` and `ProcessInfo`, so a test asserts on a known environment
    /// instead of on whatever machine it runs on.
    public struct Environment: Sendable { … }

    public static func build(…) throws -> [String: Data]
    public static func write(_ files: [String: Data], named: String) throws -> URL
}
```

Three implementation notes, each of which is the reason a guarantee holds:

- **No `SELECT` reaches a text column.** `archive_stats.json` is `COUNT(*)` and `PRAGMA`;
  `app_counts.json` reads `apps`, never `notifications`. The exclusion is a property of the
  code rather than a promise about it, which is what `testTheExportContainsNoArchiveText`
  turns into a standing check: it seeds a title, a body, a sender and a code, then asserts
  none of them appears in any file.
- **Settings are an allow-list, never a dump of the suite.** `UserDefaults` accumulates keys
  from every part of the app and from macOS itself, so a future setting holding a saved search
  or a rule pattern would otherwise be exported the day it was added, by code nobody
  revisited. `exportableSettingKeys` is the whole list, and a test asserts no key in it looks
  like one that could carry text.
- **The zip is `NSFileCoordinator`'s `.forUploading`.** Foundation has no archiver, and
  shelling out to `/usr/bin/zip` from a signed app is a subprocess Backglance has no other
  reason to have.

App identities are anonymised by default and sorted loudest-first, so `app-01` is the noisiest.
"Which apps notify you" is itself personal — a dating app, a psychiatrist's booking system, a
union's messenger — and the anonymised form still answers the question a "why is Backglance
slow" report is asking. `manifest.json` records `contains_app_names`, so a reader never has to
guess whether `app-01` is a label or an app literally called that.

### Reviewing the Zip Before Sending

Users are told, in the export sheet, to look before they attach:

```bash
cd ~/Desktop
mkdir bg-review && ditto -x -k Backglance-Diagnostics-2026-08-17.zip bg-review
ls -la bg-review
# read each file — they are all short JSON/text
cat bg-review/manifest.json
cat bg-review/app_counts.json
less bg-review/log_tail.txt
```

If anything in there worries the user, they delete the file from the folder and re-zip, or simply do not send it. The developer's issue template asks for `adapter.json` and `capture_status_history.json` first; the rest is optional.

## Health Indicators in the UI

**Menu bar icon states**

| State | Icon | Meaning |
|---|---|---|
| Running | Filled glyph | Capture running, adapter healthy |
| Running with unread | Filled glyph + badge count (`99+` cap) | Unread notifications since last popover open |
| Paused | Outlined glyph with pause bar | User paused (15 min / 1 h / until tomorrow / indefinitely) |
| Degraded | Outlined glyph with small warning triangle | `CaptureStatus.degraded(reason)` — click to see the reason |
| Stopped | Dimmed glyph | Engine stopped (during migration, wipe, or after a fault) |

**Settings ▸ Status pane**

| Row | Source | Example |
|---|---|---|
| Capture | `CaptureEngine` status | `Running` / `Degraded — Unknown store schema` |
| Adapter | `capture_state.adapter_id` | `StoreAdapterV26` |
| Store fingerprint | `StoreFingerprint.schemaHash` prefix + `dbinfoVersion` | `9f2c…4b1a (dbinfo 17)` |
| Last capture | Time of last successful batch | `2 minutes ago (14 records)` |
| Full Disk Access | `StoreLocation.current()` readability probe | `Granted` / `Not granted — Open System Settings` |
| Archive | Size, notification count, last integrity check result and time | `84 MB · 61,204 notifications · integrity ok (yesterday 03:12)` |
| Degraded reasons | `DegradedReason` history, most recent first | `.unknownSchema` at 08:41 after macOS 26.6 update |
| Updater | Enabled/disabled, last check, channel | `Enabled · checked 3 h ago` |
| Buttons | — | `Export Diagnostics…`, `Check for Updates…`, `Run Integrity Check` |

The Status pane reads the same values the diagnostics export writes, so what a user sees is what the developer will receive.

## Crash Logs Without a Crash Reporter

Backglance ships **no** crash-reporting SDK. Not Sentry, not Crashlytics, not any hosted service. If the app crashes, macOS writes a report to `~/Library/Logs/DiagnosticReports/` as it does for any process, and that file stays on the Mac.

To attach one manually to a bug report:

```bash
ls -t ~/Library/Logs/DiagnosticReports/ | grep -i backglance | head
# Open the newest one and read it — it contains thread stacks and binary images,
# not notification content, but do read it before sharing.
open ~/Library/Logs/DiagnosticReports/"$(ls -t ~/Library/Logs/DiagnosticReports/ | grep -i backglance | head -1)"
```

`Console.app ▸ Crash Reports` shows the same files. Symbolication happens on the developer's side with the dSYM archived per release (see [`../deployment/PACKAGING_NOTARIZATION.md`](../deployment/PACKAGING_NOTARIZATION.md)).

> ℹ️ **Info:** Apple's own crash-report sharing (System Settings ▸ Privacy & Security ▸ Analytics & Improvements ▸ "Share with App Developers") does not apply: Backglance is not distributed through the Mac App Store, so Apple never forwards its reports.

## What "Zero Telemetry" Means Operationally

Concretely, for the shipped binary:

- No analytics SDK is linked. `otool -L` on `Backglance.app/Contents/MacOS/Backglance` shows system frameworks, GRDB, and Sparkle — nothing else.
- No request is made on launch, on first run, on update install, on crash, or on any user action, except by Sparkle when the updater is enabled.
- Sparkle, when enabled, contacts the appcast URL (`https://backglance.github.io/backglance/appcast.xml`) on its schedule and downloads a release archive from GitHub Releases when the user accepts an update. `SUEnableSystemProfiling` is **off**, so no system-profile query string is appended. Disabling the updater in Settings ▸ Updates removes the only network access.
- CloudKit sync (v1.x) is opt-in and off by default; when enabled it talks only to iCloud under the user's own Apple ID.

How a user can verify:

```bash
# Watch what Backglance's process touches on the network for a couple of minutes.
# With the updater disabled you should see zero bytes.
nettop -p "$(pgrep -x Backglance)" -m tcp -L 1

# Or over time:
nettop -p "$(pgrep -x Backglance)" -m tcp -d
```

With **Little Snitch** (or LuLu, or Lockdown-style firewalls): create a rule to deny all outgoing connections for `Backglance`. Everything keeps working; the only thing that stops is Sparkle's update check, which will report "Unable to check for updates" in Settings ▸ Updates. That is the intended proof.

> ✅ **Do:** treat "the app made a request I did not expect" as a bug and report it with the destination host. It would be a regression against a documented guarantee, and the [`../security/SECURITY.md`](../security/SECURITY.md) policy treats it as a security issue.

## Next Steps

- Reading a specific failure? Go to [`./TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) for the scenario list and the bug-report checklist.
- Rotation, retention jobs, and integrity schedules live in [`./MAINTENANCE.md`](./MAINTENANCE.md).
- Adapter fingerprints and the fixture strategy referenced in the Status pane are explained in [`../architecture/OS_COMPATIBILITY_PLAYBOOK.md`](../architecture/OS_COMPATIBILITY_PLAYBOOK.md).

## Related Documentation

- [`./TROUBLESHOOTING.md`](./TROUBLESHOOTING.md)
- [`./MAINTENANCE.md`](./MAINTENANCE.md)
- [`../features/PERMISSIONS_PRIVACY.md`](../features/PERMISSIONS_PRIVACY.md)
- [`../features/PRIVACY_CONTROLS.md`](../features/PRIVACY_CONTROLS.md)
- [`../features/CAPTURE.md`](../features/CAPTURE.md)
- [`../architecture/OS_COMPATIBILITY_PLAYBOOK.md`](../architecture/OS_COMPATIBILITY_PLAYBOOK.md)
- [`../architecture/DATABASE_SCHEMA.md`](../architecture/DATABASE_SCHEMA.md)
- [`../deployment/CI_CD.md`](../deployment/CI_CD.md)
- [`../deployment/PACKAGING_NOTARIZATION.md`](../deployment/PACKAGING_NOTARIZATION.md)
- [`../security/SECURITY.md`](../security/SECURITY.md)
- [`../testing/TESTING.md`](../testing/TESTING.md)
- [`../../README.md`](../../README.md)
