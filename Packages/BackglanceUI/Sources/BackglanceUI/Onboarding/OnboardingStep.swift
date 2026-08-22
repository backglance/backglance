import Foundation

// MARK: - OnboardingStep

/// The five screens, in order.
///
/// Ordered by `rawValue` so Back is arithmetic rather than another switch that can disagree
/// with Next. Starting at 1 keeps "step 2 of 5" honest without an off-by-one everywhere it
/// is shown.
///
/// See docs/features/PERMISSIONS_PRIVACY.md#onboardingview-state-machine.
public enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome = 1
    case whyFDA
    case whatWeRead
    case grant
    case done

    // MARK: Public

    public var id: Int {
        rawValue
    }

    /// The step before this one, or `nil` at the start.
    public var previous: OnboardingStep? {
        OnboardingStep(rawValue: rawValue - 1)
    }

    /// The step after this one, or `nil` at the end.
    public var next: OnboardingStep? {
        OnboardingStep(rawValue: rawValue + 1)
    }
}

// MARK: - FullDiskAccessDisplayState

/// What onboarding, the banner and the Permissions pane need to know about Full Disk Access.
///
/// A deliberate mirror of `BackglanceCapture.FullDiskAccessState` rather than an import of
/// it, for the reason ``TimelineCaptureState`` gives: `BackglanceUI` must not depend on the
/// capture layer (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction). The app
/// shell owns the mapping.
public enum FullDiskAccessDisplayState: Equatable, Sendable {
    /// Backglance can read the store. Capture works.
    case granted

    /// TCC is refusing. The one state with a button that fixes it.
    case denied

    /// The store is not there. **Not** a permission problem — the copy for this state must
    /// not send anyone to System Settings.
    case storeMissing

    // MARK: Public

    public var isGranted: Bool {
        self == .granted
    }
}
