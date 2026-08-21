import BackglanceCore
import BackglanceUI
import UserNotifications

// MARK: - LocalNotificationAuthorizer

/// Backglance's own Notifications permission, asked for at the one moment it is allowed
/// to be asked for: when the user turns on a feature that needs it.
///
/// Never at launch, and never from the posting path
/// (docs/features/PERMISSIONS_PRIVACY.md#notifications-backglances-own-local-notifications).
/// An app whose entire pitch is "macOS shows a notification once and forgets it" has no
/// business opening a permission prompt nobody asked for, and there is nothing to prompt
/// *about* until someone switches the digest banner on.
///
/// Denial is a normal outcome, not an error: the digest's default presentation is the
/// popover, which needs no permission at all.
enum LocalNotificationAuthorizer {
    /// The current state, without asking for anything.
    ///
    /// This is what `DigestBannerPoster` calls before every post. It cannot prompt, which
    /// is the property that makes "requested only from an explicit user action" true no
    /// matter what the posting path does later.
    static func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Whether a banner would actually be delivered right now.
    static func isAuthorized() async -> Bool {
        switch await status() {
        case .authorized,
             .provisional,
             .ephemeral: true
        default: false
        }
    }

    /// Asks, if asking is still possible. Call this **only** from an explicit user action.
    ///
    /// A previous denial is respected rather than re-asked: macOS would not show a second
    /// prompt anyway, and Settings ▸ Digest says where to change it instead.
    ///
    /// - Returns: the resulting status. `.denied` covers a refusal and a failure alike,
    ///   because the caller's next move — leave the toggle off and explain — is the same.
    @discardableResult
    static func requestIfNeeded() async -> UNAuthorizationStatus {
        let current = await status()
        switch current {
        case .authorized,
             .provisional,
             .ephemeral:
            return current

        case .denied:
            // Not re-requested by design: the system shows nothing on a second call, so a
            // "grant" button that silently did nothing would be worse than a link.
            return .denied

        case .notDetermined:
            break

        @unknown default:
            break
        }

        do {
            // `.sound` is requested so the opt-in toggle has something to turn on; every
            // post still sets `content.sound = nil` unless that toggle is on.
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            Log.digest.info("Notification authorization request returned granted=\(granted)")
            return granted ? .authorized : .denied
        } catch {
            // `notificationsNotAllowed` on a managed Mac, or no bundle at all when running
            // from a non-app path. Both mean the same thing to the caller.
            Log.digest.error("notification authorization request failed: \(error.localizedDescription)")
            return .denied
        }
    }
}

// MARK: - UNAuthorizationStatus + BannerAuthorization

extension UNAuthorizationStatus {
    /// The three answers Settings has different words for.
    ///
    /// `provisional` and `ephemeral` count as authorized because a banner posted under
    /// either does arrive; the pane's question is only ever "would the user see this".
    var bannerAuthorization: BannerAuthorization {
        switch self {
        case .authorized,
             .provisional,
             .ephemeral:
            .authorized

        case .denied:
            .denied

        case .notDetermined:
            .notDetermined

        @unknown default:
            .notDetermined
        }
    }
}
