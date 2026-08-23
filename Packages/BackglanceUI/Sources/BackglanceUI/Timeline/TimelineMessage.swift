import Foundation

// MARK: - TimelineMessage

/// A short, content-free message worth surfacing outside any one row, drawn by
/// ``MessageToastView`` and cleared automatically a few seconds after it last changed.
///
/// Not `String?` alone: `TimelineView`'s auto-dismiss `.task(id:)` needs a value that
/// changes even when the same sentence is shown twice in a row — showing "Not in the
/// archive" for one bad link, then a second one right after, has to restart the clock
/// rather than let the second toast inherit whatever was left of the first's timer. `id`
/// is what makes that a fresh `.task` invocation each time, the same trick
/// ``TimelineStore/ScrollRequest`` uses for the same reason.
public struct TimelineMessage: Identifiable, Equatable, Sendable {
    // MARK: Lifecycle

    public init(text: String) {
        self.text = text
    }

    // MARK: Public

    public let id = UUID()
    public let text: String
}
