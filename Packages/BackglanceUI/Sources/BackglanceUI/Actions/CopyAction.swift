import AppKit
import BackglanceCore
import Foundation

// MARK: - CopyAction

/// The ⌘C / ⌥⌘C path: builds the plain-text form of one or more notifications and
/// writes it to the pasteboard through ``PasteboardCopier``, never directly. See
/// docs/features/ACTIONS.md#copy.
///
/// A plain `struct`, the same shape as ``OpenAction``: text-building has a handful
/// of small, independently testable rules (drop empty parts, join with an em dash,
/// prefix app-and-timestamp for the ⌥⌘C form), and reads cleanest as its own type
/// that `CopyActionTests` can drive without touching the archive. Internal, not
/// `public`: nothing outside `BackglanceUI` constructs one directly, only
/// `NotificationActionHandler`.
///
/// Unlike ``OpenAction``, the seam this reaches AppKit through
/// (``PasteboardWriting``) exists for one narrow reason rather than as a blanket
/// "never touch the real thing" rule: a real `NSPasteboard` is safe to use
/// directly, even in tests, because a private named instance
/// (`NSPasteboard(name:)`) cannot affect anything outside itself the way
/// `NSWorkspace.open` or `openApplication` would. See ``PasteboardWriting``'s
/// doc comment for why the seam is still worth having.
struct CopyAction {
    // MARK: Internal

    /// `false` for ⌘C, `true` for ⌥⌘C. See docs/features/ACTIONS.md#copy.
    var includeAppAndTimestamp = false

    /// Where the concealed write lands. Defaults to `.general`, the real
    /// pasteboard every production call site uses; `CopyActionTests` passes a
    /// private named pasteboard instead, per
    /// docs/features/ACTIONS.md#testing-approach, so a test run never touches the
    /// developer's actual clipboard. See ``PasteboardWriting`` for why this is a
    /// protocol rather than concrete `NSPasteboard`.
    var pasteboard: any PasteboardWriting = NSPasteboard.general

    /// The plain-text form of one notification: `Title — Body` (em dash with
    /// spaces), or just whichever of the two is non-empty.
    ///
    /// `title` and `body` only — `subtitle` is deliberately left out. This is a
    /// decision, not an oversight: docs/features/ACTIONS.md#copy specifies
    /// `Title — Body` and does not mention subtitle anywhere in the format, so
    /// this follows the doc as written rather than guessing that subtitle
    /// belongs too. A future revision that wants subtitle included is free to
    /// add it, deliberately, as its own task.
    ///
    /// Redacted content is copied exactly as the archive stored it — i.e. the
    /// placeholder `[code redacted]` sitting in `title` or `body` like any other
    /// text. The original digits were never written to the archive in the first
    /// place (Privacy Invariant #2), so there is nothing left for this function
    /// to redact, and no redaction logic belongs here: it would either be a
    /// no-op against text that is already a placeholder, or — worse — a second
    /// place a real code could theoretically leak through if some future bug
    /// ever let one reach `title`/`body` unredacted.
    func text(for notification: ArchivedNotification, app: AppRecord) -> String {
        let parts = [notification.title, notification.body]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let line = parts.joined(separator: " — ")
        guard includeAppAndTimestamp else {
            return line
        }
        let name = app.displayName ?? app.bundleId
        return "\(name) · \(Self.stamp.string(from: notification.deliveredAt.date))\n\(line)"
    }

    /// Multi-select: one block per notification, separated by a blank line, in
    /// the order `items` was given — the order the caller's selection was in,
    /// not re-sorted here. Writes through ``PasteboardCopier/copyConcealed(_:to:)``,
    /// the one function every copy in Backglance goes through.
    ///
    /// - Throws: ``ActionError/pasteboardFailure`` if the concealed write
    ///   failed.
    func run(_ items: [(ArchivedNotification, AppRecord)]) throws {
        let joined = items.map { text(for: $0.0, app: $0.1) }.joined(separator: "\n\n")
        guard PasteboardCopier.copyConcealed(joined, to: pasteboard) else {
            throw ActionError.pasteboardFailure
        }
    }

    // MARK: Private

    /// `yyyy-MM-dd HH:mm`, local time — unambiguous, sorts well when pasted into
    /// a sheet. A `static let` because building a `DateFormatter` is expensive
    /// enough to be worth sharing across every call rather than paying the cost
    /// per copy.
    ///
    /// docs/features/ACTIONS.md's sketch left `locale` at its default. A fixed
    /// `dateFormat` string is not immune to the user's locale just because it
    /// looks like plain ASCII: `DateFormatter` interprets pattern letters like
    /// `yyyy` and `HH` against the locale's *calendar*, and some locales (Farsi,
    /// Thai, and others) use a non-Gregorian calendar and non-ASCII digits by
    /// default, which would silently turn "2026-08-22 09:41" into something a
    /// user pasting into a bug report did not expect and could not sort.
    /// Pinning `locale` to `en_US_POSIX` — Apple's own recommendation for a
    /// fixed-format, machine-readable date string — keeps the output Gregorian
    /// and ASCII regardless of the user's region. `timeZone` is left at its
    /// default (the system's current zone) on purpose: the format is
    /// documented as local time, not UTC, so the zone should track wherever
    /// the user actually is.
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
