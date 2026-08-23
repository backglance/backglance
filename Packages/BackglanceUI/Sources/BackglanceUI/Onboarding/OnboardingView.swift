import SwiftUI

// MARK: - OnboardingView

/// The onboarding window's frame: one screen at a time, and the footer that moves between
/// them.
///
/// The footer is fixed while the content changes, which is the reason for the split. Setup
/// asks for something unusual — permission to read every notification the Mac receives — and
/// a window whose buttons move around while it does that reads as evasive. Back, Skip and
/// Continue stay exactly where they were on every screen.
///
/// See docs/features/PERMISSIONS_PRIVACY.md#onboardingview-state-machine.
public struct OnboardingView: View {
    // MARK: Lifecycle

    public init(model: OnboardingModel) {
        self.model = model
    }

    // MARK: Public

    /// The window's fixed size. Setup is not resizable: every screen is written to fit it.
    public static let windowSize = CGSize(width: 640, height: 480)

    public var body: some View {
        VStack(spacing: 0) {
            OnboardingStepView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)

            Divider()
            footer
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        // `children: .contain` is load-bearing, not decoration. Without it an identifier on
        // a container is applied to everything inside it, and the outermost application
        // wins: the step group, Back, Skip and Continue all came back as
        // "onboarding.window", which is every identifier `OnboardingFDATests` drives the
        // flow by. Same pairing as `ExportSheet` and `FDABanner`
        // (docs/reference/ACCESSIBILITY.md#identifiers-for-ui-tests).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.window")
    }

    // MARK: Private

    @Bindable private var model: OnboardingModel

    private var continueTitle: String {
        model.step == .done
            ? String(localized: "Open Backglance")
            : String(localized: "Continue")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.canGoBack {
                Button(String(localized: "Back")) { model.back() }
                    .accessibilityIdentifier("onboarding.back")
            }

            Spacer()

            if model.canSkip {
                Button(String(localized: "Skip for now")) { model.skip() }
                    .buttonStyle(.link)
                    // Said plainly, because skipping is a supported outcome and someone
                    // hesitating over it deserves to know it is not a dead end.
                    .accessibilityHint(Text(String(
                        localized: "Closes setup. You can grant Full Disk Access later from Settings."
                    )))
                    .accessibilityIdentifier("onboarding.skip")
            }

            Button(continueTitle) { model.next() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canContinue)
                .accessibilityIdentifier("onboarding.continue")
        }
        .padding(16)
    }
}

// MARK: - OnboardingStepView

/// Whichever screen the step names.
///
/// Its own view rather than a `switch` inside ``OnboardingView`` so the frame and the screens
/// stay separable: the frame is navigation, and the screens are copy.
struct OnboardingStepView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        switch model.step {
        case .welcome:
            WelcomeStep()

        case .whyFDA:
            WhyFDAStep()

        case .whatWeRead:
            WhatWeReadStep()

        case .grant:
            GrantStep(model: model)

        case .done:
            DoneStep(model: model)
        }
    }
}

#Preview {
    OnboardingView(model: OnboardingModel(fdaState: .denied))
}
