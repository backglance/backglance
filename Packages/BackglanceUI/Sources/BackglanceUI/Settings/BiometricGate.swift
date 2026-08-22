import Foundation
import LocalAuthentication

// MARK: - BiometricGate

/// Touch ID, as something a test can stand in for.
///
/// `LAContext` cannot be driven from a unit test — the prompt is a system UI that wants a
/// finger — so the one thing worth asserting about the wipe's second gate is the *logic*
/// around it: that a Mac without Touch ID falls back to the typed word rather than becoming
/// un-wipeable, and that a failed or cancelled prompt deletes nothing. Both need a seam.
public protocol BiometricGate: Sendable {
    /// Whether this Mac can ask at all. `false` on a Mac with no Secure Enclave, and on a
    /// clamshell setup with no Touch ID keyboard.
    var isAvailable: Bool { get }

    /// Asks. Throws if the user cancelled, failed, or is locked out.
    func authenticate(reason: String) async throws
}

// MARK: - LocalAuthenticationGate

/// The real gate.
///
/// A fresh `LAContext` per call, deliberately: a reused context caches a successful
/// evaluation for its lifetime, which would turn "ask before wiping" into "ask before the
/// first wipe of this launch".
public struct LocalAuthenticationGate: BiometricGate {
    // MARK: Lifecycle

    public init() {}

    // MARK: Public

    public var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    public func authenticate(reason: String) async throws {
        let context = LAContext()
        guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) else {
            throw LAError(.authenticationFailed)
        }
    }
}
