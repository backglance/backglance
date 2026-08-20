import AppKit
import BackglanceCapture
import BackglanceCore
import os

/// Application delegate for the Backglance agent app.
///
/// Backglance has no Dock icon and no windows at launch: `LSUIElement` in `Info.plist`
/// makes it an agent, and everything the user sees hangs off the status item.
///
/// The delegate is where the pieces that cannot live in a package get wired together.
/// Today that is the archive and the capture engine; the status item, the ⌃⌥N hotkey, the
/// `backglance://` handler and the Sparkle controller join them in later milestones
/// (docs/architecture/ARCHITECTURE.md#app-shell-backglance-target).
///
/// The order below is the one the architecture requires and is not interchangeable: the
/// archive is opened **and migrated** before anything hands it to the engine, because
/// `CaptureEngine.start()` writes the capture fingerprint on its very first bootstrap and
/// would otherwise write into a schema that does not exist yet.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: Internal

    func applicationDidFinishLaunching(_: Notification) {
        // LSUIElement already does this at launch. Setting it again is what keeps the app
        // an agent if it is ever launched in a way that bypasses the Info.plist key, and
        // it documents the intent at the one place a reader looks for it.
        NSApp.setActivationPolicy(.accessory)
        logger.notice("Backglance launched as an agent app")

        startCapture()
    }

    func applicationWillTerminate(_: Notification) {
        // Best effort, and deliberately not waited on. The engine persists its cursor
        // *after* each batch commits, precisely so that being killed mid-tick costs a
        // re-read of records the unique index then discards, never a lost notification —
        // so a quit that outruns this teardown is a case the design already covers.
        guard let engine else {
            return
        }
        Task { await engine.stop() }
    }

    /// macOS 14 warns on delegates that do not answer this; Backglance restores no state.
    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        true
    }

    // MARK: Private

    private let logger = Logger(subsystem: "app.backglance.Backglance", category: "ui")

    /// Retained for the lifetime of the app. The engine is the only reader of Apple's
    /// store, and the watcher is the only thing that wakes it; a local would deallocate
    /// both at the end of launch and capture would silently never run.
    private var archive: Archive?
    private var watcher: StoreWatcher?
    private var engine: CaptureEngine?

    /// Opens the archive, builds the capture engine on top of it, and starts watching.
    ///
    /// Nothing here blocks on Full Disk Access or on the store existing. Both are ordinary
    /// states rather than failures: `CaptureEngine` records them as `.degraded` and retries
    /// on every wake, which is what lets someone grant access in System Settings and see
    /// capture resume without relaunching (docs/features/PERMISSIONS_PRIVACY.md).
    private func startCapture() {
        let archive: Archive
        do {
            archive = try Archive.open()
        } catch {
            // Deliberately not `Archive.shared`, which is `fatalError` on failure by
            // design — that design assumes onboarding has already ruled out the
            // recoverable causes, and onboarding arrives in a later milestone. Until it
            // does, crashing an agent app at launch with no window to explain itself is
            // strictly worse than running without capture and saying so in the log.
            let detail = (error as? ArchiveError)?.logDescription ?? ArchiveError.detail(from: error)
            logger.error("archive unavailable, capture not started: \(detail, privacy: .public)")
            return
        }

        // `expected()` rather than `current()`: on a fresh account `usernoted` has not
        // created its database yet, and the watcher has to be armed anyway so that capture
        // begins the moment it appears.
        let watcher = StoreWatcher(location: StoreLocation.expected())
        let engine = CaptureEngine(
            archive: archive,
            watcher: watcher,
            // The real enrichment, not the `NoEnrichment` default: icons and deep links
            // are what make a row in the timeline actionable.
            enrichment: EnrichmentService()
        )

        self.archive = archive
        self.watcher = watcher
        self.engine = engine

        // First-launch import is *not* started here. Live capture begins at the store's
        // tail, and backfilling what the store already holds is an explicit step the user
        // agrees to, with its own progress UI, in the onboarding milestone
        // (docs/features/CAPTURE.md#first-launch-import).
        Task { await engine.start() }
    }
}
