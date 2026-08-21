import Foundation

// MARK: - DigestSection

/// One app's rows inside a digest, ready to render.
///
/// Ordered by where the app's best notification landed in `DigestEngine`'s ranking, so
/// a VIP's app leads the card: ``DigestViewModel`` groups without re-sorting, and the
/// order the engine chose is the order the card shows.
///
/// A top-level type rather than one nested in the `@MainActor` view model, so a preview,
/// a test, or `PreviewData` can build one without hopping to the main actor first — the
/// same reason ``TimelineItem`` sits beside ``TimelineStore`` instead of inside it.
public struct DigestSection: Identifiable, Equatable, Sendable {
    // MARK: Lifecycle

    public init(id: String, appName: String, bundleID: String?, items: [TimelineItem]) {
        self.id = id
        self.appName = appName
        self.bundleID = bundleID
        self.items = items
    }

    // MARK: Public

    /// The app's bundle identifier, falling back to its display name for a row whose
    /// app record has no bundle id. Unique within one digest, which is what `ForEach`
    /// needs of it.
    public let id: String

    public let appName: String
    public let bundleID: String?
    public let items: [TimelineItem]
}

// MARK: - DigestDayCount

/// How many notifications arrived on one local day of a multi-day away session — the
/// "Fri 34 · Sat 12 · Sun 41" line in ``DigestHeader``.
public struct DigestDayCount: Identifiable, Equatable, Sendable {
    // MARK: Lifecycle

    public init(id: Date, count: Int) {
        self.id = id
        self.count = count
    }

    // MARK: Public

    /// The start of the local day, which is also what makes each day unique in the
    /// header's `ForEach`.
    public let id: Date

    public let count: Int
}
