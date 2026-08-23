import BackglanceCore
import UserNotifications

// MARK: - DigestBannerPoster

/// Posts the digest's optional local notification banner.
///
/// Yes, a notification-history app posting a notification is mildly ironic. That is
/// exactly why it is off until asked for, one per session, silent, and one toggle from
/// gone (docs/features/MISSED_DIGEST.md#the-local-notification-banner).
///
/// This type does no deciding. ``BackglanceCore/DigestBannerPolicy`` answers whether a
/// banner is allowed and this posts it — the split is what keeps the never-nagging rules
/// testable without `UserNotifications`, and what keeps the one framework import in a file
/// that has no logic worth testing.
///
/// It also never *requests* authorization, only reads it. Asking belongs to
/// ``LocalNotificationAuthorizer/requestIfNeeded()``, which the Settings toggle calls;
/// putting a request here would make a permission prompt appear the first time someone
/// came back to their Mac, which is the opposite of an explicit user action.
struct DigestBannerPoster {
    /// The key the tap handler reads back out of `userInfo` to know which digest to open.
    static let digestIDKey = "digestID"

    /// "You missed 12 notifications from 4 apps while locked".
    ///
    /// Counts and a reason, nothing else — see the privacy note in
    /// ``post(digest:appCount:reason:sessionEndedAt:popoverLastOpenedAt:policy:center:)``.
    static func body(itemCount: Int, appCount: Int, reason: AwayReason) -> String {
        String(
            localized: """
            You missed \(itemCount) notifications from \
            \(appCount) apps \(reason.whileLabel)
            """,
            comment: "Digest banner body. Both counts are pluralized by the string catalog."
        )
    }

    /// Posts a banner for a freshly built digest, if every gate allows it.
    ///
    /// - Parameters:
    ///   - appCount: how many apps the digest covers, for the body text.
    ///   - reason: the session's primary cause.
    ///   - popoverLastOpenedAt: when the user last opened the popover, so an open within
    ///     the grace window after their return cancels the banner.
    /// - Returns: whether a banner was actually posted. For the tests and the log; no
    ///   caller changes behaviour on it.
    @discardableResult
    func post(
        digest: Digest,
        appCount: Int,
        reason: AwayReason,
        sessionEndedAt: Date,
        popoverLastOpenedAt: Date?,
        policy: DigestBannerPolicy = DigestBannerPolicy(),
        center: UNUserNotificationCenter = .current()
    ) async -> Bool {
        guard let digestID = digest.id else {
            return false
        }
        // Cheapest gates first, and the authorization read last: it is the only one that
        // crosses into another process.
        guard policy.isEnabled, reason != .focus || policy.includesFocus else {
            return false
        }
        guard await LocalNotificationAuthorizer.isAuthorized() else {
            Log.digest.info("Digest banner skipped: not authorized")
            return false
        }
        guard policy.allowsBanner(
            reason: reason,
            sessionEndedAt: sessionEndedAt,
            popoverLastOpenedAt: popoverLastOpenedAt,
            isAuthorized: true
        ) else {
            Log.digest.info("Digest banner skipped: the popover was already opened on return")
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "What did I miss")
        content.body = Self.body(itemCount: digest.itemCount, appCount: appCount, reason: reason)
        // 🔒 Nothing from a captured notification reaches this content. The title is fixed
        // and the body is built from two counts and one enum — never a title, a sender or
        // a body, which would put another app's notification text on screen and into the
        // system's own store on the way there.
        content.sound = policy.playsSound ? .default : nil
        content.userInfo = [Self.digestIDKey: digestID]

        // Deterministic identifier: posting twice for one digest replaces the first
        // banner rather than adding a second, so rule 1 holds even if a caller races.
        let request = UNNotificationRequest(
            identifier: "digest-\(digestID)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            Log.digest.info("Digest banner posted for digest \(digestID)")
            return true
        } catch {
            // A banner that fails to post is not an error the user needs to see: the
            // popover path is the primary one and is unaffected.
            Log.digest.error("digest banner failed: \(error.localizedDescription)")
            return false
        }
    }
}
