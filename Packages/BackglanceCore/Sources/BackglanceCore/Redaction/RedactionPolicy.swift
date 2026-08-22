import Foundation

// MARK: - RedactionPolicy

/// Which apps ``OTPRedactor`` is allowed to run on.
///
/// Two settings, and they are not symmetrical. `apps.redact_otp` is per app and is the
/// one the user actually curates; `privacy.redactOTPInAllApps` is a global override that
/// says "run it everywhere regardless". There is no global *off* switch here on purpose —
/// turning redaction off is done app by app, because "off for everything" is a decision
/// worth making one app at a time rather than with a single toggle that a user might flip
/// while looking for something else.
///
/// The policy is a value, not a service: it reads the defaults once at construction, and
/// the capture path builds a fresh one per notification so that a toggle takes effect on
/// the next notification rather than at the next launch. That is cheap —
/// `UserDefaults.bool(forKey:)` is a hit in the registered-domain cache, not a file read.
///
/// See docs/features/PRIVACY_CONTROLS.md#per-app-toggle-and-redact-codes-in-all-apps.
public struct RedactionPolicy: Sendable, Equatable {
    // MARK: Lifecycle

    /// No default value on purpose: with one, `RedactionPolicy()` would compile as either
    /// this or ``init(defaults:)``, and neither the compiler nor a reader could tell which
    /// was meant.
    public init(redactsAllApps: Bool) {
        self.redactsAllApps = redactsAllApps
    }

    /// Reads the global override, defaulting to off.
    public init(defaults: UserDefaults = .standard) {
        self.init(redactsAllApps: defaults.bool(forKey: Self.redactAllAppsKey))
    }

    // MARK: Public

    public static let redactAllAppsKey = "privacy.redactOTPInAllApps"

    /// The apps redaction is on for before the user has configured anything.
    ///
    /// 🔒 Messages and Mail carry one-time codes often enough that waiting for the user
    /// to find the setting would mean archiving codes in the meantime. Everything else is
    /// off by default because the keyword rules are tuned for SMS and e-mail phrasing;
    /// see ``redactsAllApps``.
    ///
    /// One source of truth for the two places that need it: `Archive.upsertApp`, which
    /// stamps it onto the row when capture first sees the app, and
    /// `Archive.redactsOTP(bundleID:)`, which answers for an app that has no row yet. They
    /// have to agree, or the pane would promise something capture would not do.
    public static let defaultBundleIDs: Set<String> = ["com.apple.MobileSMS", "com.apple.mail"]

    /// Whether the redactor runs on every app, not only the ones with `apps.redact_otp`.
    ///
    /// Off by default. The keyword lists are written for the way an SMS or an e-mail
    /// announces a code, and running them over a chat app or a build server turns ticket
    /// numbers next to the word "login" into `[code redacted]` — a false positive that
    /// cannot be undone, because there is nothing left to undo it from.
    public let redactsAllApps: Bool

    /// Whether redaction is on for `bundleID` before the user has touched anything.
    public static func redactsByDefault(bundleID: String) -> Bool {
        defaultBundleIDs.contains(bundleID)
    }

    public static func save(redactsAllApps: Bool, to defaults: UserDefaults) {
        defaults.set(redactsAllApps, forKey: redactAllAppsKey)
    }

    /// Whether an app whose row says `redact_otp = appRedactsOTP` should be redacted.
    public func redacts(appRedactsOTP: Bool) -> Bool {
        redactsAllApps || appRedactsOTP
    }

    /// Whether `app` should be redacted.
    public func redacts(_ app: AppRecord) -> Bool {
        redacts(appRedactsOTP: app.redactOtp)
    }
}
