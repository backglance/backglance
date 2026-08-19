import AppKit
import Foundation

// MARK: - DeepLinkResolver

/// Produces the URL that reopens the context of one notification.
///
/// Resolvers run at capture time and their result is stored in
/// `notifications.deep_link`, so "Open" on a two-week-old notification does not depend on
/// re-deriving anything. They are handed the ``ParsedNotification`` while it still has its
/// `userInfo`, which the archive does not keep.
///
/// ⚠️ Almost every key a resolver reads is undocumented: apps put what they like in
/// `userInfo`, and the Apple ones are not documented at all. So a resolver's contract is
/// narrow — return a URL only when it is confident, `nil` otherwise. `nil` is not a
/// failure: the UI falls back to activating the app, which is always right, while a wrong
/// URL opens the wrong conversation.
///
/// See docs/features/ACTIONS.md#open-openaction-and-deeplinkresolver.
public protocol DeepLinkResolver: Sendable {
    /// Bundle identifiers this resolver handles. An empty set marks the generic fallback.
    static var bundleIDs: Set<String> { get }

    /// The URL, or `nil` when nothing can be said with confidence.
    func resolve(_ notification: ParsedNotification) -> URL?
}

// MARK: - DeepLinkResolverRegistry

/// Picks the resolver for a notification: the app's own first, then the generic scan.
public struct DeepLinkResolverRegistry: Sendable {
    // MARK: Lifecycle

    public init(
        resolvers: [any DeepLinkResolver],
        generic: any DeepLinkResolver = GenericURLResolver()
    ) {
        var byBundleID: [String: any DeepLinkResolver] = [:]
        for resolver in resolvers {
            for bundleID in type(of: resolver).bundleIDs {
                byBundleID[bundleID] = resolver
            }
        }
        self.byBundleID = byBundleID
        self.generic = generic
    }

    // MARK: Public

    /// The resolvers Backglance ships.
    public static let `default` = DeepLinkResolverRegistry(resolvers: [
        MessagesResolver(),
        MailResolver(),
        SlackResolver(),
        DiscordResolver(),
    ])

    /// The app's own resolver first, then the generic scan of `userInfo`.
    ///
    /// Never throws and never blocks on anything slow: enrichment sits inside the capture
    /// tick, and a resolver that stalled would stall archiving.
    public func resolve(_ notification: ParsedNotification) -> URL? {
        if let resolver = byBundleID[notification.bundleID], let url = resolver.resolve(notification) {
            return url
        }
        return generic.resolve(notification)
    }

    // MARK: Private

    private let byBundleID: [String: any DeepLinkResolver]
    private let generic: any DeepLinkResolver
}

// MARK: - URLOpenerCheck

/// Whether this Mac has an app registered for a URL.
///
/// Injectable because the answer depends on what is installed, and a test that asserted
/// "slack:// opens" would pass or fail based on the machine it ran on.
public protocol URLOpenerCheck: Sendable {
    func canOpen(_ url: URL) -> Bool
}

// MARK: - WorkspaceOpenerCheck

public struct WorkspaceOpenerCheck: URLOpenerCheck {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public func canOpen(_ url: URL) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }
}

// MARK: - GenericURLResolver

/// The fallback: the first value in `userInfo` that is a URL this Mac can actually open.
///
/// Requiring a registered handler is what keeps this honest. Plenty of apps put internal
/// identifiers in `userInfo` that happen to parse as URLs; opening one would do nothing
/// visible and look like a bug, whereas leaving `deep_link` empty gets the user the app
/// itself.
public struct GenericURLResolver: DeepLinkResolver {
    // MARK: Lifecycle

    public init(opener: any URLOpenerCheck = WorkspaceOpenerCheck()) {
        self.opener = opener
    }

    // MARK: Public

    public static let bundleIDs: Set<String> = []

    public func resolve(_ notification: ParsedNotification) -> URL? {
        // Sorted so the same notification always resolves to the same URL, whatever order
        // the dictionary happens to hash in.
        for key in notification.userInfo.keys.sorted() {
            guard
                let value = notification.userInfo[key],
                let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
                let scheme = url.scheme?.lowercased(),
                // Never open a local file: a notification is not a reason to reveal
                // whatever path an app happened to put in its payload.
                scheme != "file",
                opener.canOpen(url)
            else {
                continue
            }
            return url
        }
        return nil
    }

    // MARK: Private

    private let opener: any URLOpenerCheck
}

// MARK: - MessagesResolver

/// Messages: back to the conversation, when the handle is there to go back to.
public struct MessagesResolver: DeepLinkResolver {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public static let bundleIDs: Set<String> = ["com.apple.MobileSMS"]

    public func resolve(_ notification: ParsedNotification) -> URL? {
        // ⚠️ Undocumented: the handle has been observed under these keys. `sender` is the
        // last resort because for Messages it is the notification's title, which is a
        // display name as often as it is a handle — hence the shape check below.
        let candidates = [
            notification.userInfo["senderHandle"],
            notification.userInfo["handle"],
            notification.sender,
        ]

        guard
            let handle = candidates.compactMap({ $0 }).first(where: Self.looksLikeHandle),
            let encoded = handle.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else {
            return nil
        }
        return URL(string: "imessage://\(encoded)") ?? URL(string: "sms:\(encoded)")
    }

    // MARK: Internal

    /// A phone number or an email address — never a display name.
    ///
    /// "Ada Lovelace" is what Messages usually puts in the title, and `imessage://Ada%20Lovelace`
    /// opens nothing. Rejecting it costs the deep link and keeps the app fallback, which
    /// at least opens Messages.
    static func looksLikeHandle(_ candidate: String) -> Bool {
        if candidate.contains("@") {
            return candidate.split(separator: "@").count == 2
        }
        let digits = candidate.filter(\.isNumber)
        return digits.count >= 7 && candidate.allSatisfy { $0.isNumber || " +-()".contains($0) }
    }
}

// MARK: - MailResolver

/// Mail: back to the message, when the store carried its Message-ID.
///
/// ⚠️ It usually did not. Expect `nil` most of the time and the app fallback with it.
public struct MailResolver: DeepLinkResolver {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public static let bundleIDs: Set<String> = ["com.apple.mail"]

    public func resolve(_ notification: ParsedNotification) -> URL? {
        guard var messageID = notification.userInfo["messageID"] ?? notification.userInfo["message-id"] else {
            return nil
        }
        if !messageID.hasPrefix("<") {
            messageID = "<\(messageID)>"
        }
        guard let encoded = messageID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return nil
        }
        return URL(string: "message://\(encoded)")
    }
}

// MARK: - SlackResolver

/// Slack: whatever URL its payload carried, `slack:` or the web app.
///
/// Which keys are present depends on the Slack build, so this reads several and takes the
/// first that is a URL of a scheme Slack actually handles.
public struct SlackResolver: DeepLinkResolver {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public static let bundleIDs: Set<String> = ["com.tinyspeck.slackmacgap"]

    public func resolve(_ notification: ParsedNotification) -> URL? {
        PayloadURL.first(
            in: notification,
            keys: ["deeplink", "deepLink", "link", "url"],
            schemes: ["slack", "https"]
        )
    }
}

// MARK: - DiscordResolver

/// Discord: the `discord:` URL from its payload, when there is one.
public struct DiscordResolver: DeepLinkResolver {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public static let bundleIDs: Set<String> = ["com.hnc.Discord"]

    public func resolve(_ notification: ParsedNotification) -> URL? {
        PayloadURL.first(
            in: notification,
            keys: ["deeplink", "deepLink", "link", "url"],
            schemes: ["discord", "https"]
        )
    }
}

// MARK: - PayloadURL

/// The shared "find a URL in `userInfo`" step the per-app resolvers use.
///
/// Kept in one place because the difference between Slack's resolver and Discord's is the
/// bundle id and the scheme it trusts, and two copies of the scan would be two places to
/// forget the scheme check.
enum PayloadURL {
    /// The first value under `keys` that parses as a URL with one of `schemes`.
    ///
    /// `keys` is ordered by preference; the scheme allow-list is what keeps an app's
    /// internal identifier from being handed to `NSWorkspace` as if it were a link.
    static func first(in notification: ParsedNotification, keys: [String], schemes: Set<String>) -> URL? {
        for key in keys {
            guard
                let value = notification.userInfo[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                let url = URL(string: value),
                let scheme = url.scheme?.lowercased(),
                schemes.contains(scheme)
            else {
                continue
            }
            return url
        }
        return nil
    }
}
