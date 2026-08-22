import Foundation

// MARK: - OpenAction

/// The click-time half of Open: given the stored `deep_link` and the owning
/// app's bundle id, decides between "open that URL" and "activate the app".
/// See docs/features/ACTIONS.md#open-openaction-and-deeplinkresolver.
///
/// *Resolution* — picking a URL out of a notification's `userInfo` — already
/// happened at capture time, in `BackglanceCapture`'s `DeepLinkResolver`
/// registry, and the result is sitting in `notifications.deep_link` by the
/// time a user ever clicks. This type never looks at `userInfo`, never parses
/// notification content, and never builds a URL out of anything but the
/// stored `deep_link` string itself — see the "Don't" callout at the end of
/// docs/features/ACTIONS.md#edge-cases-and-error-handling.
///
/// A plain `struct` rather than a method directly on `NotificationActionHandler`:
/// the ordering has three independent exit points (link opened, link present
/// but refused so fall through, no link at all) and reads cleanest as its own
/// small piece of logic that `NotificationActionHandlerTests` — or a sibling
/// `OpenActionTests` — can drive with a scripted ``AppLaunching`` without
/// touching the archive at all. Internal, not `public`: nothing outside
/// `BackglanceUI` constructs one directly, only `NotificationActionHandler`.
///
/// `@MainActor` because ``AppLaunching`` is: every call this makes into it
/// is main-thread, same as `NotificationActionHandler` itself.
@MainActor
struct OpenAction {
    let workspace: any AppLaunching

    /// A stored `deep_link` that does not parse as an openable `URL` is
    /// treated exactly like a dead handler, not an error: the column is
    /// `TEXT` with no validation at write time, so a future resolver bug or a
    /// hand-edited row should fall through to app activation, the same as a
    /// scheme nobody claims any more.
    ///
    /// Two things are refused here rather than handed to `NSWorkspace`, and
    /// both are refusals the resolvers already make at capture time. This is
    /// the second gate, not the first: the archive outlives the build that
    /// wrote it, so a row inserted by an older resolver is exactly the case a
    /// click-time check exists for.
    ///
    /// - `file:`, because a notification is never a reason to open something
    ///   on this Mac. `GenericURLResolver` rejects it at enrichment for the
    ///   same reason — see docs/features/ACTIONS.md#edge-cases-and-error-handling.
    /// - Anything with no scheme at all, because `URL(string:)` is happy to
    ///   read a plain sentence as a relative path. A notification body that
    ///   somehow reached this column would parse, and handing it to
    ///   `NSWorkspace` is precisely the "URL built from notification content"
    ///   the "Don't" callout forbids.
    static func parsedURL(_ deepLink: String?) -> URL? {
        guard let deepLink,
              let url = URL(string: deepLink),
              // Bare `lowercased()`, not `lowercased(with:)` — a scheme is an
              // ASCII token compared against an ASCII literal, and the
              // Turkish dotless ı is exactly why the locale-aware form is
              // banned for internal comparisons.
              let scheme = url.scheme?.lowercased(),
              scheme != "file"
        else {
            return nil
        }
        return url
    }

    /// Whether `url` is worth a separate "Open Link" menu item, per the
    /// Context Menu Specification table in docs/features/ACTIONS.md: only
    /// when it "differs from plain app activation, i.e. has a path/query". A
    /// bare `slack://` or `https://example.com` opens to the same place app
    /// activation would, so offering a second menu item for it would just be
    /// a second way to do the first one.
    ///
    /// `url.path` is `""` for both `slack://` and `https://example.com` —
    /// there is no authority-relative segment to speak of — and becomes
    /// non-empty the moment one exists (`https://example.com/a` → `"/a"`).
    /// `URLComponents.query` is `nil` until a `?` is present, even an empty
    /// one, which is exactly "carries a query" in the plain-English sense of
    /// the spec.
    static func hasPathOrQuery(_ url: URL) -> Bool {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.query
        return !url.path.isEmpty || query != nil
    }

    /// Full three-step ordering behind ↩ / "Open in ‹App›":
    /// 1. `deepLink`, if it parses and something still opens it, wins.
    /// 2. Otherwise activate `bundleID`.
    /// 3. Otherwise throw.
    ///
    /// - Throws: ``ActionError/appNotInstalled(bundleID:)`` when `bundleID`
    ///   does not resolve to an installed app, or
    ///   ``ActionError/launchFailed(bundleID:reason:)`` when it resolves but
    ///   `openApplication` itself throws.
    func run(deepLink: String?, bundleID: String) async throws {
        if let url = Self.parsedURL(deepLink), workspace.open(url) {
            return
        }
        guard let appURL = workspace.applicationURL(forBundleID: bundleID) else {
            throw ActionError.appNotInstalled(bundleID: bundleID)
        }
        do {
            try await workspace.launchApplication(at: appURL)
        } catch {
            throw ActionError.launchFailed(bundleID: bundleID, reason: error.localizedDescription)
        }
    }

    /// ⌘↩'s "Open Link only": step 1 alone, with no app-activation fallback.
    /// A missing link, an unparseable one, and a refused one are all the same
    /// outcome here — there is nothing left to try once the link itself has
    /// failed, unlike ``run(deepLink:bundleID:)`` which still has app
    /// activation to fall back to.
    ///
    /// - Throws: ``ActionError/deepLinkUnresolvable(notificationID:)``, which
    ///   the view layer turns into a system beep, not text — see
    ///   `ActionError.userMessage`.
    func openLink(deepLink: String?, notificationID: Int64) throws {
        guard let url = Self.parsedURL(deepLink), workspace.open(url) else {
            throw ActionError.deepLinkUnresolvable(notificationID: notificationID)
        }
    }
}
