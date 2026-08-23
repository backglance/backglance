import BackglanceCore
import Foundation

// MARK: - PauseCopy

/// The words the pause menu and the status item's tooltip use.
///
/// In this package rather than in the app shell for the reason
/// ``StatusItemAccessibility`` gives: the menu is AppKit and lives next to the status
/// item, but the app target has no test bundle, and "paused until 09:00" is a sentence
/// that varies by clock, calendar and locale — exactly the kind of thing worth asserting
/// against.
///
/// See docs/features/PRIVACY_CONTROLS.md#pause-capture.
public enum PauseCopy {
    // MARK: Public

    /// The choices, in the order the menu offers them: shortest first, and "until I say"
    /// last, so the item that never ends by itself is the one furthest from the cursor.
    public static let choices: [PauseChoice] = [
        .fifteenMinutes, .oneHour, .untilTomorrow, .indefinitely,
    ]

    /// The parent item the four choices hang off.
    public static var pauseMenuTitle: String {
        String(
            localized: "Pause Capture",
            comment: "Menu item with a submenu of durations: temporarily stops archiving notifications"
        )
    }

    /// The single item that replaces the submenu while capture is paused.
    public static var resumeMenuTitle: String {
        String(localized: "Resume Capture", comment: "Menu item: starts archiving notifications again after a pause")
    }

    public static func menuTitle(for choice: PauseChoice) -> String {
        switch choice {
        case .fifteenMinutes:
            String(localized: "For 15 Minutes", comment: "Submenu item under Pause Capture: how long to pause")

        case .oneHour:
            String(localized: "For 1 Hour", comment: "Submenu item under Pause Capture: how long to pause")

        case .untilTomorrow:
            String(localized: "Until Tomorrow", comment: "Submenu item under Pause Capture: how long to pause")

        case .indefinitely:
            String(
                localized: "Until I Resume",
                comment: "Submenu item under Pause Capture: pause with no end time, until resumed by hand"
            )
        }
    }

    /// The tooltip clause for a paused status item — "capture paused until 09:00".
    ///
    /// A pause that ends today is named by its time alone; one that ends tomorrow or later
    /// carries its date too, because "paused until 00:00" on its own reads as a pause that
    /// has already ended. An indefinite pause names no time, since there is none to name.
    public static func pausedClause(
        until date: Date?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        guard let date else {
            return String(
                localized: "capture paused",
                comment: "Status item tooltip clause; deliberately lowercase, follows the app name in the tooltip"
            )
        }
        let when = deadlineText(for: date, now: now, calendar: calendar)
        return String(
            localized: "capture paused until \(when)",
            comment: "Status item tooltip clause; deliberately lowercase; placeholder is the time the pause ends"
        )
    }

    /// Just the time a pause ends — "17:00", or "23 Aug 17:00" when that is another day.
    ///
    /// Separate from ``pausedClause(until:now:calendar:)`` because the two places that name
    /// a deadline want different sentences around the same instant: the status item's
    /// tooltip has room for "Backglance — capture paused until 17:00", and the Privacy
    /// pane's row is already labelled "Capture" and only needs "Paused until 17:00".
    public static func deadlineText(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        date.formatted(deadlineStyle(for: date, now: now, calendar: calendar))
    }

    // MARK: Internal

    /// The format the clause names a deadline in.
    ///
    /// Built against the given calendar rather than left to the default, so the day the
    /// style decides to print and the day ``pausedClause(until:now:calendar:)`` compared
    /// against are the same day. Two time zones' worth of disagreement about that is how
    /// "until tomorrow" ends up printing today's date.
    /// Whether the clause has to say which day the pause ends on.
    ///
    /// One that ends today does not: the time alone is unambiguous, and shorter.
    static func namesTheDay(of date: Date, now: Date, calendar: Calendar) -> Bool {
        !calendar.isDate(date, inSameDayAs: now)
    }

    static func deadlineStyle(for date: Date, now: Date, calendar: Calendar) -> Date.FormatStyle {
        Date.FormatStyle(
            date: namesTheDay(of: date, now: now, calendar: calendar) ? .abbreviated : .omitted,
            time: .shortened,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
    }
}
