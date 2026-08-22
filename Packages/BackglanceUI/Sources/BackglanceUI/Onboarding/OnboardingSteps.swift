import SwiftUI

// MARK: - WelcomeStep

/// Screen 1. What the app is, and what it is going to ask for.
///
/// The permission is named on the first screen rather than sprung on the fourth. Someone who
/// is not going to grant Full Disk Access should find that out before spending a minute
/// reading, and someone who will should not feel it was worked up to.
struct WelcomeStep: View {
    var body: some View {
        OnboardingScreen(
            title: String(localized: "Backglance"),
            subtitle: String(localized: "The notification history macOS never had."),
            identifier: "onboarding.welcome"
        ) {
            Text(String(localized: """
            macOS deletes notifications the moment you dismiss them. Backglance keeps a private, \
            local archive so you can search what you missed — nothing leaves your Mac.
            """))

            Text(String(localized: "Setup takes about a minute and needs one permission."))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - WhyFDAStep

/// Screen 2. Why the permission is this large, said without apology.
///
/// Full Disk Access is an enormous thing to ask for, and the honest answer is that macOS
/// offers nothing narrower for this database. Saying so — including the part about the App
/// Store — is more persuasive than any reassurance, because it is checkable.
struct WhyFDAStep: View {
    var body: some View {
        OnboardingScreen(
            title: String(localized: "One permission: Full Disk Access"),
            identifier: "onboarding.whyFDA"
        ) {
            Text(String(localized: """
            Notification history lives in a system database that macOS protects. There is no narrower \
            permission and no API for it — Full Disk Access is the only way any app can read it. \
            This is also why Backglance is not in the Mac App Store.
            """))

            Text(String(localized: """
            Backglance is open source (GPL-3.0). You can read exactly what it opens, and watch it \
            with fs_usage if you like.
            """))
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - WhatWeReadStep

/// Screen 3. The complete list, both halves.
///
/// The "never" half is the point. Full Disk Access grants far more than Backglance uses, so
/// the only meaningful thing to say is what it does *not* touch — and to make that
/// verifiable rather than promised, which is what the previous screen's `fs_usage` line is
/// for.
struct WhatWeReadStep: View {
    // MARK: Internal

    var body: some View {
        OnboardingScreen(
            title: String(localized: "What Backglance reads"),
            identifier: "onboarding.whatWeRead"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Self.reads, id: \.self) { item in
                    Label(item, systemImage: "checkmark.circle")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(String(localized: "What Backglance never reads"))
                .font(.headline)
                .padding(.top, 4)

            Text(String(localized: """
            Mail, Messages, Safari, Photos, Documents, the keychain, or any other app’s data. \
            It makes no network connections except checking for updates, which you can turn off.
            """))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Private

    private static let reads: [String] = [
        String(localized: "The Notification Center database — copied read-only, never modified."),
        String(localized: "Two Focus files, to know when you were in a Focus."),
        String(localized: "App icons, through the standard NSWorkspace API."),
    ]
}

// MARK: - GrantStep

/// Screen 4. The only screen that waits for something.
///
/// It waits because it has to: there is no API to request Full Disk Access, so the button
/// below opens another app and this screen's job is to notice when the user comes back. That
/// is also why "Check again" exists next to it — a manual escape hatch for the case where the
/// watching does not fire, so nobody is ever stuck looking at a screen that seems wrong.
struct GrantStep: View {
    // MARK: Internal

    @Bindable var model: OnboardingModel

    var body: some View {
        OnboardingScreen(
            title: String(localized: "Grant Full Disk Access"),
            identifier: "onboarding.grant"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(Self.instructions.enumerated()), id: \.offset) { index, line in
                    Text(verbatim: "\(index + 1). \(line)")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            status
            buttons

            if model.showsRelaunchHint {
                Text(String(localized: """
                macOS sometimes needs the app to restart after granting. Your setup progress is saved.
                """))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onboarding.grant.relaunchHint")
            }

            Text(String(localized: """
            Backglance can’t request this permission for you; macOS only lets apps point you to the setting.
            """))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Private

    private static let instructions: [String] = [
        String(localized: "Click Open System Settings below."),
        String(localized: """
        Turn on the switch next to Backglance. If it isn’t listed, click + and choose it from Applications.
        """),
        String(localized: "Come back here — this screen updates by itself."),
    ]

    @ViewBuilder private var status: some View {
        switch model.fdaState {
        case .granted:
            Label(String(localized: "Granted, thanks!"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("onboarding.grant.status.granted")

        case .denied:
            Label(String(localized: "Waiting for permission…"), systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("onboarding.grant.status.waiting")

        case .storeMissing:
            // Not a permission problem, so this must not read like one. The switch is
            // irrelevant here and sending someone to flip it would waste their time.
            Label(
                String(localized: "macOS hasn’t created a notification database on this Mac yet."),
                systemImage: "questionmark.circle"
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("onboarding.grant.status.storeMissing")
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button(String(localized: "Open System Settings")) { model.openFullDiskAccessSettings() }
                .accessibilityIdentifier("onboarding.grant.openSettings")

            Button(String(localized: "Check again")) { model.checkAgain() }
                .accessibilityIdentifier("onboarding.grant.checkAgain")
        }
    }
}

// MARK: - DoneStep

/// Screen 5. Setup is over, and the import is running.
///
/// The last line is the one that matters: what arrives is "everything the system still had",
/// not "your notification history". macOS prunes its own store after a few days, so a new
/// user who expects last month and gets last Tuesday should learn why here rather than
/// conclude the import failed.
struct DoneStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        OnboardingScreen(
            title: String(localized: "You’re set."),
            identifier: "onboarding.done"
        ) {
            Text(String(localized: """
            Backglance is importing what macOS still has — usually the last few days, since the system \
            prunes older notifications. From now on every notification is archived as it arrives.
            """))

            ImportProgressView(progress: model.importProgress)

            Text(String(localized: "Backglance lives in your menu bar. Press Control-Option-N to open it."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - OnboardingScreen

/// The shape every screen shares: a title, an optional subtitle, and a column of text.
///
/// Shared so that five screens written at five different times cannot drift into five
/// different layouts — a setup flow whose type sizes and spacing change between screens reads
/// as unfinished, which is the wrong impression to give while asking for Full Disk Access.
struct OnboardingScreen<Content: View>: View {
    // MARK: Lifecycle

    init(
        title: String,
        subtitle: String? = nil,
        identifier: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.identifier = identifier
        self.content = content()
    }

    // MARK: Internal

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Private

    private let title: String
    private let subtitle: String?
    private let identifier: String
    private let content: Content
}
