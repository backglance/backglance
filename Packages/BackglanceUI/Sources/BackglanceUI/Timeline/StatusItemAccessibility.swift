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

    /// The singular/plural of the exact-count phrase lives in the catalog entry's
    /// plural variations, per docs/reference/INTERNATIONALIZATION.md#plural-rules;
    /// the zero and above-cap phrases are their own keys because they are different
    /// sentences, not grammatical variants of this one.
    ///
    /// Nothing in this package can see the variations render: these tests have no host
    /// bundle, so `Bundle.main` is the xctest runner and every lookup falls back to
    /// the key — which is why a first conversion once shipped the singular to
    /// VoiceOver with eight green tests. The rendered forms are asserted where they
    /// can be: `PluralRenderingTests` in `BackglanceAppUITests` reads this label off
    /// the running app's status item for a count of 1 and of 3.
    private static func unreadPhrase(count: Int) -> String {
        switch count {
        case ..<1:
            String(
                localized: "Backglance, no unread notifications",
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
                comment: "Spoken by VoiceOver for the menu bar item; count pluralized by the catalog (1–99)"
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
