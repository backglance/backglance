import BackglanceCore
import Foundation
import Observation

// MARK: - PrivacySettingsModel

/// What the Privacy pane needs beyond the four models it composes.
///
/// Composition rather than ownership: retention, exclusions and redaction each already have
/// a model and a `Section`-returning view, and this holds them rather than reimplementing
/// their state. What is left is the handful of things that belong to the pane itself — the
/// redaction activity table, the pause row, revealing the archive in Finder, and the sheet
/// that can destroy everything.
///
/// The pause row reads `UserDefaults` rather than the engine. `BackglanceUI` cannot see
/// `BackglanceCapture` (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction), and
/// it does not need to: the pause state is persisted precisely so it survives a relaunch, so
/// the stored value is the same answer the engine would give.
///
/// See docs/features/PRIVACY_CONTROLS.md#ui-components.
@MainActor
@Observable
public final class PrivacySettingsModel {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - archive: where the redaction counts come from. `nil` leaves the table empty.
    ///   - retention: the Retention section's model.
    ///   - exclusions: the Excluded Apps section's model.
    ///   - redaction: the code-redaction section's model.
    ///   - wipe: the confirmation sheet's model.
    ///   - resumeCapture: what the pause row's Resume button calls. Supplied by the app
    ///     shell, which owns the engine.
    ///   - defaults: where the pause state and the import-while-paused switch live.
    public init(
        archive: Archive?,
        retention: RetentionSettingsModel,
        exclusions: ExcludedAppsSettingsModel,
        redaction: CodeRedactionSettingsModel,
        wipe: WipeConfirmationModel,
        resumeCapture: @escaping @Sendable () async -> Void = {},
        defaults: UserDefaults = .standard
    ) {
        self.archive = archive
        self.retention = retention
        self.exclusions = exclusions
        self.redaction = redaction
        self.wipe = wipe
        self.resumeCapture = resumeCapture
        self.defaults = defaults
        pauseState = PauseSettings(defaults: defaults).state
        importWhilePaused = PauseSettings(defaults: defaults).importWhilePaused
    }

    // MARK: Public

    /// How far back the redaction activity table looks.
    public static let activityWindow: TimeInterval = 60 * 60 * 24 * 30

    public let retention: RetentionSettingsModel
    public let exclusions: ExcludedAppsSettingsModel
    public let redaction: CodeRedactionSettingsModel
    public let wipe: WipeConfirmationModel

    /// Redaction counts per app over the last thirty days, busiest first. Counts only.
    public private(set) var activity: [RedactionActivity] = []

    /// Set when a read did not go through, so the pane can say the table is not reflecting
    /// anything rather than sit there looking like a well-earned zero.
    public private(set) var failure: String?

    /// Whether capture is paused, and until when. Re-read on appearance, because the status
    /// item's menu can change it while this window is open.
    public private(set) var pauseState: PauseState

    /// Whether resuming backfills what arrived during a pause. Written straight through:
    /// `CaptureEngine.resume()` reads it fresh, so there is no apply step to forget.
    public var importWhilePaused: Bool {
        didSet {
            guard importWhilePaused != oldValue else {
                return
            }
            PauseSettings.save(importWhilePaused: importWhilePaused, to: defaults)
        }
    }

    /// Whether the redaction table has anything to say yet.
    ///
    /// An empty table is a real answer, not a missing one — "nothing has looked like a code
    /// in thirty days" — so the pane says that rather than hiding the section.
    public var hasActivity: Bool {
        !activity.isEmpty
    }

    /// Where the archive lives, for the Reveal in Finder button. `nil` for an in-memory
    /// archive, which has no folder to show.
    public var archiveDirectory: URL? {
        archive?.location.fileURL?.deletingLastPathComponent()
    }

    /// Reads everything the pane owns, and asks each composed model to read its own.
    public func load() async {
        pauseState = PauseSettings(defaults: defaults).state
        importWhilePaused = PauseSettings(defaults: defaults).importWhilePaused
        await loadActivity()
    }

    /// Ends a pause from the pane, rather than from the status item's menu.
    public func resume() async {
        await resumeCapture()
        pauseState = PauseSettings(defaults: defaults).state
    }

    // MARK: Private

    private let archive: Archive?
    private let resumeCapture: @Sendable () async -> Void
    private let defaults: UserDefaults

    private func loadActivity() async {
        guard let archive else {
            activity = []
            return
        }
        do {
            activity = try archive.redactionActivity(since: Date().addingTimeInterval(-Self.activityWindow))
            failure = nil
        } catch {
            activity = []
            failure = (error as? ArchiveError)?.userMessage ?? String(localized: "Couldn’t read redaction activity.")
        }
    }
}
