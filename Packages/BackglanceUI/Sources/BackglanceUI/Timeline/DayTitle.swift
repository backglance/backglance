import Foundation

// MARK: - DayTitle

/// The one place a day header's text is decided.
///
/// Recency is what the user is reading for, so the format tightens as the day
/// gets closer: "Today" and "Yesterday" need no date at all, the last week reads
/// better by weekday ("Monday, 11 Aug"), and older days get the full date. One
/// function, so the popover and the window can never disagree — and so the
/// thresholds can be tested against a frozen `now` in several locales.
///
/// Calendar and time zone are parameters rather than `.current` reads inside, so
/// a test can pin them and the timeline can regroup when the system's change
/// while a window is open (docs/features/TIMELINE.md#edge-cases-and-error-handling).
public enum DayTitle {
    /// The header for a day, given the calendar it was bucketed in.
    ///
    /// - Parameters:
    ///   - day: the day's start, as produced by `Calendar.startOfDay(for:)`.
    ///   - calendar: the user's calendar; its `timeZone` decides where a day ends.
    ///   - now: today, injectable so the "within the last week" threshold is testable.
    public static func string(for day: Date, calendar: Calendar = .current, now: Date = .now) -> String {
        if calendar.isDate(day, inSameDayAs: now) {
            return String(localized: "Today")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(day, inSameDayAs: yesterday)
        {
            return String(localized: "Yesterday")
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        // The calendar carries the locale so a caller that pins one — a test, or
        // a future per-window override — pins the formatting with it.
        formatter.locale = calendar.locale ?? .autoupdatingCurrent
        // Six days back, not seven: a week ago today would print the same weekday
        // as today, which reads as "this coming Monday" rather than "last Monday".
        let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
        let withinWeek = weekAgo.map { day >= $0 } ?? false
        formatter.setLocalizedDateFormatFromTemplate(withinWeek ? "EEEE d MMM" : "d MMMM y")
        return formatter.string(from: day)
    }
}
