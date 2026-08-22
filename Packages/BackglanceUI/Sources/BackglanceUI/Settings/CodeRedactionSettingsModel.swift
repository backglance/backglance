import BackglanceCore
import Foundation
import Observation

// MARK: - RedactionAppRow

/// One line in the Code Redaction pane.
///
/// Not `AppRecord`, because the pane shows two kinds of row that the archive does not
/// distinguish: apps it has captured notifications from, and the two it redacts by default
/// but has not seen yet. The second kind has no `apps` row at all until the user touches
/// its toggle — and a pane that only listed what the archive held would show neither
/// Messages nor Mail on a Mac where they have not notified, which is precisely when
/// somebody would want to check.
public struct RedactionAppRow: Identifiable, Sendable, Hashable {
    public let bundleID: String

    /// The app's name where enrichment has resolved one, its bundle identifier where it
    /// has not. Never a placeholder like "Unknown app": the bundle id is the more useful
    /// of the two to someone deciding whether to trust a row.
    public let name: String

    public let isOn: Bool

    /// How many notifications the archive holds for it. `0` for a row that only exists
    /// because it is a default or because the user added it by bundle identifier.
    public let notificationCount: Int

    public var id: String {
        bundleID
    }
}

// MARK: - CodeRedactionSettingsModel

/// The Code Redaction pane's state: one global override, and one toggle per app.
///
/// The two settings live in different places on purpose. "Redact codes in all apps" is a
/// preference and goes to `UserDefaults`, because it is a statement about how the app
/// should behave. The per-app toggles are `apps.redact_otp` in the archive, because they
/// are statements about *that archive's* apps — they have to survive alongside the rows
/// they govern, and a user restoring an archive should get the redaction settings that
/// went with it rather than whichever ones this Mac happens to hold.
///
/// > 🔒 Every change here affects notifications captured *afterwards*. Turning redaction
/// > off cannot bring back a code that was already replaced, and this model has no method
/// > that pretends otherwise: there is nothing in the archive to restore from.
///
/// See docs/features/PRIVACY_CONTROLS.md#per-app-toggle-and-redact-codes-in-all-apps.
@MainActor
@Observable
public final class CodeRedactionSettingsModel {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - archive: where the per-app toggles live. `nil` — a preview, or a launch whose
    ///     archive would not open — leaves the list empty and the rows unwritable rather
    ///     than showing toggles that quietly do nothing.
    ///   - defaults: where `privacy.redactOTPInAllApps` and the one-time warning live.
    public init(archive: Archive?, defaults: UserDefaults = .standard) {
        self.archive = archive
        self.defaults = defaults
        redactsAllApps = RedactionPolicy(defaults: defaults).redactsAllApps
        hasWarnedAboutPlainText = defaults.bool(forKey: Self.plainTextWarningShownKey)
    }

    // MARK: Public

    /// What the pane lists: every app the archive knows about, noisiest first, with
    /// Messages and Mail appended if they have not notified yet.
    public private(set) var rows: [RedactionAppRow] = []

    /// Set when a read or a write did not go through, so the pane can say the toggles are
    /// not reflecting anything rather than sit there looking authoritative.
    public private(set) var failure: String?

    /// Shown once, under the app that was just switched off: the plain warning that this
    /// only stops covering future notifications, and that codes will now be stored as
    /// they arrive. Cleared by ``dismissPlainTextWarning()`` and never shown again.
    public private(set) var plainTextWarningBundleID: String?

    /// A bundle identifier the user is typing to add an app the archive has not seen.
    public var pendingBundleID = ""

    /// Whether the redactor runs on every app rather than only the ones toggled on.
    ///
    /// Written straight through, because `PerAppOTPRedaction` reads this key per
    /// notification: the next notification is redacted under the new setting, with no
    /// apply step and no restart.
    public var redactsAllApps: Bool {
        didSet {
            guard redactsAllApps != oldValue else {
                return
            }
            RedactionPolicy.save(redactsAllApps: redactsAllApps, to: defaults)
        }
    }

    /// Whether ``pendingBundleID`` is something worth trying to add.
    ///
    /// A bundle identifier, not a name: at least one dot, no whitespace, and not one the
    /// list already has. Deliberately loose beyond that — Apple's own identifiers do not
    /// follow a stricter rule than this, and refusing a valid one is worse than accepting
    /// a typo the user can see sitting in the list with no notifications against it.
    public var canAddPendingBundleID: Bool {
        let trimmed = pendingBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("."), !trimmed.contains(where: \.isWhitespace) else {
            return false
        }
        return !rows.contains { $0.bundleID == trimmed }
    }

    /// Reads the app list. Called on appearance, and again after every write, because the
    /// row that changed is the one the user is looking at.
    public func load() async {
        guard let archive else {
            return
        }
        do {
            let apps = try await Task.detached { try archive.allApps() }.value
            rows = Self.rows(from: apps)
            failure = nil
        } catch {
            failure = Self.message(for: error)
        }
    }

    /// Turns redaction on or off for one app.
    ///
    /// The list is reloaded rather than patched in place: the write can create a row, and
    /// a model that guessed at the result would drift from the archive the first time a
    /// write failed silently.
    public func setRedaction(_ enabled: Bool, forBundleID bundleID: String) async {
        guard let archive else {
            return
        }
        do {
            _ = try await Task.detached { try archive.setRedactsOTP(enabled, bundleID: bundleID) }.value
            failure = nil
            if !enabled {
                warnAboutPlainTextIfNeeded(bundleID: bundleID)
            }
        } catch {
            failure = Self.message(for: error)
        }
        await load()
    }

    /// Adds ``pendingBundleID`` with redaction on.
    ///
    /// The row is created empty — no notifications, no display name — which is exactly
    /// what the archive would have created on the app's first notification, only earlier.
    /// That is the point: it lets someone switch redaction on for their bank's app before
    /// the bank sends them a code, rather than after.
    public func addPendingBundleID() async {
        let trimmed = pendingBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAddPendingBundleID else {
            return
        }
        pendingBundleID = ""
        await setRedaction(true, forBundleID: trimmed)
    }

    public func dismissPlainTextWarning() {
        plainTextWarningBundleID = nil
    }

    // MARK: Private

    private static let plainTextWarningShownKey = "privacy.redactionPlainTextWarningShown"

    private let archive: Archive?
    private let defaults: UserDefaults

    /// Once, not on every toggle. Persisted rather than kept in memory, because "the user
    /// has been told" is a fact about the user and not about this launch of the app.
    private var hasWarnedAboutPlainText: Bool

    /// The archive's rows, then whichever shipped defaults are missing from them.
    ///
    /// The defaults go last rather than first: they have notified nobody, and the app a
    /// user came to this pane about is one that has. Their `isOn` is the shipped default
    /// — which is also what capture will apply when it creates their row, so the toggle
    /// is not describing something that has yet to be decided.
    private static func rows(from apps: [AppRecord]) -> [RedactionAppRow] {
        let known = Set(apps.map(\.bundleId))
        let captured = apps.map { app in
            RedactionAppRow(
                bundleID: app.bundleId,
                name: app.displayName ?? app.bundleId,
                isOn: app.redactOtp,
                notificationCount: app.notificationCount
            )
        }
        let unseenDefaults = RedactionPolicy.defaultBundleIDs
            .subtracting(known)
            .sorted()
            .map { bundleID in
                RedactionAppRow(bundleID: bundleID, name: bundleID, isOn: true, notificationCount: 0)
            }
        return captured + unseenDefaults
    }

    private static func message(for error: Error) -> String {
        (error as? ArchiveError)?.errorDescription ?? String(localized: "The archive could not be read.")
    }

    /// Warns the first time redaction is switched off for an app that shipped with it on.
    ///
    /// Scoped to the defaults because those are the two the user did not choose: switching
    /// off an app they switched on themselves is them undoing their own decision, and does
    /// not need a warning about a consequence they just opted into.
    private func warnAboutPlainTextIfNeeded(bundleID: String) {
        guard !hasWarnedAboutPlainText, RedactionPolicy.redactsByDefault(bundleID: bundleID) else {
            return
        }
        hasWarnedAboutPlainText = true
        defaults.set(true, forKey: Self.plainTextWarningShownKey)
        plainTextWarningBundleID = bundleID
    }
}
