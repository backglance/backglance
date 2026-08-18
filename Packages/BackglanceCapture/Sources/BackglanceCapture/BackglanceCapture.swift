import Foundation

/// Module marker for `BackglanceCapture`.
///
/// The real types (`CaptureEngine`, the store layer, the per-macOS adapters and the
/// record parser) land in Phase 1. Everything in this module reads Apple's
/// undocumented Notification Center store; see
/// `docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md` before changing any of it.
public enum BackglanceCapture {
    /// macOS major versions this build ships a store adapter for.
    public static let supportedOSMajorVersions: [Int] = [14, 15, 26]
}
