import Foundation

// MARK: - PauseChoice

/// The four ways a user can say "stop reading the store".
///
/// Four fixed choices rather than a duration picker, because pausing is something people
/// reach for mid-sentence — a screen share is starting, a stranger is at the desk — and a
/// menu that asks how many minutes is a menu nobody uses in that moment. The four cover
/// what the moments actually are: the length of a demo, the length of a meeting, the rest
/// of today, and "I will say when".
///
/// Raw values are the vocabulary of `backglance://pause` (Phase 4.3) as much as of the
/// menu, so they are spelled as durations rather than as Swift case names.
///
/// See docs/features/PRIVACY_CONTROLS.md#pause-capture.
public enum PauseChoice: String, CaseIterable, Hashable, Sendable {
    case fifteenMinutes = "15m"
    case oneHour = "1h"
    case untilTomorrow = "tomorrow"
    case indefinitely

    // MARK: Public

    /// When capture resumes by itself, or `nil` for a pause that only the user ends.
    ///
    /// `untilTomorrow` walks the calendar rather than adding 86,400 seconds: on the two
    /// days a year that a day is not 24 hours long, "until tomorrow" still means the next
    /// local midnight, and adding a fixed interval would land an hour either side of it.
    public func deadline(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .fifteenMinutes:
            now.addingTimeInterval(15 * 60)

        case .oneHour:
            now.addingTimeInterval(60 * 60)

        case .untilTomorrow:
            calendar.date(byAdding: .day, value: 1, to: now).map { calendar.startOfDay(for: $0) }

        case .indefinitely:
            nil
        }
    }
}
