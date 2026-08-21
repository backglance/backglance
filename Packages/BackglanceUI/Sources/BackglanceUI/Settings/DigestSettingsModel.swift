import BackglanceCore
import Foundation
import Observation

// MARK: - BannerAuthorization

/// What `UNUserNotificationCenter` would do with a banner right now, reduced to the three
/// answers Settings has different words for.
///
/// A local enum rather than `UNAuthorizationStatus` because `BackglanceUI` does not import
/// `UserNotifications` — and because the pane only needs to know whether to offer the
/// toggle, explain a refusal, or say nothing.
public enum BannerAuthorization: Sendable, Equatable {
    /// Never asked. Switching the toggle on is what asks.
    case notDetermined

    /// Banners will be delivered.
    case authorized

    /// Refused, or unavailable on a managed Mac. Not re-askable from inside the app.
    case denied
}

// MARK: - BannerAuthorizing

/// The two questions the Digest pane can ask the notification centre.
///
/// One value rather than two closure parameters. They have identical types, and Swift's
/// trailing-closure syntax always binds to the *last* parameter — so `init(defaults:) { ... }`
/// would silently wire the reader where the requester was meant, with no warning, and
/// SwiftLint's `trailing_closure` rule actively pushes toward that spelling. Bundling them
/// makes the mistake unspellable instead of merely documented.
public struct BannerAuthorizing: Sendable {
    // MARK: Lifecycle

    public init(
        read: @escaping @Sendable () async -> BannerAuthorization,
        request: @escaping @Sendable () async -> BannerAuthorization
    ) {
        self.read = read
        self.request = request
    }

    // MARK: Public

    /// The current status, without asking for anything. Safe on every appearance.
    public let read: @Sendable () async -> BannerAuthorization

    /// Asks. Called on exactly one transition: the banner toggle going on.
    public let request: @Sendable () async -> BannerAuthorization
}

// MARK: - DigestSettingsModel

/// The Digest pane's state: five stored settings and one permission.
///
/// Every value is written straight through to `UserDefaults` on change, because that is
/// where the rest of the app reads them from — `DigestPolicy` at the end of each away
/// session, `DigestBannerPolicy` at each post. There is no "apply" step to forget.
///
/// The authorization request is injected rather than performed here. Asking is a
/// `UserNotifications` call, and this package does not import that framework; more to the
/// point, the request must happen on exactly one trigger — the user switching banners on
/// — and passing it in is what makes that visible at the call site
/// (docs/features/PERMISSIONS_PRIVACY.md#notifications-backglances-own-local-notifications).
@MainActor
@Observable
public final class DigestSettingsModel {
    // MARK: Lifecycle

    /// - Parameter authorization: how to read and request Notifications authorization.
    ///   `nil` — a preview, or a host with no notification centre — leaves the banner
    ///   toggle inert rather than pretending it granted something.
    public init(
        defaults: UserDefaults = .standard,
        authorization: BannerAuthorizing? = nil
    ) {
        self.defaults = defaults
        self.authorization = authorization
        threshold = DigestThreshold(defaults: defaults)
        let policy = DigestPolicy(defaults: defaults)
        disabledReasons = policy.disabledReasons
        let banner = DigestBannerPolicy(defaults: defaults)
        bannerEnabled = banner.isEnabled
        bannerForFocus = banner.includesFocus
        bannerSound = banner.playsSound
    }

    // MARK: Public

    /// Kinds of away that do **not** earn a digest. Stored as the complement of what the
    /// pane shows — the checkboxes read "count this", because a list of negatives is a
    /// list nobody parses correctly.
    public private(set) var disabledReasons: Set<AwayReason>

    public private(set) var bannerAuthorization: BannerAuthorization = .notDetermined

    /// How long away has to be before a digest is worth showing.
    public var threshold: DigestThreshold {
        didSet {
            guard threshold != oldValue else {
                return
            }
            DigestThreshold.save(threshold, to: defaults)
        }
    }

    /// Whether the digest also posts a local notification.
    ///
    /// Settable, because a `Toggle` needs a binding it can write through synchronously —
    /// one whose `set` only kicks off async work desyncs from its `get` on the very next
    /// redraw, and renders off while the model says on. So this flips immediately and
    /// ``authorizeBannersIfNeeded()`` flips it *back* when authorization is refused, which
    /// is also the more honest animation: the switch visibly declines to stay on.
    public var bannerEnabled: Bool {
        didSet {
            guard bannerEnabled != oldValue, !isSyncingBanner else {
                return
            }
            defaults.set(bannerEnabled, forKey: DigestBannerPolicy.enabledKey)
            guard bannerEnabled else {
                return
            }
            Task { await authorizeBannersIfNeeded() }
        }
    }

    public var bannerForFocus: Bool {
        didSet {
            guard bannerForFocus != oldValue else {
                return
            }
            defaults.set(bannerForFocus, forKey: DigestBannerPolicy.focusKey)
        }
    }

    public var bannerSound: Bool {
        didSet {
            guard bannerSound != oldValue else {
                return
            }
            defaults.set(bannerSound, forKey: DigestBannerPolicy.soundKey)
        }
    }

    /// Whether digests are switched off entirely, which greys out everything below.
    public var isDigestDisabled: Bool {
        threshold.isDisabled
    }

    /// Whether the pane can still get authorization. `false` once the user has refused —
    /// at which point the only route is System Settings, and the pane says so.
    public var canRequestBanners: Bool {
        bannerAuthorization != .denied
    }

    /// Whether a reason earns a digest. The pane's checkboxes bind to this.
    public func counts(_ reason: AwayReason) -> Bool {
        !disabledReasons.contains(reason)
    }

    public func setCounts(_ counts: Bool, for reason: AwayReason) {
        var updated = disabledReasons
        if counts {
            updated.remove(reason)
        } else {
            updated.insert(reason)
        }
        guard updated != disabledReasons else {
            return
        }
        disabledReasons = updated
        DigestPolicy.save(disabledReasons: updated, to: defaults)
    }

    /// Reads the current authorization without asking for it. Safe to call on every
    /// appearance, and the only way a refusal made in System Settings reaches the pane.
    ///
    /// A status that has gone to `denied` also switches the stored setting off: leaving it
    /// on would mean the app quietly believed banners were coming when they were not.
    public func refreshAuthorization() async {
        guard let authorization else {
            return
        }
        bannerAuthorization = await authorization.read()
        if bannerAuthorization == .denied, bannerEnabled {
            setBanner(false)
        }
    }

    /// Switching banners on is the explicit user action that requests authorization — the
    /// only one in the app.
    ///
    /// Called from ``bannerEnabled``'s `didSet`, so the request happens on that transition
    /// and nowhere else. If the answer is no, the setting goes back off: a toggle that
    /// stayed on while nothing could ever be delivered would be a lie.
    ///
    /// Switching banners *off* never asks anything and never revokes anything; it just
    /// stops Backglance posting.
    public func authorizeBannersIfNeeded() async {
        guard bannerEnabled, bannerAuthorization != .authorized else {
            return
        }
        guard let authorization else {
            // No notification centre to ask — a preview, or a host that wired none. Better
            // an inert toggle than one that claims a permission nobody granted.
            setBanner(false)
            return
        }
        bannerAuthorization = await authorization.request()
        guard bannerAuthorization != .authorized else {
            return
        }
        Log.digest.info("Digest banners left off: authorization not granted")
        setBanner(false)
    }

    // MARK: Private

    /// Guards ``setBanner(_:)`` against re-entering ``bannerEnabled``'s `didSet`.
    private var isSyncingBanner = false

    private let defaults: UserDefaults
    private let authorization: BannerAuthorizing?

    /// Writes the stored setting without re-entering the `didSet` above.
    private func setBanner(_ enabled: Bool) {
        isSyncingBanner = true
        bannerEnabled = enabled
        isSyncingBanner = false
        defaults.set(enabled, forKey: DigestBannerPolicy.enabledKey)
    }
}
