import BackglanceCore
import Foundation

// MARK: - EnrichmentService

/// Fills in what the store does not carry: the app's icon, and where "Open" should go.
///
/// An actor because it owns a cache on disk and runs from the capture engine, which is
/// itself an actor — two ticks enriching the same app at once would otherwise race on the
/// same file. It is also the one place in capture that touches Launch Services, which is
/// slow enough to be worth doing once per app rather than once per notification.
///
/// Nothing here is allowed to fail a capture. An app that has been uninstalled has no
/// icon, a notification with no URL-ish payload has no deep link, and both cases end with
/// the notification archived exactly as it was parsed — a generic glyph in the timeline
/// and an "Open" that activates the app instead of jumping to the conversation.
///
/// See docs/features/CAPTURE.md#redaction-triage-enrichment.
public actor EnrichmentService: NotificationEnricher {
    // MARK: Lifecycle

    public init(
        icons: AppIconCache = AppIconCache(),
        deepLinks: DeepLinkResolverRegistry = .default
    ) {
        self.icons = icons
        self.deepLinks = deepLinks
    }

    // MARK: Public

    /// Caches the app's icon and resolves the notification's deep link.
    ///
    /// The icon is a side effect rather than a field: the archive has no icon column, and
    /// storing one per notification would keep thousands of copies of the same PNG. The
    /// timeline looks the icon up by bundle id when it draws.
    ///
    /// The deep link *is* a field, and this is the only chance to fill it: it is derived
    /// from `userInfo`, which the archive does not keep. A notification that resolves to
    /// nothing keeps a `nil` link and gets the app fallback when opened.
    public func enrich(_ notification: ParsedNotification) async -> ParsedNotification {
        icons.ensureIcon(forBundleID: notification.bundleID)

        guard notification.deepLink == nil else {
            return notification
        }
        var enriched = notification
        enriched.deepLink = deepLinks.resolve(notification)
        return enriched
    }

    /// Where the cached icon for `bundleID` is, if there is one.
    public func iconURL(forBundleID bundleID: String) -> URL? {
        icons.cachedURL(forBundleID: bundleID)
    }

    // MARK: Private

    private let icons: AppIconCache
    private let deepLinks: DeepLinkResolverRegistry
}
