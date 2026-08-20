import BackglanceCore
import Foundation

// MARK: - TimelineSection

/// One day of the timeline, flattened into the exact sequence the list draws.
///
/// A namespace rather than a view: the *shape* of a day — where the unread
/// divider lands, which app headers appear, which rows are collapsed into
/// "Muted (n)" — is decided by `TimelineStore` and tested as a pure function.
/// `TimelineSectionView` (Phase 2.2) only walks the result.
public enum TimelineSection {
    // MARK: - Model

    /// A day header plus everything under it.
    public struct Model: Identifiable, Equatable, Sendable {
        // MARK: Lifecycle

        public init(id: Date, title: String, slots: [Slot], mutedItems: [TimelineItem] = []) {
            self.id = id
            self.title = title
            self.slots = slots
            self.mutedItems = mutedItems
        }

        // MARK: Public

        /// The day's start, in the user's calendar and time zone at render time.
        public let id: Date

        /// "Today", "Yesterday", "Monday, 11 Aug", "11 August 2026" — see ``DayTitle``.
        public let title: String

        /// Divider, app headers and rows in draw order. One flat array so
        /// `LazyVStack` instantiates only what is on screen.
        public let slots: [Slot]

        /// The rows this day hides behind its collapsed "Muted (n)" group.
        ///
        /// Carried rather than dropped: muting is presentation, and a group the
        /// user expands has to have something to show. They stay out of
        /// ``slots`` so the collapsed case — the common one — costs nothing.
        public let mutedItems: [TimelineItem]

        /// How many rows the muted group holds. Zero when the day has none.
        public var mutedCount: Int {
            mutedItems.count
        }

        /// The rows in this day, skipping headers and the divider — what ↑/↓
        /// selection moves through.
        public var items: [TimelineItem] {
            slots.compactMap { slot in
                if case let .row(item) = slot {
                    item
                } else {
                    nil
                }
            }
        }
    }

    // MARK: - Slot

    /// One drawable position in a day.
    public enum Slot: Identifiable, Equatable, Sendable {
        /// "new since you were away", before the first row at or below the anchor.
        case divider

        /// An app group's header — by-app grouping, or the collapsed muted group.
        case appHeader(AppGroup)

        /// A notification.
        case row(TimelineItem)

        // MARK: Public

        /// Stable across refreshes so `ForEach` diffs rather than rebuilds. Rows
        /// key on the archive id; the two header kinds cannot collide with it
        /// because their ids are strings.
        public var id: String {
            switch self {
            case .divider:
                "divider"

            case let .appHeader(group):
                "app:\(group.id)"

            case let .row(item):
                "row:\(item.id)"
            }
        }
    }

    // MARK: - AppGroup

    /// The header for a run of rows from one app, or for a day's muted rows.
    public struct AppGroup: Identifiable, Equatable, Sendable {
        // MARK: Lifecycle

        public init(id: String, name: String, count: Int, isMuted: Bool = false, bundleID: String? = nil) {
            self.id = id
            self.name = name
            self.count = count
            self.isMuted = isMuted
            self.bundleID = bundleID
        }

        // MARK: Public

        /// Unique within its day: the bundle id for an app group, `"muted"` for
        /// the collapsed group.
        public let id: String
        public let name: String
        public let count: Int

        /// The trailing "Muted (n)" group, collapsed by default and excluded
        /// from the unread badge.
        public let isMuted: Bool

        public let bundleID: String?
    }
}
