import BackglanceCore
import Foundation

// MARK: - StatusItemAccessibility

/// What VoiceOver says about the menu bar item.
///
/// The status item itself is AppKit and lives in the app shell, but the copy it
/// announces is decided here for two reasons: the strings belong next to
/// ``TimelineCaptureState``, which is what varies them, and the app target has
/// no test bundle — a pure function in this package is the only version of this
/// logic anything can assert against.
///
/// The icon carries three signals at once — a glyph for capture state, a number
/// for the unread count, and nothing at all when both are unremarkable. A
/// VoiceOver user gets none of that from an image, so the label spells out both
/// (docs/reference/ACCESSIBILITY.md#menu-bar-item).
public enum StatusItemAccessibility {
    // MARK: Public

    /// The help text, which never varies — what the button does and the hotkey
    /// that does it without the menu bar.
    public static var help: String {
        String(localized: "Opens the notification timeline. Also available with Control-Option-N.")
    }

    /// What the button announces: the unread count, then the capture state when
    /// it is anything other than running.
    ///
    /// The count is capped the same way the drawn badge is, at
    /// ``BackglanceCore/Archive/unreadBadgeCap``. Reading out an exact number
    /// the icon does not show would be a different kind of wrong from reading
    /// nothing.
    public static func label(unreadCount: Int, state: TimelineCaptureState) -> String {
        let unread = unreadPhrase(count: unreadCount)
        guard let suffix = stateSuffix(for: state) else {
            return unread
        }
        return String(localized: "\(unread), \(suffix)")
    }

    // MARK: Private

    /// The `1` and default branches look like they should collapse into one
    /// `^[\(count) unread notification](inflect: true)` call — the same markup
    /// ``StatusSettingsView`` and ``ImportProgressView`` already use. They stay apart:
    /// this package's tests have no host bundle for a catalog entry to resolve
    /// against (the same trade ``UndoToastView/message(count:)`` and
    /// ``ExportSheet/title(count:)`` document), and here that is not a silent
    /// no-op — verified by actually making the swap and running
    /// ``StatusItemAccessibilityTests``: `inflect: true` resolves in that
    /// environment, but always to the *singular* noun, so "7 unread notifications"
    /// becomes "7 unread notification" for every count, not the literal markup and
    /// not the correct plural. That regresses VoiceOver's actual output, so the
    /// hand-written branch stays until the dedicated localization pass gives this
    /// package a catalog to resolve against.
    private static func unreadPhrase(count: Int) -> String {
        switch count {
        case ..<1:
            String(localized: "Backglance, no unread notifications")

        case 1:
            String(localized: "Backglance, 1 unread notification")

        case Archive.unreadBadgeCap...:
            String(localized: "Backglance, more than 99 unread notifications")

        default:
            String(localized: "Backglance, \(count) unread notifications")
        }
    }

    /// The state clause, or `nil` when capture is running and there is nothing
    /// to add. Degraded reasons stay generic here: the tooltip carries the
    /// capture layer's sentence, and a label read aloud on every focus is the
    /// wrong place for a paragraph.
    private static func stateSuffix(for state: TimelineCaptureState) -> String? {
        switch state {
        case .running:
            nil

        case .paused:
            String(localized: "capture paused")

        case .noFullDiskAccess:
            String(localized: "needs Full Disk Access")

        case .degraded:
            String(localized: "capture degraded")

        case .stopped:
            String(localized: "capture stopped")
        }
    }
}
