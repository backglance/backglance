import AppKit
import BackglanceCapture
import BackglanceCore
import BackglanceUI
import os
import UserNotifications

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
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    // MARK: Internal

    /// Internal rather than private: the onboarding wiring lives in
    /// `AppDelegate+Onboarding.swift`, and `private` does not reach across files even within
    /// one type. Each is retained for the app's lifetime for the reason below.
    var engine: CaptureEngine?
    var monitor: FullDiskAccessMonitor?
    var banners: CaptureBannerModel?
    var onboarding: OnboardingWindowController?
    var activationObserver: (any NSObjectProtocol)?

    /// Internal so the mirror can live in `AppDelegate+CaptureStatus.swift`.
    var statusMirror: Task<Void, Never>?

    /// Retained for the lifetime of the app. The engine is the only reader of Apple's
    /// store, and the watcher is the only thing that wakes it; a local would deallocate
    /// both at the end of launch and capture would silently never run.
    var archive: Archive?
    /// The one notification-action coordinator, shared by the popover and the window so
    /// the two can never disagree about what is pending undo. Retained for the same reason
    /// every other model on this delegate is: a local would deallocate at the end of
    /// launch and take every row action with it.
    var actionHandler: NotificationActionHandler?

    /// The away model. The tracker is the state machine; the bridge is the only thing
    /// holding its OS observers, and both die with the app.
    /// The prune loop. Retained for the same reason as the engine: a local would
    /// deallocate it at the end of launch and nothing would ever expire.
    var retention: RetentionJob?

    /// The interface, retained for the same reason: a status item whose
    /// controller is deallocated stays in the menu bar and stops responding.
    var store: TimelineStore?

    /// The full window's own store.
    ///
    /// Separate from ``store`` because ``BackglanceUI/TimelineStore/Host`` is fixed at
    /// init and decides real behaviour, not just chrome: `TimelineStore+Selection` gates
    /// every multi-select mutator on `host == .window`, `NotificationRowMenu` hides
    /// "Export Selection…" outside it, and the two hosts file their view mode and
    /// grouping under different defaults keys. One shared `host: .popover` store meant
    /// the window silently lost all of it (BACKGLANCE-243).
    ///
    /// `nil` until the window is first opened — see `showTimelineWindow()` for why the
    /// second subscription and page cache are not paid for at launch.
    var windowStore: TimelineStore?

    /// What the engine last said, so a store built after that status arrived does not
    /// start out claiming capture is running when it is not. ``windowStore`` is created
    /// on first open, long after the mirror's first value.
    var lastCaptureState: TimelineCaptureState = .running

    var digests: DigestPresenter?
    var search: SearchService?
    var searchModel: SearchViewModel?
    var settings: SettingsWindowController?
    var statusItem: StatusItemController?
    var hotKeys: HotKeyCenter?
    var window: TimelineWindowController?

    /// Retained for the same reason as every other collaborator here: a local would
    /// deallocate at the end of `startURLScheme()`, and whether `NSAppleEventManager`
    /// itself would then still have somewhere live to deliver `kAEGetURL` to is not a
    /// question worth risking — this is the one strong reference the app keeps on it
    /// (docs/api/API_DOCUMENTATION.md#url-scheme-backglance).
    var urlSchemeHandler: URLSchemeHandler?

    /// The Sparkle owner, and with it the only network access this app has. Built and
    /// gated in `AppDelegate+Updates.swift`; retained here because an updater that
    /// deallocated would take Sparkle's scheduled check with it.
    var updater: SparkleUpdaterController?

    /// `rulesEngine`, or ``NoTriage`` when it has not been built — which only happens when
    /// `startCapture()` itself found no archive, the same state every `guard let archive`
    /// below already treats as "nothing to build". Every triage-consuming type default-
    /// initializes to `NoTriage()` on its own, so this exists only to give every call site
    /// below the same one instance instead of each falling back to its own separate no-op.
    var triage: any TriageEvaluating {
        if let rulesEngine {
            return rulesEngine
        }
        return NoTriage()
    }

    func applicationDidFinishLaunching(_: Notification) {
        // LSUIElement already does this at launch. Setting it again is what keeps the app
        // an agent if it is ever launched in a way that bypasses the Info.plist key, and
        // it documents the intent at the one place a reader looks for it.
        NSApp.setActivationPolicy(.accessory)
        logger.notice("Backglance launched as an agent app")

        startCapture()
        // Before startAwayTracking(): the recorder's digest build and the timeline both
        // triage through this one instance, so it has to exist before the first thing that
        // hands it out does.
        startRules()
        startAwayTracking()
        // Before startInterface(): the settings window built there needs a `RetentionJob`
        // reference for the Retention pane's "Run cleanup now" button. Moving this call
        // earlier does not cost the popover anything — `RetentionJob.start()` only spins up
        // an async `Task` that sleeps for its launch delay before doing real work, so the
        // "painted popover first" ordering `startRetention()`'s own doc comment describes is
        // about when a *pass* runs, not about when this method is called.
        startRetention()
        // Before startInterface(): that method builds the settings window, whose Updates
        // pane reads this controller, and the status item's menu, which asks it whether to
        // offer "Check for Updates…" at all. Starting it here costs nothing at launch — an
        // updater that is allowed to run schedules its first check, it does not make one.
        startUpdater()
        startInterface()
        // After startInterface(): every surface a route can reach — the status item, the
        // timeline window, the engine — has to exist before the first `kAEGetURL` can
        // arrive, and macOS does not deliver a launch URL until this method returns anyway
        // (docs/api/API_DOCUMENTATION.md#url-scheme-backglance).
        startURLScheme()
        // Last, and after the interface: setup's last screen ends with "Backglance lives in
        // your menu bar", which wants a menu bar item already there to look at.
        startOnboardingIfNeeded()
        // Setting a delegate neither requests authorization nor shows anything; it is
        // only how a tap on a banner we may never post finds its way back here.
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationWillTerminate(_: Notification) {
        // Best effort, and deliberately not waited on. The engine persists its cursor
        // *after* each batch commits, precisely so that being killed mid-tick costs a
        // re-read of records the unique index then discards, never a lost notification —
        // so a quit that outruns this teardown is a case the design already covers.
        // The away tracker holds any open session in memory; committing it here is what
        // turns "quit while locked" into a session row instead of nothing. Same
        // best-effort posture as the engine below.
        if let awayTracker {
            Task { await awayTracker.flush() }
        }
        if let retention {
            Task { await retention.stop() }
        }

        guard let engine else {
            return
        }
        Task { await engine.stop() }
    }

    /// macOS 14 warns on delegates that do not answer this; Backglance restores no state.
    func applicationSupportsSecureRestorableState(_: NSApplication) -> Bool {
        true
    }

    /// A tap on the digest banner opens the popover, which is already showing that digest:
    /// `DigestPresenter` surfaces whatever is pending, and the banner exists only because
    /// something is. So this opens the surface rather than routing an identifier through
    /// it — one path to the digest, not two that could disagree.
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.notification.request.content.userInfo[DigestBannerPoster.digestIDKey] != nil else {
            return
        }
        statusItem?.openOnDigest()
    }

    /// Backglance is an agent app and is almost never frontmost, but it *is* frontmost
    /// while its own popover has key — exactly when a digest banner can arrive. Without
    /// this the system would swallow it, and the user would have switched banners on for
    /// nothing.
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// The settings window and the models its panes read.
    ///
    /// Each pane's model is built here rather than inside the window controller, because
    /// the archive and the search service are the app shell's to hand out — `BackglanceUI`
    /// is given what it reads, and does not go looking for it.
    ///
    /// - Parameter retention: `nil` when `startRetention()` could not build one (no
    ///   archive). `RetentionSettingsModel` treats that the same way every other pane treats
    ///   a `nil` archive: "Run cleanup now" disables itself rather than pressing a button
    ///   that quietly does nothing.
    func settingsWindow(
        search: SearchService,
        archive: Archive,
        retention: RetentionJob?
    ) -> SettingsWindowController {
        // The Privacy pane is the only place that can destroy the archive, so it is also
        // the only place given the closures that stop and start capture. The engine is
        // reached weakly and per call: it is built after the archive and can be replaced.
        let pause: @Sendable () async -> Void = { [weak self] in await self?.engine?.pause() }
        let resume: @Sendable () async -> Void = { [weak self] in await self?.engine?.resume() }
        let wipe = WipeConfirmationModel(archive: archive, pauseCapture: pause, resumeCapture: resume)
        // Built once and shared between Privacy and Apps, not one instance per pane: both
        // panes write the same three per-app settings, and two separate models would mean a
        // change made in one pane sitting stale in the other's list until the next appearance
        // re-triggered its own `.task { await model.load() }`.
        let retentionModel = RetentionSettingsModel(archive: archive, job: retention)
        let exclusionsModel = ExcludedAppsSettingsModel(archive: archive)
        let redactionModel = CodeRedactionSettingsModel(archive: archive)
        let privacy = PrivacySettingsModel(
            archive: archive,
            retention: retentionModel,
            exclusions: exclusionsModel,
            redaction: redactionModel,
            wipe: wipe,
            resumeCapture: resume
        )
        let apps = AppsSettingsModel(retention: retentionModel, exclusions: exclusionsModel, redaction: redactionModel)
        // `rulesEngine` is already built and observing by the time this runs —
        // `applicationDidFinishLaunching(_:)` calls `startRules()` before `startInterface()`,
        // which is the only caller of this method — so the Rules pane's export/import menu
        // has a live engine from the moment the window can first be shown, the same as every
        // other model built here.
        let rules = RulesSettingsModel(archive: archive, engine: rulesEngine)
        let general = GeneralSettingsModel(
            digest: Self.digestSettings(),
            search: Self.semanticSearchControl(search),
            launchAtLogin: Self.launchAtLoginControl(),
            hotKey: hotKeyControl()
        )
        return SettingsWindowController(
            general: general,
            apps: apps,
            privacy: privacy,
            rules: rules,
            updates: makeUpdatesModel(),
            permissions: makePermissionsModel(),
            status: makeStatusModel(archive: archive)
        )
    }

    // The members below are `internal`, not `private`, because
    // `AppDelegate+Interface.swift` composes the interface out of them and Swift's
    // `private` does not reach across files even for an extension of the same type —
    // the same reason `AppDelegate+CaptureStatus.swift`'s `makeBannerModel()` is
    // internal. They are still owned here: nothing outside this target sets them.

    // MARK: Private

    private let logger = Logger(subsystem: "app.backglance.Backglance", category: "ui")

    private var watcher: StoreWatcher?

    /// One instance for the whole app, built right after `archive` and started before
    /// anything that needs to triage a row hands it out — see `startRules()`. Never one
    /// engine per surface: the popover and the window would otherwise be able to disagree
    /// about a rule, and the triage cache would be duplicated instead of shared.
    private var rulesEngine: RulesEngine?

    private var awayTracker: AwaySessionTracker?
    private var awayBridge: AwayEventBridge?
    private var focusWatcher: FocusAssertionWatcher?
    private var presentationDetector: PresentationDetector?

    /// The Digest pane's model, and the only place in Backglance that can cause a
    /// permission prompt — and only when the user switches banners on.
    ///
    /// Both closures are `UserNotifications` calls, which `BackglanceUI` cannot make
    /// itself: passing them in is what keeps that framework's one import in the app target,
    /// and what makes the single trigger for the request visible at a call site.
    private static func digestSettings() -> DigestSettingsModel {
        DigestSettingsModel(authorization: BannerAuthorizing(
            read: { await LocalNotificationAuthorizer.status().bannerAuthorization },
            request: { await LocalNotificationAuthorizer.requestIfNeeded().bannerAuthorization }
        ))
    }

    /// Offers the freshly built digest to the banner.
    ///
    /// On the main actor because the one thing it needs beyond the archive — when the
    /// popover was last opened — lives on the status item. `DigestBannerPoster` refuses on
    /// its own if banners are off, unauthorized, or the user has already looked; nothing
    /// here second-guesses that, so there is one place where the answer is decided.
    private func postDigestBanner(_ digest: Digest, for session: AwaySession, in archive: Archive) async {
        guard let digestID = digest.id, let endedAt = session.endedAt else {
            return
        }
        let appCount = (try? archive.digestAppCount(digestID: digestID)) ?? 0
        await DigestBannerPoster().post(
            digest: digest,
            appCount: appCount,
            reason: session.reason,
            sessionEndedAt: endedAt.date,
            popoverLastOpenedAt: statusItem?.lastOpenedAt
        )
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
            // 🔒 The real exclusion list, not the `AllowAllApps` default. Without this
            // line a password manager's notifications are parsed and archived like any
            // other app's (Privacy Invariant #3).
            exclusions: ArchiveExclusionList(archive: archive),
            // 🔒 The real redactor, not the `NoRedaction` default. This is the only place
            // it is installed: a build that dropped this line would archive one-time
            // codes in plain text and nothing else would notice, because every other
            // component would behave exactly as it does now (Privacy Invariant #2).
            redactor: PerAppOTPRedaction(),
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

    /// Builds the app's one `RulesEngine` and starts its observation.
    ///
    /// Ordered after `startCapture()`, for the same reason every other `start…()` method
    /// here is: no archive means nothing to compile rules against or mute an app in. Ordered
    /// before `startAwayTracking()` and `startInterface()`, which is the part that actually
    /// matters — both hand this instance out (`AwaySessionRecorder`'s digest build,
    /// `TimelineStore`'s `regroup()`), and a `nil` engine there would silently fall back to
    /// `NoTriage`, leaving every rule with no visible effect until the next launch.
    ///
    /// `start()` only subscribes; the first snapshot is not required to have landed by the
    /// time this method returns. Until it does, `evaluate(_:)` answers `Triage.none` for
    /// every row — the same "no rules yet" state a fresh install with zero rules is in
    /// anyway, so there is nothing to wait for here.
    private func startRules() {
        guard let archive else {
            return
        }
        let engine = RulesEngine(archive: archive)
        engine.start()
        rulesEngine = engine
    }

    /// Starts watching for the user going away, and writes finished sessions down.
    ///
    /// Ordered after `startCapture()` because it needs the archive that opened there — no
    /// archive means no place to put a session, so there is no point tracking one. The
    /// digest that reads these rows arrives with its own board task; until then the
    /// sessions are what makes `is:missed` and the unread anchor honest
    /// (docs/features/MISSED_DIGEST.md#the-away-session-model).
    private func startAwayTracking() {
        guard let archive else {
            return
        }

        // A session left open by a crash or a power loss would sit in the table looking
        // like the user never came back, which is exactly the state the unread anchor
        // reads. Closing it at launch is the honest repair: the end is unknown, and now
        // is the last moment we can prove the Mac was in use.
        do {
            let closed = try archive.closeOpenAwaySessions(endedAt: Date())
            if closed > 0 {
                logger.notice("closed \(closed, privacy: .public) away session(s) left open by a previous run")
            }
        } catch {
            let detail = (error as? ArchiveError)?.logDescription ?? ArchiveError.detail(from: error)
            logger.error("could not close stale away sessions: \(detail, privacy: .public)")
        }

        // `archive`, not `self`: `Archive` is `Sendable`, so the insert runs on the
        // tracker's executor instead of hopping to the main actor. A synchronous SQLite
        // write on the main thread would block behind whatever write lock capture is
        // holding, and a 500-record batch is not a wait the menu bar should take.
        // Recording, linking and building live in `BackglanceCore` so the whole chain can
        // be driven by a test; this closure only decides what the *app* does afterwards.
        let recorder = AwaySessionRecorder(archive: archive, triage: triage)
        let tracker = AwaySessionTracker(minDuration: DigestThreshold.minDuration()) { [weak self] ended in
            guard let outcome = recorder.record(ended), let digest = outcome.digest else {
                return
            }
            // The banner is the only part of this that has to be on the main actor, and it
            // is the only part that can wait: the digest is already written and the popover
            // will show it whether or not this hop ever completes.
            Task { @MainActor in
                await self?.postDigestBanner(digest, for: outcome.session, in: archive)
            }
        }
        let bridge = AwayEventBridge(tracker: tracker)
        bridge.start()

        // ⚠️ Focus has no public API, so this reads a private file and may simply not
        // work. It feeds the same tracker directly rather than through the bridge: the
        // watcher already delivers on its own queue, and routing a background event
        // through the main actor to reach an actor would be a hop for nothing.
        let focus = FocusAssertionWatcher { status in
            switch status {
            case .active:
                Task { await tracker.handle(.focusChanged(active: true)) }

            case .inactive:
                Task { await tracker.handle(.focusChanged(active: false)) }

            case .unavailable:
                // Clearing matters as much as the watcher stopping. Focus detection can
                // fail *after* reporting `.active` — the file is replaced with a shape we
                // do not know while a Focus is on — and a cause that never clears is a
                // session that never ends. Sessions keep forming from lock and sleep.
                Task { await tracker.handle(.focusChanged(active: false)) }
            }
        }
        focus.start()

        // ⚠️ Also heuristic, and polled — there is no notification for "a share toolbar
        // appeared". The policy is read per sample rather than captured, so editing the
        // allowlist in Settings takes effect at the next poll instead of the next launch.
        let presentation = PresentationDetector(
            policy: { PresentationPolicy(defaults: .standard) },
            onChange: { presenting in
                Task { await tracker.handle(.presentingChanged(active: presenting)) }
            }
        )
        presentation.start()

        awayTracker = tracker
        awayBridge = bridge
        focusWatcher = focus
        presentationDetector = presentation
    }

    /// Starts the prune loop.
    ///
    /// Third of the four, ahead of `startInterface()`, because that method builds the
    /// settings window and the Retention pane's model needs a `RetentionJob` reference to
    /// hand its "Run cleanup now" button. That ordering does not cost the popover anything:
    /// this method only constructs the actor and fires `Task { await job.start() }`, and
    /// `start()` itself does no real work until its launch delay elapses — thirty seconds
    /// behind even a build that called it first, so the writer capture and the popover want
    /// at launch is still free until well after both have painted.
    ///
    /// No archive means nothing to prune, which is the same reason `startInterface()`
    /// gives up early.
    private func startRetention() {
        guard let archive else {
            return
        }
        let job = RetentionJob(archive: archive)
        retention = job
        Task { await job.start() }
    }
}
