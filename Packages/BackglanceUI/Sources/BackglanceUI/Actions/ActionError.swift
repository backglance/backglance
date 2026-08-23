import Foundation

// MARK: - ActionError

/// Everything that can go wrong running a notification action, from any of the three
/// entry points (context menu, keyboard shortcut, hover button).
///
/// Every case is built from identifiers, bundle ids, and system-error strings — never
/// from a notification's title, subtitle, body, sender, thread id or deep link. That is
/// not a convention to remember while adding a case; it is what the case list below
/// actually allows, the same way ``RedactingLogger`` makes a leak a compile error rather
/// than a habit. `reason:` payloads come from `Error.localizedDescription` on
/// system-level failures (`NSWorkspace`, `NSPasteboard`, the file system) or from
/// ``ArchiveError/detail(from:)``, never from parsed notification content.
///
/// See docs/features/ACTIONS.md#notificationactionhandler.
public enum ActionError: Error, Equatable {
    /// Neither the notification nor its owning app row could be found. Usually means the
    /// row was deleted (by this window or another) between the user's click and the fetch.
    case notFound(notificationID: Int64)

    /// Open failed because the app is not installed: `NSWorkspace` has no URL for
    /// `bundleID`. See docs/features/ACTIONS.md#open-openaction-and-deeplinkresolver.
    case appNotInstalled(bundleID: String)

    /// The app resolved to an installed copy, but `openApplication(at:configuration:)`
    /// itself threw. `reason` is `Error.localizedDescription` from `NSWorkspace`.
    case launchFailed(bundleID: String, reason: String)

    /// ⌘↩ ("open the link, no app fallback") was pressed on a row with no usable
    /// `deep_link`, or `NSWorkspace.open` refused the one that was there.
    case deepLinkUnresolvable(notificationID: Int64)

    /// `NSPasteboard.setString` returned `false` — typically another app holding the
    /// pasteboard locked at the instant of the write.
    case pasteboardFailure

    /// Export reached `ExportService` but failed after the save panel closed (an
    /// unwritable destination, a disk that filled mid-write). Cancelling the panel is
    /// not this case — see docs/features/ACTIONS.md#edge-cases-and-error-handling.
    case exportFailed(reason: String)

    /// All three System Settings URLs in `SystemSettingsLink` were refused.
    case systemSettingsUnavailable

    /// A read or write against the archive failed for a reason that is not one of the
    /// cases above. `reason` is always ``ArchiveError/detail(from:)``, never
    /// `error.localizedDescription` — the latter can spell out a failing statement's
    /// bound arguments in DEBUG builds, and a bound argument on an insert is the
    /// notification's own title, subtitle, body and sender.
    case archive(reason: String)

    // MARK: Public

    /// The one sentence the view layer shows inline for this error, or `nil` when
    /// there is nothing to say.
    ///
    /// `.deepLinkUnresolvable` is the `nil` case by design: docs/features/ACTIONS.md's
    /// error table maps it to a system beep (`NSSound.beep()`), not text — ⌘↩ with no
    /// link is a keyboard miss, not a failure worth interrupting the timeline for, and
    /// the beep says exactly as much as the situation deserves.
    ///
    /// `.notFound` and `.archive` share one message: neither tells the user anything
    /// they can act on, so both point at the log rather than inventing a sentence that
    /// would just repeat "something failed" in different words.
    public var userMessage: String? {
        switch self {
        case .notFound,
             .archive:
            String(localized: "Something went wrong — see log")

        case .appNotInstalled:
            String(localized: "App not found", comment: "Inline error: the notification's app is not installed")

        case let .launchFailed(bundleID, _):
            // No display name reaches this case — only the bundle id NSWorkspace was
            // given — so the bundle id stands in for "‹App›" rather than the row
            // re-deriving a name the error does not carry.
            String(
                localized: "Couldn't open \(bundleID)",
                comment: "Inline error: launching the app failed; placeholder is a bundle id, not a display name"
            )

        case .deepLinkUnresolvable:
            nil

        case .pasteboardFailure:
            String(localized: "Couldn't copy", comment: "Inline error: copying to the clipboard failed")

        case let .exportFailed(reason):
            String(
                localized: "Export failed: \(reason)",
                comment: "Inline error; placeholder is a system error description, already localized by macOS"
            )

        case .systemSettingsUnavailable:
            String(
                localized: "Couldn't open System Settings",
                comment: "Inline error; \"System Settings\" is the macOS app — use Apple's localized name for it"
            )
        }
    }
}
