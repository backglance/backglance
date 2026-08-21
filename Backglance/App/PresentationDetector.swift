import AppKit
import BackglanceCore
import CoreGraphics

/// Gathers what ``PresentationPolicy`` needs, and tells the tracker when the answer flips.
///
/// ⚠️ The signals are heuristic and the gathering is best-effort. Everything that can fail
/// here — no window list, no window titles, no frontmost app — fails towards "not
/// presenting", because a false positive opens an away session while the user is sitting
/// right there.
///
/// Polling rather than observing: there is no notification for "a share toolbar
/// appeared". 15 seconds matches the capture poll and is far below the 5-minute minimum
/// session, so the sampling granularity never decides whether a digest happens.
///
/// > Important: Backglance does **not** request Screen Recording. Without it
/// > `kCGWindowName` is absent for other apps' windows, so the share-indicator half of the
/// > heuristic finds nothing and only the slideshow half works. That is the documented
/// > trade (docs/features/PERMISSIONS_PRIVACY.md): Full Disk Access is the only permission
/// > this app asks for.
@MainActor
final class PresentationDetector {
    // MARK: Lifecycle

    init(
        policy: @escaping @Sendable () -> PresentationPolicy,
        interval: TimeInterval = 15,
        onChange: @escaping @Sendable (Bool) -> Void
    ) {
        self.policy = policy
        self.interval = interval
        self.onChange = onChange
    }

    deinit {
        // A timer scheduled on the main run loop retains its target block, so a detector
        // released without `stop()` would keep polling the window server forever.
        MainActor.assumeIsolated {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: Internal

    /// Begins polling. Idempotent: re-starting replaces the timer rather than adding one.
    func start() {
        stop()
        // `.common` so the poll keeps running while a menu is open — the status item's
        // menu tracking would otherwise stall it.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sample()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Reads the world once and reports a change. Internal so a test can step it.
    func sample() {
        let presenting = policy().isPresenting(Self.observe())
        guard presenting != lastReported else {
            return
        }
        lastReported = presenting
        Log.digest.info("Presenting detection changed to \(presenting)")
        onChange(presenting)
    }

    // MARK: Private

    private let policy: @Sendable () -> PresentationPolicy
    private let interval: TimeInterval
    private let onChange: @Sendable (Bool) -> Void

    private var timer: Timer?

    /// `nil` until the first sample, so the first result is always reported.
    private var lastReported: Bool?

    /// One snapshot of the window server, translated into AppKit-free values.
    private static func observe() -> PresentationPolicy.Observation {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            // The window list is unavailable. Assume not presenting rather than carrying
            // the previous answer forward — a stuck `true` never clears.
            return PresentationPolicy.Observation(frontmostBundleID: frontmost)
        }

        let screens = NSScreen.screens.map(\.frame)
        let windows = raw.map { window -> PresentationPolicy.WindowRef in
            PresentationPolicy.WindowRef(
                ownerName: window[kCGWindowOwnerName as String] as? String ?? "",
                // Absent without Screen Recording, which is the ordinary case here.
                name: window[kCGWindowName as String] as? String,
                coversScreen: coversAScreen(window, screens: screens),
                layer: window[kCGWindowLayer as String] as? Int ?? 0
            )
        }
        return PresentationPolicy.Observation(frontmostBundleID: frontmost, windows: windows)
    }

    /// Whether a window's bounds cover one of the screens.
    ///
    /// Compared with a tolerance rather than for equality: `kCGWindowBounds` is in a
    /// flipped, global coordinate space and a slideshow's rectangle is routinely a point
    /// or two off a screen's, which an exact match would reject.
    private static func coversAScreen(_ window: [String: Any], screens: [CGRect]) -> Bool {
        guard
            let bounds = window[kCGWindowBounds as String] as? [String: Any],
            let width = bounds["Width"] as? CGFloat,
            let height = bounds["Height"] as? CGFloat
        else {
            return false
        }
        let tolerance: CGFloat = 4
        return screens.contains { screen in
            abs(width - screen.width) <= tolerance && abs(height - screen.height) <= tolerance
        }
    }
}
