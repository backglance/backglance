import AppKit
import BackglanceCore
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

    /// `backglance://open?id=` — opens the timeline window.
    ///
    /// - Note: BACKGLANCE-244 reveals `uuid` in the timeline and shows the "Not in the
    ///   archive" toast when it is not there (docs/api/API_DOCUMENTATION.md#error-behavior).
    ///   Two surfaces that needs do not exist yet, and this deliberately does not invent
    ///   either to close the gap early: `Archive` has no public uuid → row lookup (only
    ///   the private `ArchivedNotification.filter(Column("uuid") == …)` GRDB uses
    ///   internally for upsert), and `BackglanceUI` has no generic toast surface —
    ///   `UndoToastView` renders one specific message for one specific action, not an
    ///   arbitrary string a caller outside the undo flow could hand it. Until that task
    ///   lands, this opens the window, which is real progress toward the doc's contract,
    ///   but does not scroll to or select the row, and never shows the "not found" case.
    func performOpen(uuid _: UUID) {
        showTimelineWindow()
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
