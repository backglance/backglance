import Foundation
import GRDB

// MARK: - AppPrivacySetting

/// One app's privacy decisions, without any of its notifications.
///
/// Bundle identifiers and flags — nothing a notification said. That is what makes it safe
/// for a wipe to carry across: someone who excluded their bank's app, shortened Slack's
/// retention, or turned redaction off for Messages made those decisions about *apps*, and
/// destroying the archive is not a request to un-decide them. The confirmation sheet offers
/// to forget these too, off by default.
///
/// See docs/features/PRIVACY_CONTROLS.md#panic-wipe.
public struct AppPrivacySetting: Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        bundleID: String,
        retention: AppRetention = .inherit,
        isExcluded: Bool = false,
        isMuted: Bool = false,
        redactOTP: Bool
    ) {
        self.bundleID = bundleID
        self.retention = retention
        self.isExcluded = isExcluded
        self.isMuted = isMuted
        self.redactOTP = redactOTP
    }

    // MARK: Public

    public let bundleID: String
    public let retention: AppRetention
    public let isExcluded: Bool
    public let isMuted: Bool
    public let redactOTP: Bool
}

// MARK: - Archive + per-app privacy settings

public extension Archive {
    /// Every app whose settings differ from what a fresh row would hold.
    ///
    /// Only the differences, because a row exists for every app that has ever notified this
    /// user and restoring all of them would rebuild the app list from a wipe — which is
    /// content, in the sense that matters: "which apps notify you" is exactly the kind of
    /// thing someone wiping their archive is trying to remove.
    ///
    /// The comparison is against a *fresh* row rather than against `false` everywhere,
    /// because redaction ships on for Messages and Mail. Turning it off for Messages is a
    /// deliberate decision and has to survive; leaving it on is the default and does not
    /// need to.
    func perAppPrivacySettings() throws -> [AppPrivacySetting] {
        do {
            return try pool.read { db in
                try AppRecord.fetchAll(db).compactMap { app in
                    let setting = AppPrivacySetting(
                        bundleID: app.bundleId,
                        retention: app.retention,
                        isExcluded: app.isExcluded,
                        isMuted: app.isMuted,
                        redactOTP: app.redactOtp
                    )
                    return setting.isDefault ? nil : setting
                }
            }
        } catch {
            throw ArchiveError.observationFailed(ArchiveError.detail(from: error))
        }
    }

    /// Writes those settings back, creating an app row for each.
    ///
    /// The rows it creates carry `notification_count = 0` and today's seen-at timestamps,
    /// which is the truth after a wipe: the settings survived, the history did not.
    func restorePerAppPrivacySettings(_ settings: [AppPrivacySetting], now: Date = Date()) throws {
        guard !settings.isEmpty else {
            return
        }
        do {
            try pool.write { db in
                for setting in settings {
                    var app = try Self.upsertApp(db, bundleID: setting.bundleID, now: now, retention: setting.retention)
                    app.retention = setting.retention
                    app.isExcluded = setting.isExcluded
                    app.isMuted = setting.isMuted
                    app.redactOtp = setting.redactOTP
                    try app.update(db)
                }
            }
        } catch {
            throw ArchiveError.writeFailed(
                table: AppRecord.databaseTableName,
                underlying: ArchiveError.detail(from: error)
            )
        }
    }
}

// MARK: - AppPrivacySetting + defaults

extension AppPrivacySetting {
    /// Whether this is exactly what a newly created row for the same app would hold, and so
    /// carries no decision worth preserving.
    var isDefault: Bool {
        retention == .inherit
            && !isExcluded
            && !isMuted
            && redactOTP == RedactionPolicy.redactsByDefault(bundleID: bundleID)
    }
}
