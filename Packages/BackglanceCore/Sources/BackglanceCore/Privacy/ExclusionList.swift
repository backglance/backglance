import Foundation

// MARK: - ExclusionList

/// Which apps are never archived.
///
/// > 🔒 Privacy Invariant #3. An excluded app's notification is not stored, not indexed,
/// > and not even decoded — the check runs against the raw store row's bundle id, before
/// > the payload becomes objects in memory. This type only answers the question; where it
/// > is asked is what makes the promise true, and that is `CaptureEngine.archiveOne`
/// > (docs/features/PRIVACY_CONTROLS.md#where-exclusion-happens).
///
/// Two layers, and the split is deliberate:
///
/// - **Shipped defaults** live in code (``shippedDefaults``). A release can add a password
///   manager to the list and every existing archive picks it up on the next launch. Seeded
///   rows could not do that — they would be frozen at the moment the archive was created,
///   so the safest thing a future release could offer would only ever reach new installs.
/// - **The user's decisions** live in `apps.is_excluded`, because they are facts about
///   that archive and have to travel with it.
///
/// The user's row always wins, including when it says *not* excluded: a default is a
/// starting position, not a policy, and someone who wants their password manager's
/// notifications archived is entitled to that.
public struct ExclusionList: Sendable, Equatable {
    // MARK: Lifecycle

    /// - Parameter overrides: `apps.is_excluded` keyed by bundle id, for every app row
    ///   the archive holds. An app absent from this map has no row and therefore no
    ///   decision, so the shipped default stands.
    public init(overrides: [String: Bool] = [:]) {
        self.overrides = overrides
    }

    // MARK: Public

    // MARK: - ShippedDefault

    /// One shipped exclusion, and why it is there.
    ///
    /// The reason is carried rather than left to a comment because the Excluded Apps pane
    /// shows it: "Password manager" next to a bundle identifier is the difference between
    /// a list a user can audit and a list they have to trust.
    public struct ShippedDefault: Sendable, Equatable, Identifiable, Hashable {
        // MARK: Lifecycle

        init(bundleID: String, name: String, reason: Reason) {
            self.bundleID = bundleID
            self.name = name
            self.reason = reason
        }

        // MARK: Public

        public enum Reason: String, Sendable, Equatable, Hashable {
            case passwordManager
            case ownNotifications
        }

        public let bundleID: String

        /// What to call it before the app has ever notified and enrichment has had
        /// anything to resolve. Not localized: these are product names.
        public let name: String

        public let reason: Reason

        public var id: String {
            bundleID
        }
    }

    /// The list Backglance ships with.
    ///
    /// Deliberately short. Backglance cannot tell that an app is a bank, a brokerage or a
    /// health service — a bundle identifier does not say so, and a curated "sensitive
    /// apps" list would be wrong for most people and falsely reassuring for the rest. What
    /// it *can* be sure of is that a password manager's notifications are never worth
    /// archiving, and that archiving its own banners is pure noise.
    ///
    /// See docs/features/PRIVACY_CONTROLS.md#defaults.
    public static let shippedDefaults: [ShippedDefault] = [
        ShippedDefault(bundleID: "com.1password.1password", name: "1Password", reason: .passwordManager),
        ShippedDefault(bundleID: "com.agilebits.onepassword7", name: "1Password 7", reason: .passwordManager),
        ShippedDefault(bundleID: "com.bitwarden.desktop", name: "Bitwarden", reason: .passwordManager),
        ShippedDefault(bundleID: "com.dashlane.Dashlane", name: "Dashlane", reason: .passwordManager),
        ShippedDefault(bundleID: "com.lastpass.LastPass", name: "LastPass", reason: .passwordManager),
        ShippedDefault(bundleID: "com.apple.Passwords", name: "Passwords", reason: .passwordManager),
        ShippedDefault(bundleID: "app.backglance.Backglance", name: "Backglance", reason: .ownNotifications),
    ]

    /// The shipped defaults as a set, for the membership test.
    public static let shippedDefaultBundleIDs = Set(shippedDefaults.map(\.bundleID))

    /// Every bundle id this list excludes: the defaults the user has not switched off,
    /// plus the apps they added.
    public var excludedBundleIDs: Set<String> {
        var excluded = Self.shippedDefaultBundleIDs
        for (bundleID, isExcluded) in overrides {
            if isExcluded {
                excluded.insert(bundleID)
            } else {
                excluded.remove(bundleID)
            }
        }
        return excluded
    }

    /// The shipped defaults the user has switched off.
    ///
    /// What "Restore defaults" has to undo — and nothing else, which is why it is stated
    /// as a query rather than left to the caller to work out.
    public var suppressedDefaults: [ShippedDefault] {
        Self.shippedDefaults.filter { overrides[$0.bundleID] == false }
    }

    /// Whether `bundleID` ships excluded, before the user has decided anything.
    public static func isExcludedByDefault(_ bundleID: String) -> Bool {
        shippedDefaultBundleIDs.contains(bundleID)
    }

    /// Whether notifications from `bundleID` must never be archived.
    ///
    /// Compared exactly rather than case-insensitively. A bundle identifier is an
    /// identifier, and the one the store reports is the one the app registered — folding
    /// case here would mean `com.example.app` and `com.example.App` were the same app,
    /// which macOS does not think and which would let a near-miss silently un-exclude
    /// something (docs/reference/INTERNATIONALIZATION.md#the-turkish-locale-rule).
    public func excludes(_ bundleID: String) -> Bool {
        overrides[bundleID] ?? Self.isExcludedByDefault(bundleID)
    }

    // MARK: Private

    /// `apps.is_excluded` per bundle id. Absent means no row, not "false".
    private let overrides: [String: Bool]
}
