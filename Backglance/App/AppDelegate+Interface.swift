import AppKit
import BackglanceCore
import BackglanceUI
import Foundation

// MARK: - AppDelegate + interface

/// Building the timeline and everything that shows it: the store, the two surfaces, the
/// coordinator every row action dispatches through, search, the digest presenter, the
/// status item and the global hot key.
///
/// Split out of `AppDelegate.swift` along the same seam as `AppDelegate+CaptureStatus.swift`
/// and `AppDelegate+Onboarding.swift`: composing the interface is one job with a dozen
/// collaborators, and keeping it here is what holds `AppDelegate.swift` inside SwiftLint's
/// file-length limit as that list grows.
extension AppDelegate {
    /// Builds the timeline and everything that shows it.
    ///
    /// Without an archive there is nothing to show, so the interface is simply
    /// not built — the alternative, a status item whose popover explains that
    /// the database could not be opened, is a window's worth of apology that
    /// onboarding will do properly (docs/features/PERMISSIONS_PRIVACY.md).
    func startInterface() {
        guard let archive else {
            return
        }

        let store = TimelineStore(archive: archive, triage: triage, host: .popover)
        let banners = makeBannerModel()
        self.banners = banners
        // One coordinator for the whole app, handed to both surfaces below.
        //
        // Not one per surface: `pendingUndo` lives on this object and the undo toast is
        // read from it, so two handlers would mean deleting in the window and finding no
        // toast to undo with in the popover — the same reasoning `startRules()` gives for
        // a single `RulesEngine`.
        //
        // Until this existed, `\.actionDispatcher` was never set anywhere in the app
        // target, so `NotificationRow`'s context menu rendered empty and every keyboard
        // handler needing a dispatcher returned `.ignored`: the whole actions layer was
        // unreachable in the shipping app despite being implemented and tested
        // (BACKGLANCE-242).
        let actionHandler = NotificationActionHandler(archive: archive, triage: triage)
        self.actionHandler = actionHandler
        // No window is built here. It gets its own `host: .window` store, and building
        // both eagerly would open a second timeline subscription and a second page cache
        // at launch for a window most launches never show — see `showTimelineWindow()`.
        //
        // Search owns the semantic model and the background indexer, both of
        // which stay asleep until the user turns the setting on.
        //
        // `triage` is the same `RulesEngine` the timeline evaluates through, threaded in
        // so `is:vip` and pinned-first ordering in search agree with what the timeline
        // draws. Without it `HybridSearch` fell back to `NoTriage()` and every VIP rule
        // was invisible to search (BACKGLANCE-241).
        let search = SearchService(archive: archive, triage: triage)
        search.start()
        let settings = settingsWindow(search: search, archive: archive, retention: retention)
        // The field's own state: what was typed, what came back, what is still
        // in flight. It asks `search` its questions through `SearchRunning`.
        // Read per call rather than captured once: the toggle can change
        // between one keystroke and the next.
        let semanticEnabled: @Sendable () -> Bool = { [weak search] in
            MainActor.assumeIsolated { search?.semanticEnabled ?? false }
        }
        let searchModel = SearchViewModel(search: search, semanticEnabled: semanticEnabled)
        // Holds whichever digest is waiting to be seen. It reads the archive only when
        // the popover is about to open, so an app that never comes back from an away
        // session never asks the question.
        let digests = DigestPresenter(archive: archive)
        digests.onOpenTimeline = { [weak self] _ in self?.showTimelineWindow() }
        let statusItem = StatusItemController(
            store: store,
            search: searchModel,
            searchService: search,
            digests: digests,
            banners: banners,
            actions: actionHandler,
            menuActions: menuActions(settings: settings)
        )
        // Registration fails when another app already owns ⌃⌥N. That is a note
        // in Settings, not a failure to launch: the status item still works.
        let hotKeys = HotKeyCenter { [weak statusItem] in statusItem?.togglePopover() }
        hotKeys.register()

        self.store = store
        self.search = search
        self.searchModel = searchModel
        self.digests = digests
        self.settings = settings
        self.statusItem = statusItem
        self.hotKeys = hotKeys
        mirrorCaptureStatus()
    }

    /// Brings the full timeline window up, building it and its store the first time.
    ///
    /// The window's store is its own `TimelineStore(host: .window)`, not the popover's.
    /// `Host` is fixed at init and is not decoration: `TimelineStore+Selection` refuses
    /// every multi-select mutator unless `host == .window`, `NotificationRowMenu` hides
    /// "Export Selection…" outside it, and each host reads its view mode and grouping
    /// from its own defaults key. Handing the window the popover's store — which is what
    /// this did until BACKGLANCE-243 — silently disabled ⌘A, ⇧-click, ⌘E and the export
    /// menu item in the one surface they were written for, and collapsed both hosts onto
    /// the popover's remembered layout.
    ///
    /// Built here rather than in ``startInterface()`` because the second store is not
    /// free: it opens its own `timelineSnapshots` subscription and keeps its own page
    /// cache of up to `TimelineStore.maxRows` rows. A launch that never opens the window
    /// should not pay for either, and most launches never do — the popover is the whole
    /// point of a menu bar app.
    ///
    /// The new store is seeded from ``AppDelegate/lastCaptureState`` before anything can
    /// draw it. The status mirror only pushes on the engine's *next* value, so a store
    /// born after capture went degraded would otherwise show a running banner over a
    /// timeline that had stopped growing.
    func showTimelineWindow() {
        if let window {
            window.show()
            return
        }
        guard let archive else {
            return
        }
        let store = TimelineStore(archive: archive, triage: triage, host: .window)
        store.captureState = lastCaptureState
        windowStore = store
        let window = TimelineWindowController(store: store, banners: banners, actions: actionHandler)
        self.window = window
        window.show()
    }

    /// The four verbs the status item's menu needs, built apart from ``startInterface()``
    /// only because composing them inline pushes that function past SwiftLint's
    /// body-length limit. One parameter, not the whole interface: everything else these
    /// closures touch, they reach through `self` — including the window, which does not
    /// exist yet when this is called (``showTimelineWindow()``).
    private func menuActions(settings: SettingsWindowController) -> StatusItemController.MenuActions {
        StatusItemController.MenuActions(
            openWindow: { [weak self] in self?.showTimelineWindow() },
            pause: { [weak self] choice in
                guard let engine = self?.engine else {
                    return
                }
                Task { await engine.pause(choice) }
            },
            resume: { [weak self] in
                guard let engine = self?.engine else {
                    return
                }
                Task { await engine.resume() }
            },
            openSettings: { settings.show() }
        )
    }
}
