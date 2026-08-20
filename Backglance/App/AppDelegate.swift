import AppKit
import BackglanceCapture
import BackglanceCore
import BackglanceUI
import os

/// Application delegate for the Backglance agent app.
///
/// Backglance has no Dock icon and no windows at launch: `LSUIElement` in `Info.plist`
/// makes it an agent, and everything the user sees hangs off the status item.
///
/// The delegate is where the pieces that cannot live in a package get wired together: the
/// archive, the capture engine, the timeline store, the status item and the ⌃⌥N hotkey.
/// The `backglance://` handler and the Sparkle controller join them in later milestones
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
        startInterface()
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

    /// The interface, retained for the same reason: a status item whose
    /// controller is deallocated stays in the menu bar and stops responding.
    private var store: TimelineStore?
    private var search: SearchService?
    private var searchModel: SearchViewModel?
    private var settings: SettingsWindowController?
    private var statusItem: StatusItemController?
    private var hotKeys: HotKeyCenter?
    private var window: TimelineWindowController?
    private var statusMirror: Task<Void, Never>?

    private static func timelineState(for status: CaptureStatus) -> TimelineCaptureState {
        switch status {
        case .running:
            .running

        case let .paused(until):
            .paused(until: until)

        case .degraded(.noFullDiskAccess):
            .noFullDiskAccess

        case let .degraded(reason):
            .degraded(message: reason.userMessage)

        case .stopped:
            .stopped
        }
    }

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

    /// Builds the timeline and everything that shows it.
    ///
    /// Without an archive there is nothing to show, so the interface is simply
    /// not built — the alternative, a status item whose popover explains that
    /// the database could not be opened, is a window's worth of apology that
    /// onboarding will do properly (docs/features/PERMISSIONS_PRIVACY.md).
    private func startInterface() {
        guard let archive else {
            return
        }

        let store = TimelineStore(archive: archive, host: .popover)
        let window = TimelineWindowController(store: store)
        // Search owns the semantic model and the background indexer, both of
        // which stay asleep until the user turns the setting on.
        let search = SearchService(archive: archive)
        search.start()
        let settings = SettingsWindowController(search: search)
        // The field's own state: what was typed, what came back, what is still
        // in flight. It asks `search` its questions through `SearchRunning`.
        // Read per call rather than captured once: the toggle can change
        // between one keystroke and the next.
        let semanticEnabled: @Sendable () -> Bool = { [weak search] in
            MainActor.assumeIsolated { search?.semanticEnabled ?? false }
        }
        let searchModel = SearchViewModel(search: search, semanticEnabled: semanticEnabled)
        let statusItem = StatusItemController(
            store: store,
            search: searchModel,
            searchService: search,
            menuActions: .init(
                openWindow: { window.show() },
                pauseForAnHour: { [weak self] in
                    guard let engine = self?.engine else {
                        return
                    }
                    Task { await engine.pause(until: Date().addingTimeInterval(3_600)) }
                },
                resume: { [weak self] in
                    guard let engine = self?.engine else {
                        return
                    }
                    Task { await engine.resume() }
                },
                openSettings: { settings.show() }
            )
        )
        // Registration fails when another app already owns ⌃⌥N. That is a note
        // in Settings, not a failure to launch: the status item still works.
        let hotKeys = HotKeyCenter { [weak statusItem] in statusItem?.togglePopover() }
        hotKeys.register()

        self.store = store
        self.search = search
        self.searchModel = searchModel
        self.settings = settings
        self.window = window
        self.statusItem = statusItem
        self.hotKeys = hotKeys
        mirrorCaptureStatus(into: store)
    }

    /// Pushes the engine's status into the store as the UI's own value type.
    ///
    /// The UI never imports `BackglanceCapture`
    /// (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction), so the
    /// translation happens here, in the one place that already knows both
    /// sides. It is a small enum-to-enum map rather than a shared type because
    /// the views need far less than the engine publishes: enough to pick an
    /// icon, an empty state and one sentence.
    private func mirrorCaptureStatus(into store: TimelineStore) {
        guard let engine else {
            return
        }
        statusMirror?.cancel()
        let stream = engine.statusStream
        statusMirror = Task { @MainActor in
            for await status in stream {
                store.captureState = Self.timelineState(for: status)
            }
        }
    }
}
