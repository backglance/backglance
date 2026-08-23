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
        return String(
            localized: "\(unread), \(suffix)",
            comment: "Spoken by VoiceOver for the menu bar item: the unread phrase, then the capture-state clause"
        )
    }

    // MARK: Private

    /// The `1` and default branches look like they should collapse into one
    /// interpolated call with the plural in the catalog entry — which is what
    /// ``StatusSettingsView`` and ``ImportProgressView`` now do, and what
    /// docs/reference/INTERNATIONALIZATION.md#plural-rules asks for. They stay apart for
    /// now because nothing in this package can prove the result: these tests have no host
    /// bundle, so `Bundle.main` is the xctest runner and every lookup falls back to the
    /// key (the same trade ``UndoToastView/message(count:)`` and ``ExportSheet/title(count:)``
    /// document). What was verified, by making the swap and running
    /// ``StatusItemAccessibilityTests``, is that the fallback answers with whichever
    /// literal the key holds — so a test here would be asserting the key, not the plural.
    ///
    /// The mechanism itself does work in the built app: BACKGLANCE-248 proved catalog
    /// plurals render correctly for both branches, `^[…](inflect: true)` does not, and
    /// `OnboardingFDATests` now checks one of them against the running app. Converting
    /// these three sites is a follow-up, and it needs a UI test to come with it — an
    /// unverified conversion is how the singular got shipped to VoiceOver the first time.
    private static func unreadPhrase(count: Int) -> String {
        switch count {
        case ..<1:
            String(
                localized: "Backglance, no unread notifications",
                comment: "Spoken by VoiceOver for the menu bar item; Backglance is the app name, do not translate it"
            )

        case 1:
            String(
                localized: "Backglance, 1 unread notification",
                comment: "Spoken by VoiceOver for the menu bar item; Backglance is the app name, do not translate it"
            )

        case Archive.unreadBadgeCap...:
            String(
                localized: "Backglance, more than 99 unread notifications",
                comment: "Spoken by VoiceOver for the menu bar item; Backglance is the app name, do not translate it"
            )

        default:
            String(
                localized: "Backglance, \(count) unread notifications",
                comment: "Spoken by VoiceOver for the menu bar item; placeholder is the unread count (always 2–99)"
            )
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
            String(
                localized: "capture paused",
                comment: "Spoken by VoiceOver after the unread phrase; deliberately lowercase mid-sentence clause"
            )

        case .noFullDiskAccess:
            String(
                localized: "needs Full Disk Access",
                comment: "Spoken by VoiceOver after the unread phrase; deliberately lowercase mid-sentence clause"
            )

        case .degraded:
            String(
                localized: "capture degraded",
                comment: "Spoken by VoiceOver after the unread phrase; deliberately lowercase mid-sentence clause"
            )

        case .stopped:
            String(
                localized: "capture stopped",
                comment: "Spoken by VoiceOver after the unread phrase; deliberately lowercase mid-sentence clause"
            )
        }
    }
}
