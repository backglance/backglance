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
        let window = TimelineWindowController(store: store, banners: banners, actions: actionHandler)
        // Search owns the semantic model and the background indexer, both of
        // which stay asleep until the user turns the setting on.
        let search = SearchService(archive: archive)
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
        digests.onOpenTimeline = { _ in window.show() }
        let statusItem = StatusItemController(
            store: store,
            search: searchModel,
            searchService: search,
            digests: digests,
            banners: banners,
            actions: actionHandler,
            menuActions: menuActions(window: window, settings: settings)
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
        self.window = window
        self.statusItem = statusItem
        self.hotKeys = hotKeys
        mirrorCaptureStatus(into: store)
    }

    /// The four verbs the status item's menu needs, built apart from ``startInterface()``
    /// only because composing them inline pushes that function past SwiftLint's
    /// body-length limit. Two parameters, not the whole interface: everything else these
    /// closures touch, they reach through `self`.
    private func menuActions(
        window: TimelineWindowController,
        settings: SettingsWindowController
    ) -> StatusItemController.MenuActions {
        StatusItemController.MenuActions(
            openWindow: { window.show() },
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
