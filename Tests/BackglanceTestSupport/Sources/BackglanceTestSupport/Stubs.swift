import Foundation

/// Values every bundle needs when it builds a stub notification, a stub app record or a
/// stub store row, kept in one place so two suites cannot disagree about what "the Slack
/// app" or "an hour ago" means.
///
/// Nothing here is real: the bundle identifiers are Apple's own published ones or obvious
/// placeholders, and no title, body or code is ever hard-coded — those come from
/// ``SplitMix64`` at run time.
public enum Stubs {
    /// Bundle identifiers the fixtures and unit tests use as senders.
    public enum BundleID {
        public static let messages = "com.apple.MobileSMS"
        public static let mail = "com.apple.mail"
        public static let calendar = "com.apple.iCal"
        public static let slack = "com.tinyspeck.slackmacgap"
        public static let unknown = "app.example.unknown"

        /// Every identifier above, in a stable order.
        public static let all = [messages, mail, calendar, slack, unknown]
    }

    /// The instant `TestClock` starts at: 2026-01-01 00:00:00 UTC. Fixed so a date-bucketing
    /// assertion reads the same in January as it does in July.
    public static let epoch = Date(timeIntervalSince1970: 1_767_225_600)

    /// A date relative to ``epoch``, for readable assertions: `Stubs.date(minutesAgo: 90)`.
    public static func date(minutesAgo minutes: Int) -> Date {
        epoch.addingTimeInterval(-Double(minutes) * 60)
    }
}
