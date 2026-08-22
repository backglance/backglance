import Foundation

// MARK: - PauseState

/// Whether capture is paused, and until when.
///
/// Three states rather than an optional `Date`, because `nil` would have to mean both
/// "not paused" and "paused with no end" — the two conditions a pause has to keep apart.
///
/// Stored as one `Double` under ``PauseSettings/pausedUntilKey``: `0` for not paused, `-1`
/// for indefinitely, and a Unix timestamp otherwise. That encoding is documented in
/// docs/features/PRIVACY_CONTROLS.md#where-settings-live and is what `backglance://pause`
/// will read in Phase 4.3, so it is a format rather than an implementation detail.
public enum PauseState: Equatable, Sendable {
    case notPaused
    case indefinite
    case until(Date)

    // MARK: Lifecycle

    /// Decodes the stored `Double`.
    ///
    /// Anything negative reads as indefinite, not just exactly `-1`: a preference file
    /// edited by hand or written by a future build should fail towards *more* pausing,
    /// since the failure that matters here is capturing something the user asked not to
    /// capture.
    public init(storedValue: Double) {
        if storedValue < 0 {
            self = .indefinite
        } else if storedValue > 0 {
            self = .until(Date(timeIntervalSince1970: storedValue))
        } else {
            self = .notPaused
        }
    }

    // MARK: Public

    public var storedValue: Double {
        switch self {
        case .notPaused: 0
        case .indefinite: -1
        case let .until(date): date.timeIntervalSince1970
        }
    }

    /// The end time an engine schedules its automatic resume against, or `nil` when there
    /// is nothing to schedule.
    public var deadline: Date? {
        switch self {
        case let .until(date): date
        case .indefinite,
             .notPaused: nil
        }
    }

    public var isPaused: Bool {
        self != .notPaused
    }

    /// What this state means *now*.
    ///
    /// A pause whose end time has passed — while Backglance was quit, most often — is over,
    /// and reads as `.notPaused`. The caller still has to know it *was* a pause, which is
    /// why this returns a new value rather than mutating: `start()` compares the two to
    /// decide whether resuming has a gap to skip.
    public func resolved(at now: Date) -> PauseState {
        guard case let .until(date) = self, date <= now else {
            return self
        }
        return .notPaused
    }
}

// MARK: - PauseSettings

/// The pause state and what resuming does with the gap.
///
/// In `UserDefaults` rather than the archive, for the same reason as retention and
/// redaction: these are facts about this Mac's preferences, not about the notifications,
/// and a wipe must not quietly un-pause capture.
///
/// Read fresh at each use — there is no cached copy to go stale between the menu that
/// writes it and the engine that reads it.
///
/// See docs/features/PRIVACY_CONTROLS.md#pause-capture.
public struct PauseSettings: Sendable, Equatable {
    // MARK: Lifecycle

    public init(state: PauseState, importWhilePaused: Bool = false) {
        self.state = state
        self.importWhilePaused = importWhilePaused
    }

    public init(defaults: UserDefaults = .standard) {
        self.init(
            state: PauseState(storedValue: defaults.double(forKey: Self.pausedUntilKey)),
            importWhilePaused: defaults.bool(forKey: Self.importWhilePausedKey)
        )
    }

    // MARK: Public

    public static let pausedUntilKey = "capture.pausedUntil"
    public static let importWhilePausedKey = "capture.importWhilePaused"

    /// Whether capture is paused, and until when. Survives relaunch.
    public let state: PauseState

    /// Whether resuming backfills what was delivered during the pause.
    ///
    /// Off by default, and the default is the whole point: a pause is a gap in the archive,
    /// not a delay in it. Turning this on is right for "I paused to give a talk and still
    /// want the record" and wrong for "I paused because I did not want a record", which is
    /// why the Privacy pane says so in a sentence next to the toggle rather than leaving
    /// the label to carry it.
    public let importWhilePaused: Bool

    public static func save(state: PauseState, to defaults: UserDefaults) {
        defaults.set(state.storedValue, forKey: pausedUntilKey)
    }

    public static func save(importWhilePaused: Bool, to defaults: UserDefaults) {
        defaults.set(importWhilePaused, forKey: importWhilePausedKey)
    }
}
