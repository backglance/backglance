import Foundation

// MARK: - PresentationPolicy

/// Decides whether what the Mac is showing counts as "presenting".
///
/// ⚠️ **Heuristic, and openly so.** There is no API that answers "is this person
/// presenting". This reads two weak signals — a presenter app frontmost with a window
/// covering the screen, and the floating "you are sharing" toolbars that conferencing
/// apps put up — and either can be wrong. Vendors rename windows; Meet in Safari is not
/// detected at all.
///
/// The bias is deliberate: **false negatives are preferred to false positives.** A missed
/// presentation costs one digest's worth of grouping, and the notifications still reach
/// the timeline. A false positive opens an away session while the user is sitting right
/// there, which is the app being wrong about the one thing it claims to know.
///
/// This type is pure — it decides over an ``Observation`` someone else gathered — so the
/// heuristic is unit-testable without a window server. The gathering lives in the app
/// target, which is also the only place AppKit belongs.
///
/// See docs/features/MISSED_DIGEST.md#presenting-and-screen-share-detection.
public struct PresentationPolicy: Sendable, Equatable {
    // MARK: Lifecycle

    public init(presenterBundleIDs: Set<String> = PresentationPolicy.defaultPresenterBundleIDs) {
        self.presenterBundleIDs = presenterBundleIDs
    }

    /// Reads the user's edited allowlist, falling back to the shipped defaults when they
    /// have never touched it.
    ///
    /// An empty stored list is a real choice — "never detect a slideshow" — and is kept,
    /// which is why absence and emptiness are distinguished here.
    public init(defaults: UserDefaults) {
        if let stored = defaults.stringArray(forKey: Self.presenterBundleIDsKey) {
            presenterBundleIDs = Set(stored)
        } else {
            presenterBundleIDs = Self.defaultPresenterBundleIDs
        }
    }

    // MARK: Public

    /// One window, as much of it as can be seen without Screen Recording.
    public struct WindowRef: Sendable, Equatable {
        // MARK: Lifecycle

        public init(ownerName: String, name: String? = nil, coversScreen: Bool = false, layer: Int = 0) {
            self.ownerName = ownerName
            self.name = name
            self.coversScreen = coversScreen
            self.layer = layer
        }

        // MARK: Public

        public let ownerName: String

        /// `nil` when the window's title is not visible to Backglance.
        ///
        /// On modern macOS `kCGWindowName` for *another app's* window requires Screen
        /// Recording. Backglance does not ask for it — Full Disk Access is the only
        /// permission it requests — so this is `nil` for most windows, and the detector
        /// simply notices less.
        public let name: String?

        /// Whether the window's bounds cover a whole screen.
        public let coversScreen: Bool

        /// `kCGWindowLayer`. A slideshow is an ordinary layer-0 window; menu bars and
        /// floating panels are not.
        public let layer: Int
    }

    /// What the detector saw at one moment.
    public struct Observation: Sendable, Equatable {
        // MARK: Lifecycle

        public init(frontmostBundleID: String? = nil, windows: [WindowRef] = []) {
            self.frontmostBundleID = frontmostBundleID
            self.windows = windows
        }

        // MARK: Public

        public let frontmostBundleID: String?

        /// On-screen windows, desktop elements excluded. Empty when the window list could
        /// not be read at all.
        public let windows: [WindowRef]
    }

    /// A window that exists because someone is sharing their screen.
    public enum ShareIndicator: Sendable, Equatable {
        /// Matches only when the window's title is readable and starts with `namePrefix`.
        ///
        /// This is the only shape that ships. Every owner below runs all day — Chrome and
        /// Teams obviously, and `zoom.us` for as long as the app is open — so the *name*
        /// is the entire signal. Without Screen Recording the name is `nil`, nothing
        /// matches, and presenting is simply not detected from indicators. That is the
        /// documented trade: less detection, not a guess.
        case ownerAndWindowName(owner: String, namePrefix: String)

        /// Matches on the owner alone.
        ///
        /// > Warning: only ever for an owner whose process exists *solely* while sharing.
        /// > Applying it to an ordinary app would report presenting for as long as that
        /// > app is running, which is the worst failure this detector has — an away
        /// > session opened while the user is sitting in front of the screen. No shipped
        /// > indicator uses it.
        case ownerOnly(owner: String)
    }

    /// Apps whose frontmost full-screen window means a slideshow.
    ///
    /// Shipped defaults only; the list is the user's to edit, because which app someone
    /// presents from is not something this project can enumerate.
    public static let defaultPresenterBundleIDs: Set<String> = [
        "com.apple.iWork.Keynote",
        "com.microsoft.Powerpoint",
    ]

    /// ⚠️ Observed window titles, not API. A vendor renaming a toolbar silently turns its
    /// entry into a false negative — which is the failure direction this detector wants.
    public static let shareIndicators: [ShareIndicator] = [
        .ownerAndWindowName(owner: "zoom.us", namePrefix: "zoom share"),
        .ownerAndWindowName(owner: "Google Chrome", namePrefix: "meet.google.com is sharing"),
        .ownerAndWindowName(owner: "Microsoft Teams", namePrefix: "Sharing controls"),
    ]

    public static let presenterBundleIDsKey = "presentationDetection.presenterBundleIDs"

    /// The user's allowlist of presenter apps, by bundle identifier.
    public var presenterBundleIDs: Set<String>

    /// Persists an edited allowlist. Sorted so the stored value is stable and diffable.
    public static func save(presenterBundleIDs: Set<String>, to defaults: UserDefaults) {
        defaults.set(presenterBundleIDs.sorted(), forKey: presenterBundleIDsKey)
    }

    /// Forgets the user's edits, so the shipped defaults apply again.
    public static func resetPresenterBundleIDs(in defaults: UserDefaults) {
        defaults.removeObject(forKey: presenterBundleIDsKey)
    }

    public func isPresenting(_ observation: Observation) -> Bool {
        isRunningSlideshow(observation) || isSharing(observation)
    }

    // MARK: Private

    /// A presenter app frontmost **and** showing a window that covers a screen.
    ///
    /// Both halves are needed. Frontmost alone is the doc's stated false-positive risk:
    /// Keynote is frontmost for the hours someone spends *building* the deck, and
    /// treating that as presenting would bury a working day in away sessions.
    private func isRunningSlideshow(_ observation: Observation) -> Bool {
        guard
            let frontmost = observation.frontmostBundleID,
            presenterBundleIDs.contains(frontmost)
        else {
            return false
        }
        // Layer 0: a slideshow is an ordinary window taken full-screen, not a panel.
        return observation.windows.contains { $0.coversScreen && $0.layer == 0 }
    }

    private func isSharing(_ observation: Observation) -> Bool {
        observation.windows.contains { window in
            Self.shareIndicators.contains { indicator in
                switch indicator {
                case let .ownerOnly(owner):
                    return window.ownerName == owner

                case let .ownerAndWindowName(owner, namePrefix):
                    guard window.ownerName == owner, let name = window.name else {
                        return false
                    }
                    // Turkish-locale rule: case folding for matching is always
                    // locale-independent, and `matchKey` is the one primitive that does
                    // it. Pinning `lowercased(with:)` to a POSIX locale was equally
                    // correct and is what stood here before, but it spelled the operation
                    // the rule forbids — so every reader had to re-derive that this one
                    // was the safe use (docs/reference/INTERNATIONALIZATION.md#the-rule).
                    return name.matchKey.hasPrefix(namePrefix.matchKey)
                }
            }
        }
    }
}
