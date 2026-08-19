@testable import BackglanceCapture
import Foundation
import XCTest

// MARK: - DeepLinkResolverTests

/// ⚠️ Every key these resolvers read is undocumented — apps put what they like in
/// `userInfo` — so the contract they are held to here is narrow: a URL only when it is
/// confident, `nil` otherwise. `nil` costs the user a jump straight to the conversation
/// and gets them the app instead; a wrong URL opens the wrong thing, which is worse.
final class DeepLinkResolverTests: XCTestCase {
    // MARK: Internal

    // MARK: - Messages

    func testMessagesResolvesAPhoneHandle() {
        let url = MessagesResolver().resolve(Self.notification(
            bundleID: "com.apple.MobileSMS",
            userInfo: ["senderHandle": "+1 555 0100"]
        ))

        XCTAssertEqual(url?.absoluteString, "imessage://+1%20555%200100")
    }

    func testMessagesResolvesAnEmailHandle() {
        let url = MessagesResolver().resolve(Self.notification(
            bundleID: "com.apple.MobileSMS",
            userInfo: ["handle": "ada@example.com"]
        ))

        XCTAssertEqual(url?.absoluteString, "imessage://ada@example.com")
    }

    /// Messages puts the display name in the title, and `imessage://Ada%20Lovelace` opens
    /// nothing. Declining costs the deep link and keeps the app fallback.
    func testMessagesRefusesADisplayName() {
        let url = MessagesResolver().resolve(Self.notification(
            bundleID: "com.apple.MobileSMS",
            sender: "Ada Lovelace"
        ))

        XCTAssertNil(url)
    }

    func testMessagesFallsBackToTheSenderWhenItIsAHandle() {
        let url = MessagesResolver().resolve(Self.notification(
            bundleID: "com.apple.MobileSMS",
            sender: "+15550100"
        ))

        XCTAssertEqual(url?.absoluteString, "imessage://+15550100")
    }

    // MARK: - Mail

    func testMailResolvesAMessageID() {
        let url = MailResolver().resolve(Self.notification(
            bundleID: "com.apple.mail",
            userInfo: ["messageID": "<abc123@example.com>"]
        ))

        XCTAssertEqual(url?.absoluteString, "message://%3Cabc123%40example%2Ecom%3E")
    }

    func testMailWrapsABareMessageIDInAngleBrackets() {
        let url = MailResolver().resolve(Self.notification(
            bundleID: "com.apple.mail",
            userInfo: ["message-id": "abc123@example.com"]
        ))

        XCTAssertEqual(url?.absoluteString.hasPrefix("message://%3C"), true)
    }

    /// ⚠️ The Message-ID is usually absent from the store payload, which is the case this
    /// pins: no link, and Mail opens instead.
    func testMailResolvesNothingWithoutAMessageID() {
        XCTAssertNil(MailResolver().resolve(Self.notification(bundleID: "com.apple.mail")))
    }

    // MARK: - Slack and Discord

    func testSlackPrefersItsOwnSchemeOverTheWebLink() {
        let url = SlackResolver().resolve(Self.notification(
            bundleID: "com.tinyspeck.slackmacgap",
            userInfo: ["deeplink": "slack://channel?team=T1&id=C1", "url": "https://app.slack.com/client/T1/C1"]
        ))

        XCTAssertEqual(url?.scheme, "slack")
    }

    func testSlackAcceptsAWebLinkWhenThatIsAllThereIs() {
        let url = SlackResolver().resolve(Self.notification(
            bundleID: "com.tinyspeck.slackmacgap",
            userInfo: ["url": "https://app.slack.com/client/T1/C1"]
        ))

        XCTAssertEqual(url?.host, "app.slack.com")
    }

    /// An internal identifier that happens to parse as a URL is not a link. Handing one
    /// to the system would open nothing and look like a bug.
    func testSlackRefusesAValueOfAnUnexpectedScheme() {
        let url = SlackResolver().resolve(Self.notification(
            bundleID: "com.tinyspeck.slackmacgap",
            userInfo: ["deeplink": "internal-id://T1/C1"]
        ))

        XCTAssertNil(url)
    }

    func testDiscordResolvesItsOwnScheme() {
        let url = DiscordResolver().resolve(Self.notification(
            bundleID: "com.hnc.Discord",
            userInfo: ["link": "discord://discord.com/channels/1/2"]
        ))

        XCTAssertEqual(url?.scheme, "discord")
    }

    // MARK: - The generic scan

    func testTheGenericResolverTakesAURLTheMacCanOpen() {
        let resolver = GenericURLResolver(opener: StubOpener(canOpen: true))

        let url = resolver.resolve(Self.notification(bundleID: "com.example.app", userInfo: [
            "context": "build-42",
            "url": "https://example.com/builds/42",
        ]))

        XCTAssertEqual(url?.absoluteString, "https://example.com/builds/42")
    }

    /// Plenty of apps put identifiers in `userInfo` that parse as URLs. Opening one would
    /// do nothing visible; leaving the link empty gets the user the app.
    func testTheGenericResolverRefusesASchemeNothingHandles() {
        let resolver = GenericURLResolver(opener: StubOpener(canOpen: false))

        let url = resolver.resolve(Self.notification(
            bundleID: "com.example.app",
            userInfo: ["url": "acmeinternal://thing/42"]
        ))

        XCTAssertNil(url)
    }

    /// 🔒 A notification is not a reason to reveal whatever path an app put in its payload.
    func testTheGenericResolverNeverOpensALocalFile() {
        let resolver = GenericURLResolver(opener: StubOpener(canOpen: true))

        let url = resolver.resolve(Self.notification(
            bundleID: "com.example.app",
            userInfo: ["attachment": "file:///Users/someone/Documents/private.pdf"]
        ))

        XCTAssertNil(url)
    }

    /// The same notification must always resolve to the same URL, whatever order the
    /// dictionary happens to hash in.
    func testTheGenericResolverIsDeterministic() {
        let resolver = GenericURLResolver(opener: StubOpener(canOpen: true))
        let notification = Self.notification(bundleID: "com.example.app", userInfo: [
            "b": "https://example.com/second",
            "a": "https://example.com/first",
        ])

        let urls = (0 ..< 10).map { _ in resolver.resolve(notification)?.absoluteString }

        XCTAssertEqual(Set(urls), ["https://example.com/first"])
    }

    // MARK: - The registry

    func testTheRegistryPrefersTheAppsOwnResolver() {
        let registry = DeepLinkResolverRegistry(
            resolvers: [MessagesResolver()],
            generic: GenericURLResolver(opener: StubOpener(canOpen: true))
        )

        let url = registry.resolve(Self.notification(
            bundleID: "com.apple.MobileSMS",
            userInfo: ["handle": "ada@example.com", "url": "https://example.com/generic"]
        ))

        XCTAssertEqual(url?.scheme, "imessage")
    }

    /// A resolver that declines is not the end of it: the generic scan still runs, which
    /// is what gets Mail's notifications a link when they carry a plain URL.
    func testTheGenericScanRunsWhenTheAppsResolverDeclines() {
        let registry = DeepLinkResolverRegistry(
            resolvers: [MailResolver()],
            generic: GenericURLResolver(opener: StubOpener(canOpen: true))
        )

        let url = registry.resolve(Self.notification(
            bundleID: "com.apple.mail",
            userInfo: ["url": "https://example.com/message"]
        ))

        XCTAssertEqual(url?.absoluteString, "https://example.com/message")
    }

    func testAnAppWithNoResolverFallsStraightToTheGenericScan() {
        let registry = DeepLinkResolverRegistry(
            resolvers: [MessagesResolver()],
            generic: GenericURLResolver(opener: StubOpener(canOpen: true))
        )

        let url = registry.resolve(Self.notification(
            bundleID: "com.example.ci",
            userInfo: ["url": "https://example.com/build"]
        ))

        XCTAssertEqual(url?.absoluteString, "https://example.com/build")
    }

    // MARK: Private

    private static func notification(
        bundleID: String,
        sender: String? = nil,
        userInfo: [String: String] = [:]
    ) -> ParsedNotification {
        ParsedNotification(
            bundleID: bundleID,
            uuid: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
            title: "Ada",
            sender: sender,
            deliveredAt: Date(timeIntervalSinceReferenceDate: 774_000_000),
            presented: true,
            userInfo: userInfo
        )
    }
}

// MARK: - StubOpener

/// Stands in for Launch Services: whether this Mac has a handler for a URL depends on
/// what is installed, and a test must not.
private struct StubOpener: URLOpenerCheck {
    let canOpen: Bool

    func canOpen(_: URL) -> Bool {
        canOpen
    }
}
