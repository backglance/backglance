import BackglanceCore
import Foundation
import Observation

// MARK: - RetentionAppRow

/// One line in the Retention pane.
///
/// Not `AppRecord`, for the same reason `ExcludedAppRow` and `RedactionAppRow` are not one:
/// the row carries exactly what the picker needs — the `AppRetention` the app currently
/// holds, not the effective policy it resolves to — so that "Inherit" stays "Inherit" in the
/// picker even while the global default sitting above it changes.
///
/// Unlike the other two panes, this one lists *every* app the archive holds rather than a
/// subset. Retention is not a membership question — every app has one, even if it is only
/// "whatever the global default says" — so there is no "not shown yet" state to invent for
/// an app the archive has not seen. It simply is not a row until it has notified once.
public struct RetentionAppRow: Identifiable, Sendable, Hashable {
    public let bundleID: String

    /// The app's name where enrichment has resolved one, its bundle identifier otherwise.
    /// Never a placeholder: the bundle id is the more useful of the two to someone deciding
    /// whether a row needs an override.
    public let name: String

    /// What `apps.retention` holds for this app: `.inherit`, or an explicit policy.
    ///
    /// Not the *effective* policy. A row showing "Inherit" is telling the truth about what
    /// this app has been set to, which is what the picker has to reflect back — resolving
    /// it against the global default here would make the picker forget the user chose
    /// "Inherit" the moment the global default changed under it.
    public let retention: AppRetention

    /// How many notifications the archive holds for it.
    public let notificationCount: Int

    public var id: String {
        bundleID
    }
}

// MARK: - RetentionSettingsModel

/// The Retention pane's state: one global default, one override per app, and the button
/// that runs the job that acts on both.
///
/// The two settings live in different places on purpose, the same split as redaction and
/// exclusions. "Keep notifications for" is a preference and goes to `UserDefaults`, because
/// it is a statement about how the app should behave in general. The per-app overrides are
/// `apps.retention` in the archive, because they are statements about *that archive's*
/// apps — they have to survive alongside the rows they govern, and a user restoring an
/// archive should get the overrides that went with it rather than whichever ones this Mac
/// happens to hold.
///
/// > 🔒 Choosing "Never store" for an app sets `is_excluded` in the same transaction
/// > (`Archive.setRetention(_:bundleID:now:)`), so this pane and the Excluded Apps pane can
/// > never disagree about an app the user picked "Never store" for. Nothing here deletes
/// > what the archive already holds for that app — that is `Archive.forgetHistory(bundleID:)`,
/// > offered from a confirmation sheet this pane does not build.
///
/// See docs/features/PRIVACY_CONTROLS.md#policy-values-and-inheritance.
@MainActor
@Observable
public final class RetentionSettingsModel {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - archive: where per-app overrides live. `nil` — a preview, or a launch whose
    ///     archive would not open — leaves the list empty and every write a no-op rather
    ///     than showing controls that quietly do nothing.
    ///   - job: what "Run cleanup now" calls. `nil` — a preview, or a launch that could not
    ///     build one — disables the button rather than showing one that quietly does
    ///     nothing when pressed.
    ///   - defaults: where the global default lives.
    public init(archive: Archive?, job: RetentionJob?, defaults: UserDefaults = .standard) {
        self.archive = archive
        self.job = job
        self.defaults = defaults
        global = RetentionSettings(defaults: defaults).global
    }

    // MARK: Public

    /// What the pane lists: every app the archive holds, noisiest first, each with the
    /// override it currently carries.
    public private(set) var rows: [RetentionAppRow] = []

    /// Set when a read or a write did not go through, so the pane can say the list is not
    /// reflecting anything rather than sit there looking authoritative.
    public private(set) var failure: String?

    /// Whether a cleanup pass is running, so the button can disable itself rather than let
    /// someone queue a second pass on top of the first.
    public private(set) var isBusy = false

    /// What the last cleanup pass did, so the pane can say something more useful than "done"
    /// after the button is pressed.
    public private(set) var lastReport: RetentionJob.Report?

    /// What applies to every app that has not been given an override.
    ///
    /// Written straight through to `UserDefaults`: `RetentionJob` reads the global default
    /// fresh at the top of every pass rather than caching it, so there is no "apply" step to
    /// forget and the next pass — automatic or "Run cleanup now" — sees the new value.
    public var global: RetentionPolicy {
        didSet {
            guard global != oldValue else {
                return
            }
            RetentionSettings.save(global: global, to: defaults)
        }
    }

    /// Whether "Run cleanup now" is worth showing enabled: there is a job to call, and it is
    /// not already running one.
    public var canRunCleanupNow: Bool {
        job != nil && !isBusy
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

    /// Sets one app's retention override.
    ///
    /// The list is reloaded rather than patched in place: picking "Never store" also
    /// excludes the app in the same write, and a model that guessed at the result would
    /// drift from the archive the first time a write failed silently.
    public func setRetention(_ retention: AppRetention, forBundleID bundleID: String) async {
        guard let archive else {
            return
        }
        do {
            _ = try await Task.detached { try archive.setRetention(retention, bundleID: bundleID) }.value
            failure = nil
        } catch {
            failure = Self.message(for: error)
        }
        await load()
    }

    /// Runs one cleanup pass now, rather than waiting for the six-hourly timer.
    ///
    /// `RetentionJob.runOnce(trigger:)` never throws — a failed pass is logged and retried
    /// on the next cycle — so there is no `failure` path here, only a report of what
    /// happened. The list is reloaded afterwards because a pass that soft-deleted rows
    /// changes `notificationCount` on the rows this pane shows.
    public func runCleanupNow() async {
        guard let job else {
            return
        }
        isBusy = true
        defer { isBusy = false }
        lastReport = await job.runOnce(trigger: .manual)
        await load()
    }

    // MARK: Private

    private let archive: Archive?
    private let job: RetentionJob?
    private let defaults: UserDefaults

    private static func rows(from apps: [AppRecord]) -> [RetentionAppRow] {
        apps.map { app in
            RetentionAppRow(
                bundleID: app.bundleId,
                name: app.displayName ?? app.bundleId,
                retention: app.retention,
                notificationCount: app.notificationCount
            )
        }
    }

    private static func message(for error: Error) -> String {
        (error as? ArchiveError)?.errorDescription ?? String(localized: "The archive could not be read.")
    }
}
