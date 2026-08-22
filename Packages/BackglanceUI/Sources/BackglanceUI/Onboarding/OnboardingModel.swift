import BackglanceCore
import Foundation
import Observation

// MARK: - OnboardingModel

/// Which screen is showing, and everything that decides when it changes.
///
/// The one screen with real logic behind it is Grant, and the logic exists because of a fact
/// about macOS: **there is no API to request Full Disk Access.** Unlike Notifications or
/// Camera, TCC has no prompt for `SystemPolicyAllFiles`. An app can only detect the state and
/// point at System Settings, which means every "Allow" button in Backglance is really a
/// button that opens another app — and the screen the user comes back to has to have noticed
/// on its own. That is the whole reason this model watches rather than asks.
///
/// It works in mirrored types and closures rather than in `CaptureEngine` and
/// `FullDiskAccessProbe`, because `BackglanceUI` cannot see `BackglanceCapture`
/// (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction). The app shell owns the
/// wiring; this owns the sequence.
///
/// See docs/features/PERMISSIONS_PRIVACY.md#onboardingview-state-machine.
@MainActor
@Observable
public final class OnboardingModel {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - fdaState: where setup starts from. The app shell probes before building this.
    ///   - openSystemSettings: opens the Full Disk Access pane. Returns `false` when the deep
    ///     link did not open, which is what makes the screen show the manual path instead of
    ///     leaving the user staring at nothing.
    ///   - checkAccessAgain: re-probes on demand. The manual escape hatch behind "Check
    ///     again", for the case where activation and the poll both somehow miss.
    ///   - defaults: where "setup is done" and "the user skipped" are recorded.
    public init(
        fdaState: FullDiskAccessDisplayState,
        openSystemSettings: @escaping () -> Bool = { false },
        checkAccessAgain: @escaping () -> Void = {},
        defaults: UserDefaults = .standard
    ) {
        self.fdaState = fdaState
        self.openSystemSettings = openSystemSettings
        self.checkAccessAgain = checkAccessAgain
        self.defaults = defaults
        step = Self.startingStep(fdaState: fdaState, defaults: defaults)
    }

    // MARK: Public

    /// The onboarding flow's own version. Bumped when the screens change enough that someone
    /// who completed the old one should be shown the new one.
    public static let currentVersion = 1

    public static let completedVersionKey = "onboarding.completedVersion"
    public static let skippedFDAKey = "onboarding.skippedFDA"

    /// How long after opening System Settings without a grant before the screen suggests the
    /// thing that usually fixes it.
    public static let relaunchHintDelay: TimeInterval = 10

    /// Which screen is showing.
    public private(set) var step: OnboardingStep

    /// The last answer from the probe. Written by the app shell whenever the monitor's
    /// changes, and by ``checkAgain()``.
    public private(set) var fdaState: FullDiskAccessDisplayState

    /// Whether to show the "if the switch is on and this still says no, quit and reopen
    /// Backglance" hint.
    ///
    /// macOS applies a new Full Disk Access grant to a *running* process inconsistently, and a
    /// relaunch always works. The hint is delayed rather than shown up front because saying it
    /// immediately would teach everyone to relaunch when most people never need to.
    public private(set) var showsRelaunchHint = false

    /// Whether the user has been sent to System Settings at least once, so the Grant screen
    /// can stop leading with the button they already pressed.
    public private(set) var didOpenSystemSettings = false

    /// Whether setup ended with Full Disk Access still ungranted.
    public private(set) var didSkip = false

    /// Whether the flow has finished, either way.
    public private(set) var isFinished = false

    /// How the first-launch import is going. Written by the app shell as the engine reports.
    public private(set) var importProgress: ImportState = .idle

    /// Begins the first-launch import. Called once, on reaching the last screen, and only
    /// when access was actually granted.
    ///
    /// Set after init rather than passed to it, because the controller that runs the import
    /// is the one that builds this — the two would otherwise have to be constructed in an
    /// order neither can satisfy.
    public var onStartImport: (() -> Void)?

    /// Closes the window. The controller's, because a model that closed its own window would
    /// need to know it had one.
    public var onFinish: (() -> Void)?

    /// Whether Continue should be enabled.
    ///
    /// Grant is the only gate, and it is a real one: continuing from there without access
    /// would take the user to a screen that says setup is done, on a Mac where capture cannot
    /// run. "Skip for now" is the honest way past it, and it is on every screen.
    public var canContinue: Bool {
        step != .grant || fdaState.isGranted
    }

    /// Whether Back should be offered. Not on the first screen, and not on the last: the last
    /// one has already started the import, and stepping back from it would offer to grant
    /// access that has been granted.
    public var canGoBack: Bool {
        step.previous != nil && step != .done
    }

    /// Whether "Skip for now" should be offered. Not on the last screen, where there is
    /// nothing left to skip.
    public var canSkip: Bool {
        step != .done
    }

    /// Whether this Mac has completed setup at the current version.
    public static func isComplete(defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: completedVersionKey) >= currentVersion
    }

    /// Where "Show setup again" resumes.
    ///
    /// Not always screen one. Someone returning because the banner is still there does not
    /// need the welcome again — they need the screen that explains why, or, if access is
    /// already granted and only the import never ran, the last one.
    public static func startingStep(
        fdaState: FullDiskAccessDisplayState,
        defaults: UserDefaults = .standard
    ) -> OnboardingStep {
        guard isComplete(defaults: defaults) else {
            return .welcome
        }
        return fdaState.isGranted ? .done : .whyFDA
    }

    /// Advances, or finishes from the last screen.
    public func next() {
        switch step {
        case .grant:
            guard fdaState.isGranted else {
                return
            }
            advance(to: .done)

        case .done:
            finish(skipped: false)

        case .welcome,
             .whatWeRead,
             .whyFDA:
            guard let next = step.next else {
                return
            }
            advance(to: next)
        }
    }

    public func back() {
        guard canGoBack, let previous = step.previous else {
            return
        }
        step = previous
    }

    /// Ends setup without Full Disk Access.
    ///
    /// Skipping is a supported outcome, not a failure: Backglance without capture still shows
    /// everything already archived, and someone evaluating the app is entitled to look around
    /// before granting it the ability to read every notification they receive. The banner is
    /// the only follow-up — there is no reminder, and no second sheet.
    public func skip() {
        finish(skipped: true)
    }

    /// Records the outcome for a window that was closed some other way.
    ///
    /// The red button is a legitimate way out — the same one "Skip for now" takes — so it
    /// records the same thing. A window dismissed without recording anything would reopen on
    /// the next launch, which reads as the app not listening. A no-op once the flow has
    /// finished, so the normal close does not run this twice.
    public func skipIfUnfinished() {
        guard !isFinished else {
            return
        }
        finish(skipped: true)
    }

    /// Opens System Settings, and starts the clock on the relaunch hint.
    public func openFullDiskAccessSettings() {
        didOpenSystemSettings = true
        openedSettingsAt = Date()
        _ = openSystemSettings()
    }

    /// Re-probes now.
    ///
    /// The screen watches for the grant on its own, so this button should never be needed —
    /// which is exactly why it is there. A user who has flipped the switch and is looking at
    /// a screen that still says "waiting" needs something to press that is not "Skip".
    public func checkAgain() {
        checkAccessAgain()
    }

    /// Records how the import is going.
    public func importProgressChanged(to progress: ImportState) {
        importProgress = progress
    }

    /// Records a fresh probe result.
    ///
    /// Called by the app shell on activation and on each poll tick, and by the screen's
    /// "Check again" button. Reaching `.granted` on the Grant screen advances by itself: the
    /// user is looking at another app's window when it happens, and coming back to a screen
    /// that has moved on is the confirmation that the thing they did worked.
    public func fullDiskAccessChanged(to state: FullDiskAccessDisplayState) {
        let wasGranted = fdaState.isGranted
        fdaState = state

        if let openedAt = openedSettingsAt, !state.isGranted {
            showsRelaunchHint = Date().timeIntervalSince(openedAt) >= Self.relaunchHintDelay
        } else {
            showsRelaunchHint = false
        }

        if state.isGranted, !wasGranted, step == .grant {
            advance(to: .done)
        }
    }

    // MARK: Private

    private let openSystemSettings: () -> Bool
    private let checkAccessAgain: () -> Void
    private let defaults: UserDefaults

    private var openedSettingsAt: Date?
    private var didStartImport = false

    private func advance(to next: OnboardingStep) {
        step = next
        guard next == .done else {
            return
        }
        // Only here, and only once. The import reads every notification Apple's store still
        // holds, which is exactly the thing the user has just agreed to — and exactly the
        // thing they have not agreed to if they arrived at this screen some other way.
        guard fdaState.isGranted, !didStartImport else {
            return
        }
        didStartImport = true
        onStartImport?()
    }

    private func finish(skipped: Bool) {
        defaults.set(Self.currentVersion, forKey: Self.completedVersionKey)
        // "Skipped" means skipped *the grant*. Someone who clicked Skip on the last screen
        // with access already granted has not skipped anything, and the banner should not
        // treat them as though they had.
        didSkip = skipped && !fdaState.isGranted
        defaults.set(didSkip, forKey: Self.skippedFDAKey)
        isFinished = true
        onFinish?()
    }
}
