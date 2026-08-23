import Foundation

// MARK: - UpdaterTrigger

/// Why something is asking whether the updater may run.
public enum UpdaterTrigger: Equatable, Sendable {
    /// `applicationDidFinishLaunching`. Subject to every gate, including the user's own
    /// "check automatically" preference.
    case launch
    /// Backglance ▸ Check for Updates… — the user asked for this one request, so the
    /// automatic-checks preference does not apply to it. The other two gates still do:
    /// without a public key there is nothing to verify a download against, and
    /// `BACKGLANCE_DISABLE_UPDATER` means the whole updater is off, not merely quiet.
    case userInitiated
}

// MARK: - UpdaterStartDecision

/// Whether Sparkle may be started, and when it may not, which gate stopped it.
///
/// One case per reason rather than a `Bool`, because the reason is the thing worth
/// logging: "no network call was made" is a claim, and `noPublicKey` versus
/// `automaticChecksOff` is the difference between a debug build behaving correctly and a
/// release build with a broken key.
public enum UpdaterStartDecision: Equatable, Sendable {
    /// Start the updater. This is the only case that permits network I/O.
    case start
    /// `BACKGLANCE_DISABLE_UPDATER=1` in the environment.
    case disabledByEnvironment
    /// `SUPublicEDKey` is absent, empty, or still the xcconfig placeholder — the state
    /// every Debug build is in on purpose (`Config/Release.xcconfig` defines the key,
    /// `Config/Debug.xcconfig` does not, so `$(SU_PUBLIC_ED_KEY)` resolves to "").
    case noPublicKey
    /// The user turned "Check for updates automatically" off. Applies to ``UpdaterTrigger/launch``
    /// only; a manual check is consent for that one request.
    case automaticChecksOff
}

// MARK: - UpdaterPolicy

/// The whole of "off means off", expressed as a function with no side effects.
///
/// 🔒 This is the guarantee `docs/security/SECURITY.md#the-updater` makes to users: the
/// Sparkle updater is the only network access Backglance has, and disabling updates makes
/// that zero. `SparkleUpdaterController` in the app target is the part that owns
/// `SPUStandardUpdaterController`; it never decides anything itself, it asks this. That
/// split is not tidiness — no test bundle in this project has a `TEST_HOST`, so nothing can
/// `@testable import Backglance` (BACKGLANCE-238), and a security property with no test is
/// a claim rather than a guarantee. The same reasoning put ``URLRoute`` here.
///
/// See docs/deployment/PACKAGING_NOTARIZATION.md#sparkleupdatercontroller-and-the-off-means-off-guarantee.
public enum UpdaterPolicy {
    /// Set to `1` to keep the updater from ever starting, whatever the build carries and
    /// whatever the user's preference says. Read by `Scripts/` and by the network check in
    /// the release checklist; documented in ASSUMPTIONS.md's environment-override list.
    public static let disableEnvironmentKey = "BACKGLANCE_DISABLE_UPDATER"

    /// `UserDefaults` key behind the Settings ▸ Updates toggle. Registered default: `true`.
    public static let automaticChecksDefaultsKey = "updates.checkAutomatically"

    /// Once a day when checks are on. Sparkle's own default is also 86 400, but it is set
    /// explicitly so the interval is a decision in this repository rather than whatever a
    /// future Sparkle release picks.
    public static let checkInterval: TimeInterval = 86_400

    /// The value `Config/Release.xcconfig` ships until the release keypair is generated
    /// (Phase 4.4). Treated exactly like a missing key: a build carrying it cannot verify
    /// any update, so it has no business opening a connection to look for one.
    public static let publicKeyPlaceholder = "REPLACE_WITH_OUTPUT_OF_generate_keys_-p"

    /// - Parameters:
    ///   - trigger: launch, or the user clicking "Check for Updates…".
    ///   - disableEnvironmentValue: `ProcessInfo`'s value for ``disableEnvironmentKey``.
    ///   - publicEDKey: `Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey")`, which
    ///     is a non-optional empty `String` in a Debug build rather than a missing key —
    ///     `Backglance/Info.plist` substitutes `$(SU_PUBLIC_ED_KEY)` unconditionally.
    ///   - automaticChecksEnabled: the user's preference.
    public static func decision(
        trigger: UpdaterTrigger,
        disableEnvironmentValue: String?,
        publicEDKey: String?,
        automaticChecksEnabled: Bool
    ) -> UpdaterStartDecision {
        guard disableEnvironmentValue != "1" else {
            return .disabledByEnvironment
        }
        guard hasUsablePublicKey(publicEDKey) else {
            return .noPublicKey
        }
        guard trigger == .userInitiated || automaticChecksEnabled else {
            return .automaticChecksOff
        }
        return .start
    }

    /// Whether `SUPublicEDKey` is a key Sparkle could actually verify a signature with.
    ///
    /// Trimmed before the emptiness check because an xcconfig substitution that resolves to
    /// nothing can leave whitespace behind, and " " is not a key.
    public static func hasUsablePublicKey(_ publicEDKey: String?) -> Bool {
        guard let trimmed = publicEDKey?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !trimmed.isEmpty && trimmed != publicKeyPlaceholder
    }
}
