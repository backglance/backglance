import BackglanceCore
import Foundation
import Observation

// MARK: - ExcludedAppRow

/// One line in the Excluded Apps pane.
///
/// Not `AppRecord`, for the same reason `RedactionAppRow` is not one: a shipped default
/// that has never notified has no `apps` row at all, and a pane that only listed rows the
/// archive already held would tell someone their password manager was not excluded when
/// it in fact is — simply that it has not spoken up yet.
public struct ExcludedAppRow: Identifiable, Sendable, Hashable {
    public let bundleID: String

    /// The app's name where enrichment has resolved one or the shipped default names it,
    /// its bundle identifier otherwise. Never a placeholder: the bundle id is the more
    /// useful of the two to someone deciding whether a row belongs on this list.
    public let name: String

    /// Why Backglance excludes this app on its own, or `nil` for one the user added.
    ///
    /// Carried rather than left implicit so the view can show "Password manager" next to
    /// a bundle identifier instead of asking the user to trust a list they cannot audit.
    public let reason: ExclusionList.ShippedDefault.Reason?

    /// How many notifications the archive holds for it. `0` for a shipped default that has
    /// not notified yet, or an app the user added by bundle identifier.
    public let notificationCount: Int

    public var id: String {
        bundleID
    }

    /// Whether this row exists because Backglance ships it excluded, rather than because
    /// the user typed its bundle identifier in.
    public var isShippedDefault: Bool {
        reason != nil
    }
}

// MARK: - ExcludedAppsSettingsModel

/// The Excluded Apps pane's state: the apps whose notifications are never stored.
///
/// This is a membership list, not a toggle-per-app list like redaction's: a row belongs
/// here exactly when `ExclusionList.excludes(_:)` says yes, so an app the user has not
/// excluded never shows up asking to be removed from a list it was never on.
///
/// > 🔒 Privacy Invariant #3. Excluding an app here stops future capture; it does not
/// > delete what the archive already holds. That is a deliberate, separate decision (the
/// > per-app `never` retention policy) and this model has no method that conflates the
/// > two — someone excluding a bank from here on has not thereby asked to lose last
/// > month's statements.
///
/// See docs/features/PRIVACY_CONTROLS.md#exclusion-list.
@MainActor
@Observable
public final class ExcludedAppsSettingsModel {
    // MARK: Lifecycle

    /// - Parameter archive: where exclusions live. `nil` — a preview, or a launch whose
    ///   archive would not open — leaves the list empty and every write a no-op rather
    ///   than showing controls that quietly do nothing.
    public init(archive: Archive?) {
        self.archive = archive
    }

    // MARK: Public

    /// What the pane lists: every app currently excluded, whether that is because the
    /// archive says so or because it is a shipped default nobody has touched yet.
    public private(set) var rows: [ExcludedAppRow] = []

    /// Set when a read or a write did not go through, so the pane can say the list is not
    /// reflecting anything rather than sit there looking authoritative.
    public private(set) var failure: String?

    /// A bundle identifier the user is typing to exclude an app the archive has not seen.
    public var pendingBundleID = ""

    /// Whether ``pendingBundleID`` is something worth trying to add.
    ///
    /// A bundle identifier, not a name: at least one dot, no whitespace, and not one
    /// already excluded. Deliberately loose beyond that — refusing a valid identifier is
    /// worse than accepting a typo the user can see sitting in the list with no
    /// notifications against it.
    public var canAddPendingBundleID: Bool {
        let trimmed = pendingBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("."), !trimmed.contains(where: \.isWhitespace) else {
            return false
        }
        return !rows.contains { $0.bundleID == trimmed }
    }

    /// Reads the exclusion list. Called on appearance, and again after every write, because
    /// the row that changed is the one the user is looking at.
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

    /// Excludes `bundleID`, creating its row if the archive has none.
    ///
    /// The list is reloaded rather than patched in place: the write can create a row, and
    /// a model that guessed at the result would drift from the archive the first time a
    /// write failed silently.
    public func exclude(bundleID: String) async {
        guard let archive else {
            return
        }
        do {
            _ = try await Task.detached { try archive.setExcluded(true, bundleID: bundleID) }.value
            failure = nil
        } catch {
            failure = Self.message(for: error)
        }
        await load()
    }

    /// Stops excluding `bundleID`. For a shipped default this is the "you may remove any
    /// of these" promise; for a row the user added it forgets the app entirely.
    public func remove(bundleID: String) async {
        guard let archive else {
            return
        }
        do {
            _ = try await Task.detached { try archive.setExcluded(false, bundleID: bundleID) }.value
            failure = nil
        } catch {
            failure = Self.message(for: error)
        }
        await load()
    }

    /// Adds ``pendingBundleID`` to the exclusion list.
    ///
    /// The row is created empty — no notifications, no display name — which is exactly
    /// what the archive would have created on the app's first notification, only earlier.
    /// That is the point: it lets someone exclude their bank before it ever notifies them.
    public func addPendingBundleID() async {
        let trimmed = pendingBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAddPendingBundleID else {
            return
        }
        pendingBundleID = ""
        await exclude(bundleID: trimmed)
    }

    /// Undoes every shipped default the user has removed, and nothing else — an app the
    /// user added themselves stays excluded, because "restore defaults" means restoring
    /// the defaults and not un-excluding somebody's bank.
    public func restoreDefaults() async {
        guard let archive else {
            return
        }
        do {
            _ = try await Task.detached { try archive.restoreDefaultExclusions() }.value
            failure = nil
        } catch {
            failure = Self.message(for: error)
        }
        await load()
    }

    // MARK: Private

    private let archive: Archive?

    /// The archive's excluded rows, then whichever shipped defaults have no row at all.
    ///
    /// A default that already has a row is represented by that row, not by the shipped
    /// entry — `apps.is_excluded` is what decided whether it belongs on the list, and
    /// reading the shipped entry again here would show a default as excluded even after
    /// the user removed it.
    private static func rows(from apps: [AppRecord]) -> [ExcludedAppRow] {
        let known = Set(apps.map(\.bundleId))
        let excluded = apps
            .filter(\.isExcluded)
            .map { app in
                ExcludedAppRow(
                    bundleID: app.bundleId,
                    // Enrichment's name first, then the one the shipped entry carries, then
                    // the bundle id. Without the middle term a default that had notified
                    // would drop from "1Password" back to "com.1password.1password" — worse
                    // than the row it replaced, and for no reason the user could see.
                    name: app.displayName ?? shippedName(for: app.bundleId) ?? app.bundleId,
                    reason: shippedReason(for: app.bundleId),
                    notificationCount: app.notificationCount
                )
            }
        let untouchedDefaults = ExclusionList.shippedDefaults
            .filter { !known.contains($0.bundleID) }
            .sorted { $0.bundleID < $1.bundleID }
            .map { entry in
                ExcludedAppRow(
                    bundleID: entry.bundleID,
                    name: entry.name,
                    reason: entry.reason,
                    notificationCount: 0
                )
            }
        return excluded + untouchedDefaults
    }

    private static func shippedEntry(for bundleID: String) -> ExclusionList.ShippedDefault? {
        ExclusionList.shippedDefaults.first { $0.bundleID == bundleID }
    }

    private static func shippedReason(for bundleID: String) -> ExclusionList.ShippedDefault.Reason? {
        shippedEntry(for: bundleID)?.reason
    }

    private static func shippedName(for bundleID: String) -> String? {
        shippedEntry(for: bundleID)?.name
    }

    private static func message(for error: Error) -> String {
        (error as? ArchiveError)?.errorDescription ?? String(localized: "The archive could not be read.")
    }
}
