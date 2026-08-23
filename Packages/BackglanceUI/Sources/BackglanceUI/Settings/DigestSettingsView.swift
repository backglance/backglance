import BackglanceCore
import SwiftUI

// MARK: - DigestSettingsView

/// Settings ▸ Digest: when a digest appears, which kinds of away count, and whether it
/// also posts a banner.
///
/// The banner toggle is the one control in Backglance that can cause a permission prompt,
/// and it does so only when switched on. Everything else here is a plain preference.
///
/// See docs/features/MISSED_DIGEST.md#settings.
public struct DigestSettingsView: View {
    // MARK: Lifecycle

    public init(model: DigestSettingsModel) {
        self.model = model
    }

    // MARK: Public

    public var body: some View {
        @Bindable var model = model

        Section {
            Picker(
                String(localized: "Show digest", comment: "Picker label: when the missed digest appears"),
                selection: $model.threshold
            ) {
                ForEach(DigestThreshold.allCases, id: \.self) { threshold in
                    Text(Self.label(for: threshold)).tag(threshold)
                }
            }

            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.isDigestDisabled {
                reasons
                banner
            }
        } header: {
            Text(String(localized: "Digest", comment: "Section header: the missed-notifications digest"))
        }
        .task {
            // Catches a refusal made in System Settings since the last look, which is the
            // only way the answer changes without the user touching this pane.
            await model.refreshAuthorization()
        }
    }

    // MARK: Internal

    /// The threshold as the picker says it. `never` is spelled out rather than left as a
    /// bare word, because it is the one choice that switches a whole feature off.
    static func label(for threshold: DigestThreshold) -> String {
        switch threshold {
        case .always: String(localized: "Always", comment: "Picker option: show the digest after every away session")
        case .after5min: String(localized: "After 5 minutes away")
        case .after15min: String(localized: "After 15 minutes away")
        case .never: String(localized: "Never", comment: "Picker option: never show the digest")
        }
    }

    /// The reason as a noun, for a checkbox. `AwayReason.whileLabel` is the sentence
    /// fragment the card and the banner use; a list of checkboxes wants the other form.
    static func label(for reason: AwayReason) -> String {
        switch reason {
        case .locked: String(localized: "Locked", comment: "Checkbox: the screen was locked")
        case .asleep: String(localized: "Asleep or lid closed")
        case .focus: String(localized: "In a Focus", comment: "Checkbox; 'Focus' is the macOS feature name")
        case .presenting: String(localized: "Presenting or screen sharing")
        case .manual: String(localized: "Marked away by hand", comment: "Checkbox: user marked themselves away")
        }
    }

    // MARK: Private

    private let model: DigestSettingsModel

    /// Says what the setting does *and* what it does not do: away sessions keep being
    /// recorded whatever this says, which is what keeps `is:missed` honest and is exactly
    /// the thing someone reading "Never" would otherwise assume they had switched off.
    private var explanation: String {
        if model.isDigestDisabled {
            return String(localized: """
            No digests will be built or shown. Backglance still records when you were away, \
            so searching for what you missed keeps working.
            """)
        }
        return String(localized: """
        When you come back, Backglance shows one summary of what arrived while you were away — \
        once, and never again after you dismiss it.
        """)
    }

    private var reasons: some View {
        // Phrased as what counts, not what is excluded: a list of negatives is a list
        // people read backwards.
        LabeledContent(
            String(localized: "Count time away when", comment: "Label: the checkboxes below complete the sentence")
        ) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(AwayReason.allCases, id: \.self) { reason in
                    Toggle(
                        Self.label(for: reason),
                        isOn: Binding(
                            get: { model.counts(reason) },
                            set: { model.setCounts($0, for: reason) }
                        )
                    )
                    .accessibilityIdentifier("digest.reason.\(reason.rawValue)")
                }
            }
        }
    }

    @ViewBuilder private var banner: some View {
        @Bindable var model = model

        // A plain binding, deliberately: the model flips synchronously and undoes itself
        // if authorization is refused, so the switch visibly declines to stay on rather
        // than sitting off while the model says otherwise.
        Toggle(String(localized: "Also show a notification banner"), isOn: $model.bannerEnabled)
            .disabled(!model.canRequestBanners && !model.bannerEnabled)
            .accessibilityIdentifier("digest.banner.enabled")

        if model.bannerAuthorization == .denied {
            Text("Banners are off in System Settings ▸ Notifications ▸ Backglance.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.bannerEnabled {
            Toggle(
                String(localized: "Banner for Focus sessions", comment: "Toggle; 'Focus' is the macOS feature name"),
                isOn: $model.bannerForFocus
            )
            .accessibilityIdentifier("digest.banner.focus")
            Toggle(
                String(localized: "Play a sound", comment: "Toggle: the digest banner plays a sound"),
                isOn: $model.bannerSound
            )
            .accessibilityIdentifier("digest.banner.sound")
        }
    }
}

// MARK: - Previews

#Preview("Digest settings") {
    Form {
        DigestSettingsView(model: DigestSettingsModel(
            defaults: UserDefaults(suiteName: "app.backglance.preview.digest") ?? .standard,
            authorization: BannerAuthorizing(read: { .notDetermined }, request: { .authorized })
        ))
    }
    .formStyle(.grouped)
    .frame(width: 460)
}
