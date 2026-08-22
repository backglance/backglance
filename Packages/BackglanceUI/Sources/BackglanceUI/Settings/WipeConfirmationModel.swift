import BackglanceCore
import Foundation
import Observation

// MARK: - WipeConfirmationError

/// Why a wipe did not happen.
///
/// Every case means *nothing was deleted*, except ``incomplete(remaining:)`` — which means
/// the opposite: the wipe happened and a file survived it. Keeping both in one type is what
/// lets the sheet show one message and be right either way.
public enum WipeConfirmationError: Error, Equatable, Sendable {
    /// The text field does not say "wipe".
    case confirmationMismatch

    /// Touch ID was cancelled, failed, or the user is locked out.
    case biometricsFailed

    /// Some files could not be removed. The archive was still recreated.
    case incomplete(remaining: [String])

    /// The wipe itself failed. The archive may be empty, may be untouched, and the log says
    /// which.
    case failed(String)

    // MARK: Public

    /// One plain sentence for the sheet. No paths, no errnos — the names of files that
    /// survived are in the log, not in an alert.
    public var userMessage: String {
        switch self {
        case .confirmationMismatch:
            String(localized: "Type “wipe” to confirm.")

        case .biometricsFailed:
            String(localized: "Touch ID didn’t succeed. Nothing was deleted.")

        case .incomplete:
            String(localized: "Backglance was wiped, but some files couldn’t be removed. See the log for details.")

        case .failed:
            String(localized: "The archive couldn’t be wiped. Nothing was deleted.")
        }
    }
}

// MARK: - WipeConfirmationModel

/// The state behind Settings ▸ Privacy ▸ Wipe archive…
///
/// Two gates, in this order: the user types `wipe`, and then — on a Mac that has Touch ID —
/// touches the sensor. The typed word is the one that always applies; biometrics is an
/// additional gate where the hardware offers one, never a replacement, because a Mac in a
/// clamshell with an external keyboard would otherwise have no way to wipe at all.
///
/// The order of operations around the wipe is this model's, not ``PanicWipe``'s: capture is
/// paused before the file goes and resumed after, through closures the app shell supplies.
/// `BackglanceUI` cannot see `BackglanceCapture`
/// (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction), and it should not have
/// to — "stop the writers" is the same instruction whatever is doing the writing.
///
/// See docs/features/PRIVACY_CONTROLS.md#confirmation.
@MainActor
@Observable
public final class WipeConfirmationModel {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - archive: what gets wiped. `nil` — a preview, or a launch whose archive would not
    ///     open — leaves the button disabled rather than showing one that does nothing.
    ///   - biometrics: the second gate. Injected so a test can be a Mac with Touch ID, or
    ///     one without, without owning either.
    ///   - pauseCapture: stops the writers. Called before anything is destroyed.
    ///   - resumeCapture: starts them again, whatever the outcome — a failed wipe must not
    ///     leave capture paused for the rest of the launch.
    public init(
        archive: Archive?,
        biometrics: any BiometricGate = LocalAuthenticationGate(),
        pauseCapture: @escaping @Sendable () async -> Void = {},
        resumeCapture: @escaping @Sendable () async -> Void = {}
    ) {
        self.archive = archive
        self.biometrics = biometrics
        self.pauseCapture = pauseCapture
        self.resumeCapture = resumeCapture
    }

    // MARK: Public

    /// The word the field has to match.
    public static let confirmationWord = "wipe"

    /// The confirmation word, exactly as the user typed it.
    public var typed = ""

    /// Whether the wipe should also forget excluded apps, retention overrides and redaction
    /// toggles. Off by default — see ``BackglanceCore/PanicWipe/Options``.
    public var forgetPerAppSettings = false

    /// Set while `execute` runs, so the sheet can disable itself rather than let someone
    /// start a second wipe on top of the first.
    public private(set) var isBusy = false

    /// Why the last attempt did not go through, or `nil`.
    public private(set) var failure: WipeConfirmationError?

    /// Set when a wipe finished, so the sheet can close and say what happened.
    public private(set) var didWipe = false

    /// Whether the typed text is the confirmation word.
    ///
    /// Case-insensitive and whitespace-trimmed: someone typing this in a hurry with caps
    /// lock on, or with the trailing space macOS adds after an autocorrection, meant the
    /// same thing. Through ``BackglanceCore/Swift/String/matchKey``, which folds without a
    /// locale — a locale-sensitive fold would leave a Turkish user unable to confirm, since
    /// "WIPE" does not lowercase to "wipe" there
    /// (docs/reference/INTERNATIONALIZATION.md#the-turkish-locale-rule).
    public var isConfirmationWordTyped: Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).matchKey == Self.confirmationWord
    }

    /// Whether the Wipe button should be enabled.
    public var canWipe: Bool {
        archive != nil && isConfirmationWordTyped && !isBusy
    }

    /// Whether this Mac will ask for Touch ID, so the sheet can say which gates apply.
    ///
    /// When it will not, the sheet says the typed word is the only one — an unstated
    /// missing gate is how someone assumes a protection they do not have.
    public var asksForBiometrics: Bool {
        biometrics.isAvailable
    }

    /// Runs both gates and then the wipe.
    ///
    /// Nothing is destroyed until both gates pass: the typed word is checked before the
    /// prompt, and the prompt before capture is even paused.
    public func confirm() async {
        guard !isBusy, let archive else {
            return
        }
        guard isConfirmationWordTyped else {
            failure = .confirmationMismatch
            return
        }

        isBusy = true
        failure = nil
        defer { isBusy = false }

        if biometrics.isAvailable {
            do {
                try await biometrics.authenticate(reason: Self.biometricReason)
            } catch {
                failure = .biometricsFailed
                return
            }
        }

        await pauseCapture()
        // Resumed on every path. A wipe that failed halfway is a reason to tell the user,
        // not a reason to leave their Mac quietly not capturing until the next launch.
        defer { Task { await resumeCapture() } }

        do {
            _ = try await PanicWipe.execute(
                archive: archive,
                options: .init(forgetPerAppSettings: forgetPerAppSettings)
            )
            didWipe = true
        } catch let ArchiveError.wipeIncomplete(remaining) {
            // The archive *was* wiped and recreated; only some files outlived it. Reported,
            // but still a completed wipe as far as the sheet is concerned.
            didWipe = true
            failure = .incomplete(remaining: remaining)
        } catch {
            failure = .failed((error as? ArchiveError)?.logDescription ?? "\(type(of: error))")
        }
    }

    /// Clears the field and the last outcome, for a sheet that is being shown again.
    public func reset() {
        typed = ""
        forgetPerAppSettings = false
        failure = nil
        didWipe = false
    }

    // MARK: Private

    private static var biometricReason: String {
        String(localized: "Wipe the Backglance archive")
    }

    private let archive: Archive?
    private let biometrics: any BiometricGate
    private let pauseCapture: @Sendable () async -> Void
    private let resumeCapture: @Sendable () async -> Void
}
