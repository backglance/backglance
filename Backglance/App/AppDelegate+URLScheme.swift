import AppKit
import BackglanceCore
import BackglanceUI
import Foundation

// MARK: - AppDelegate + URL scheme

/// Wires ``URLSchemeHandler`` to the surfaces `backglance://` routes drive.
///
/// Split out of `AppDelegate.swift` along the same seam as `AppDelegate+Interface.swift`
/// and `AppDelegate+CaptureStatus.swift`: one concern, kept out of the main file so that
/// one stays inside SwiftLint's length limit as this list grows.
///
/// See docs/api/API_DOCUMENTATION.md#url-scheme-backglance for the contract every method
/// below has to honour and `URLSchemeHandler.swift` for why `export` is not one of them —
/// it is v1.x, and TASKS.md's Phase 4.3 line lists only the five routes conformed to here.
extension AppDelegate: URLRoutePerforming {
    /// Builds the handler and registers it for `kAEGetURL`. Called once, from
    /// `applicationDidFinishLaunching`, after `startInterface()` — see the call site there
    /// for why that order matters.
    func startURLScheme() {
        let handler = URLSchemeHandler(performer: self)
        handler.install()
        urlSchemeHandler = handler
    }

    // MARK: URLRoutePerforming

    /// `backglance://search?q=` — prefills the query and opens the popover, in that order
    /// so the field already shows `query` by the moment the popover is on screen instead
    /// of filling in a frame later.
    func performSearch(query: String) {
        searchModel?.text = query
        statusItem?.openPopover()
    }

    /// `backglance://open?id=` — opens the timeline window, resolves `uuid` against the
    /// archive, and either reveals the row or reports it missing
    /// (docs/api/API_DOCUMENTATION.md#error-behavior).
    ///
    /// `showTimelineWindow()` runs first and synchronously: it either shows the window
    /// already built or builds one (and `windowStore` with it) before returning, so
    /// `windowStore` below is never `nil` for a reason this method needs to handle —
    /// only ``AppDelegate/archive`` being `nil` (no archive, no interface at all) can
    /// make that guard fail, the same precondition every other route in this file
    /// already assumes.
    ///
    /// The archive read and ``BackglanceUI/TimelineStore/reveal(_:)`` both run off this
    /// call's synchronous path — the former because a uuid lookup is one indexed row,
    /// the latter because it is `async` by nature (it may have to page older rows in
    /// first) — so this hands off to a `Task` rather than blocking the Apple Event
    /// dispatch thread on either.
    func performOpen(uuid: UUID) {
        showTimelineWindow()
        guard let archive, let windowStore else {
            return
        }
        Task {
            do {
                guard let notification = try archive.notification(uuid: uuid.uuidString) else {
                    // The literal failure kind only — never the uuid itself, per
                    // `Log.automation`'s own doc comment and CLAUDE.md's logging rule.
                    Log.automation.error("open: uuid not found")
                    windowStore.showMessage(String(localized: "Not in the archive"))
                    return
                }
                if await windowStore.reveal(notification) == .unreachable {
                    windowStore.showMessage(String(localized: "Not in the archive"))
                }
            } catch {
                // A failed read, not a missing row — `ArchiveError.userMessage` already
                // says something more useful than "Not in the archive" for this case
                // (docs/api/API_DOCUMENTATION.md#error-behavior's "Archive being wiped
                // or migrated" row).
                let detail = (error as? ArchiveError)?.userMessage ?? String(localized: "Not in the archive")
                windowStore.showMessage(detail)
            }
        }
    }

    /// `backglance://digest` — opens the popover; `DigestPresenter` (refreshed as part of
    /// `StatusItemController.togglePopover()`) decides on its own whether that means a
    /// digest card or "nothing missed" (`MenuBarPopoverView`'s `content`). Clearing the
    /// search field first matters because that same view shows search results ahead of
    /// the digest whenever a query is present — without this, a digest link opened after
    /// an earlier search would show stale results instead of what it promised.
    func performDigest() {
        searchModel?.clear()
        statusItem?.openPopover()
    }

    /// `backglance://pause?minutes=` — `date` is already resolved from `minutes` by
    /// ``URLSchemeHandler/perform(_:)``; `nil` pauses indefinitely, the same as
    /// ``PauseChoice/indefinitely``. A no-op with no `engine` — the same "nothing to
    /// pause" state every other capture control in this file already treats that way.
    func performPause(until date: Date?) {
        guard let engine else {
            return
        }
        Task { await engine.pause(until: date) }
    }

    /// `backglance://resume`.
    func performResume() {
        guard let engine else {
            return
        }
        Task { await engine.resume() }
    }
}
