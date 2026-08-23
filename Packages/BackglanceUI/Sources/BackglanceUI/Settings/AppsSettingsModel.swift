import BackglanceCore
import Foundation
import Observation

// MARK: - AppsSettingsModel

/// Settings ▸ Apps: pick one app, see and change every per-app setting it carries, in one
/// place.
///
/// Retention, exclusion and redaction already have their own flat, all-apps lists —
/// ``RetentionSettingsView``, ``ExcludedAppsSettingsView``, ``CodeRedactionSettingsView`` —
/// and none of that is reimplemented here. This pane answers a different question: not "which
/// apps are excluded" or "which apps redact codes", but "what does Backglance know about
/// *this one app*". It composes the same three models those views already use and simply
/// re-presents them keyed by one selection, the way a Finder "Get Info" panel re-presents
/// facts other views already show elsewhere.
///
/// The app list itself is ``RetentionSettingsModel/rows``, not a fresh `archive.allApps()`
/// read: retention's rows are already "every app the archive holds", which is exactly the
/// universe a picker needs, and reusing it means this model owns zero archive access of its
/// own. Only ``ExcludedAppsSettingsModel`` and ``CodeRedactionSettingsModel`` also list the
/// shipped defaults that have never notified — Messages, Mail, the password managers — and
/// this pane deliberately does not pull those in: setting up an app before it has ever
/// notified you is what the Excluded Apps and Code Redaction panes are already for, and an
/// app picker seeded with apps that have never spoken is not "your apps" in the sense this
/// pane's name promises.
///
/// Per-app mute (`AppRecord.isMuted`) is not offered here. It has no settings model to reuse
/// — the one path that writes it, `RulesEngine.setAppMuted(bundleID:muted:)`, is reserved for
/// BACKGLANCE-239 (`NotificationRowMenu.swift`'s "Mute ‹App› in Timeline" placeholder, still
/// absent for the same reason), and building a fresh write path here would be reimplementing
/// exactly the thing this file's own doc comment says not to do.
///
/// See docs/features/PRIVACY_CONTROLS.md#ui-components.
@MainActor
@Observable
public final class AppsSettingsModel {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - retention: also the source of ``rows`` — see the type's doc comment for why a
    ///     separate archive read is not needed here.
    ///   - exclusions: the exclusion list's model, reused for both the read (is this app on
    ///     it) and the write.
    ///   - redaction: the redaction pane's model, reused the same way.
    public init(
        retention: RetentionSettingsModel,
        exclusions: ExcludedAppsSettingsModel,
        redaction: CodeRedactionSettingsModel
    ) {
        self.retention = retention
        self.exclusions = exclusions
        self.redaction = redaction
    }

    // MARK: Public

    public let retention: RetentionSettingsModel
    public let exclusions: ExcludedAppsSettingsModel
    public let redaction: CodeRedactionSettingsModel

    /// Which app the detail side shows. `nil` only before the first ``load()`` completes, or
    /// on an archive with nothing in it yet.
    public var selectedBundleID: String?

    /// The picker's rows: every app the archive holds. See the type's doc comment for why
    /// this is ``RetentionSettingsModel/rows`` verbatim rather than a fresh list.
    public var rows: [RetentionAppRow] {
        retention.rows
    }

    /// The selected app's row, or `nil` before anything is selected.
    public var selectedRow: RetentionAppRow? {
        guard let selectedBundleID else {
            return nil
        }
        return rows.first { $0.bundleID == selectedBundleID }
    }

    /// Whether the selected app is on the exclusion list.
    public var isSelectedExcluded: Bool {
        guard let selectedBundleID else {
            return false
        }
        return exclusions.rows.contains { $0.bundleID == selectedBundleID }
    }

    /// Whether one-time codes are redacted for the selected app.
    public var isSelectedRedacted: Bool {
        guard let selectedBundleID else {
            return false
        }
        return redaction.rows.first { $0.bundleID == selectedBundleID }?.isOn ?? false
    }

    /// The first failure among the three composed models, if any — enough for the pane to
    /// say something is wrong without inventing its own error text for reads it did not
    /// perform itself.
    public var failure: String? {
        retention.failure ?? exclusions.failure ?? redaction.failure
    }

    /// Loads all three composed models, then picks a default selection if there is none yet.
    /// Called on appearance, and safe to call again — an app removed by a write elsewhere
    /// (there is no such write today, but nothing here assumes otherwise) would simply drop
    /// out of ``rows`` and leave the selection dangling until the next pick.
    public func load() async {
        async let retentionLoad: Void = retention.load()
        async let exclusionsLoad: Void = exclusions.load()
        async let redactionLoad: Void = redaction.load()
        _ = await (retentionLoad, exclusionsLoad, redactionLoad)

        if selectedBundleID == nil {
            selectedBundleID = rows.first?.bundleID
        }
    }

    /// Sets the selected app's retention override. A no-op with nothing selected.
    public func setRetention(_ policy: AppRetention) async {
        guard let selectedBundleID else {
            return
        }
        await retention.setRetention(policy, forBundleID: selectedBundleID)
    }

    /// Excludes or un-excludes the selected app. A no-op with nothing selected.
    public func setExcluded(_ excluded: Bool) async {
        guard let selectedBundleID else {
            return
        }
        if excluded {
            await exclusions.exclude(bundleID: selectedBundleID)
        } else {
            await exclusions.remove(bundleID: selectedBundleID)
        }
    }

    /// Turns one-time-code redaction on or off for the selected app. A no-op with nothing
    /// selected.
    public func setRedaction(_ enabled: Bool) async {
        guard let selectedBundleID else {
            return
        }
        await redaction.setRedaction(enabled, forBundleID: selectedBundleID)
    }
}
