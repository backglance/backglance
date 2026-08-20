import Foundation

// MARK: - TimelineCaptureState

/// What capture is doing, as far as the timeline needs to know.
///
/// A deliberate mirror of `BackglanceCapture.CaptureStatus` rather than an
/// import of it: `BackglanceUI` must not depend on the capture layer
/// (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction), and the
/// views need far less than the engine's status carries — enough to pick an
/// empty state and write one banner sentence. The app shell owns the mapping.
public enum TimelineCaptureState: Equatable, Sendable {
    /// Watching the store and archiving.
    case running

    /// Deliberately not archiving; `until` is the automatic resume time, or
    /// `nil` for an indefinite pause. Nothing delivered while paused is ever
    /// archived, which is why the paused empty state says so.
    case paused(until: Date?)

    /// The one degraded reason the UI can actually fix, so it gets its own case
    /// and its own button.
    case noFullDiskAccess

    /// Any other degraded reason, already reduced to one content-free sentence
    /// by the capture layer.
    case degraded(message: String)

    /// The engine has not started yet, or has been stopped.
    case stopped

    // MARK: Public

    /// Whether the timeline should be showing a banner about capture at all.
    public var needsAttention: Bool {
        self != .running
    }
}

// MARK: - EmptyStateKind

/// Why the timeline has nothing to draw.
///
/// Four kinds, four different sentences, and — for three of them — a different
/// button. "Nothing here" is a very different message when Backglance has never
/// been allowed to read the store than when it simply has not seen a
/// notification yet; conflating them is how a permissions problem turns into a
/// bug report about an empty app.
///
/// Copy lives with `EmptyStateView`; this only decides which one applies. See
/// docs/features/TIMELINE.md#edge-cases-and-error-handling.
public enum EmptyStateKind: Equatable, Sendable {
    /// Degraded for want of Full Disk Access, and nothing archived earlier.
    case noFullDiskAccess

    /// Paused, with nothing archived since.
    case paused

    /// Running, but the archive is empty — a fresh install.
    case nothingYet

    /// Rows exist; the current filter or search matches none of them.
    case allFiltered
}
