import AppKit
import BackglanceCore
import Foundation
import Observation

// MARK: - NotificationActionHandler

/// The single coordinator behind every notification action — context menu, keyboard
/// shortcut, and hover button all call through this one type, so behaviour can never
/// diverge between the menu bar popover and the full timeline window.
///
/// `docs/features/ACTIONS.md` places this type in the app target, next to
/// `NSWorkspace` and `NSPasteboard`. It lives in `BackglanceUI` instead: the app
/// target ships only an XCUITest bundle, which drives the built app end to end but
/// cannot unit-test a class in isolation, and a coordinator this central needs
/// exactly that — see ``NotificationActionHandlerTests`` in
/// `Tests/BackglanceUITests`. `BackglanceUI` already reaches into AppKit where a
/// feature needs it (`PrivacySettingsView`'s `NSWorkspace.shared.activateFileViewerSelecting`
/// is one example), so nothing about the module boundary rules this out.
///
/// BACKGLANCE-196 delivered the coordinator skeleton: the type, its dependencies,
/// the shared ``fetch(_:)`` helper every action reads through, and the
/// ``ActionDispatching`` seam view code reaches it by. Open (BACKGLANCE-197), Copy
/// (BACKGLANCE-198) and Delete/Undo (BACKGLANCE-199) have landed on top of it;
/// Pin/Read, System Settings and Export are still separate follow-up tasks — see
/// docs/features/ACTIONS.md#notificationactionhandler for the full shape this class
/// grows into.
///
/// `@MainActor` because `NSWorkspace` and `NSPasteboard` (used by the actions layered
/// on top) are main-thread APIs, and because the view layer that calls this is
/// already on the main actor — there is no path where dispatching an action from a
/// background context would be correct.
///
/// `@Observable` since Delete/Undo: ``pendingUndo`` is what a host view renders the
/// undo toast from, and this is the pattern the rest of `BackglanceUI` already uses
/// for view-facing state (``DigestViewModel``, ``WipeConfirmationModel``) rather than
/// the docs/features/ACTIONS.md sketch's `onUndoStateChanged` closure — a stored
/// closure is one more thing a host has to remember to wire up and can silently not
/// call if it forgets, where an `@Observable` property just is the state, read the
/// same way any other one on this handler would be.
@MainActor
@Observable
public final class NotificationActionHandler: ActionDispatching {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - archive: the archive every action reads and writes.
    ///   - triage: the seam `RulesEngine` will conform to once rules ship — see
    ///     ``TriageEvaluating``. Defaults to ``NoTriage``, matching the timeline's own
    ///     default until then; a later action task passes the real engine in without
    ///     this initializer changing shape.
    ///   - workspace: the seam `OpenAction` reaches `NSWorkspace` through — see
    ///     ``AppLaunching``. Defaults to ``NSWorkspaceAppLauncher``, the real
    ///     conformance; tests pass a fake that records calls and never launches
    ///     anything.
    ///   - pasteboard: the seam `CopyAction` reaches `NSPasteboard` through —
    ///     see ``PasteboardWriting``. Defaults to `.general`, the real
    ///     pasteboard; tests pass either a private named pasteboard
    ///     (`NSPasteboard(name:)`, which conforms with no wrapper needed) or a
    ///     fake that reports failure, to reach `ActionError.pasteboardFailure`.
    ///   - undoClock: the seam the undo toast's 5-second expiry reaches `Task.sleep`
    ///     through — see ``UndoClock``. Defaults to ``SystemUndoClock``, the real
    ///     clock; tests pass one that resolves only when told to, so an expiry
    ///     assertion never costs the suite five real seconds.
    public init(
        archive: Archive,
        triage: any TriageEvaluating = NoTriage(),
        workspace: any AppLaunching = NSWorkspaceAppLauncher(),
        pasteboard: any PasteboardWriting = NSPasteboard.general,
        undoClock: any UndoClock = SystemUndoClock()
    ) {
        self.archive = archive
        self.triage = triage
        self.workspace = workspace
        self.pasteboard = pasteboard
        self.undoClock = undoClock
    }

    // MARK: Public

    /// The ids the most recent ``delete(ids:)`` call actually soft-deleted, while its
    /// undo toast is showing. Empty means there is nothing to undo — no toast on
    /// screen, and ``undoDelete()`` is a no-op. A host view (`UndoToastView`'s owner)
    /// reads this directly rather than through a callback: `@Observable` is what makes
    /// that safe, the same way `DigestViewModel`'s published state is.
    public private(set) var pendingUndo: [Int64] = []

    /// The ↩ / "Open in ‹App›" path: the full three-step ordering in
    /// docs/features/ACTIONS.md#open-openaction-and-deeplinkresolver, then a
    /// mark-read. Marking read happens only after `OpenAction` actually
    /// succeeded — a click that ends in `.appNotInstalled` or `.launchFailed`
    /// opened nothing, so there is nothing to mark as seen.
    ///
    /// - Throws: whatever ``OpenAction/run(deepLink:bundleID:)`` throws, or
    ///   an ``ActionError`` from ``fetch(_:)`` / `Archive.markRead(_:)`.
    public func openNotification(id: Int64) async throws {
        let (notification, app) = try fetch(id)
        try await OpenAction(workspace: workspace).run(deepLink: notification.deepLink, bundleID: app.bundleId)
        do {
            _ = try archive.markRead(id)
        } catch {
            throw ActionError.archive(reason: ArchiveError.detail(from: error))
        }
    }

    /// The ⌘↩ "Open Link only" path: opens `deep_link` and nothing else — no
    /// app-activation fallback, and no mark-read (docs/features/ACTIONS.md's
    /// Archive Tables Involved table lists `is_read` as written by "Mark
    /// read/unread, Open", not by this path).
    ///
    /// - Throws: ``ActionError/deepLinkUnresolvable(notificationID:)`` when
    ///   there is no link, it does not parse, or nothing handled it.
    public func openLink(id: Int64) throws {
        let (notification, _) = try fetch(id)
        try OpenAction(workspace: workspace).openLink(deepLink: notification.deepLink, notificationID: id)
    }

    /// The ⌘C / ⌥⌘C path: fetches every id through the shared ``fetch(_:)``
    /// helper, preserving `ids`' order, and hands the results to `CopyAction`
    /// to build the text and write it concealed. See
    /// docs/features/ACTIONS.md#copy.
    ///
    /// - Throws: ``ActionError/notFound(notificationID:)`` (propagated from
    ///   ``fetch(_:)``) the moment any id no longer resolves — a multi-select
    ///   copy either copies everything or copies nothing, never a partial
    ///   pasteboard silently missing one row — or
    ///   ``ActionError/pasteboardFailure`` if the concealed write itself
    ///   failed.
    public func copy(ids: [Int64], includeAppAndTimestamp: Bool) throws {
        let items = try ids.map { try fetch($0) }
        try CopyAction(includeAppAndTimestamp: includeAppAndTimestamp, pasteboard: pasteboard).run(items)
    }

    /// ⌫ / ⌦: soft-deletes `ids` and (re)starts the 5-second undo window.
    ///
    /// Per docs/features/ACTIONS.md#undo-toast, a second delete that lands before the
    /// first toast expires *replaces* the pending set rather than adding to it — the
    /// toast always describes the most recent delete, never a running total, so the
    /// previous timer is cancelled unconditionally before this one's ids are stored.
    /// ``Archive/softDelete(_:)`` may return fewer ids than were asked for (some were
    /// already deleted by another window); when it returns none at all there is
    /// nothing new to undo, so no toast — and no timer — is started for a delete that
    /// changed nothing.
    ///
    /// - Throws: ``ActionError/archive(reason:)`` if the soft delete write itself
    ///   failed. The previous pending undo, if any, is still cancelled in that case —
    ///   a failed second delete should not leave a stale toast offering to undo
    ///   something that already expired in the user's mind.
    public func delete(ids: [Int64]) throws {
        undoExpiry?.cancel()
        undoExpiry = nil
        let flipped: [Int64]
        do {
            flipped = try archive.softDelete(ids)
        } catch {
            pendingUndo = []
            let detail = ArchiveError.detail(from: error)
            Log.ui.error("softDelete failed for \(ids.count) id(s): \(detail)")
            throw ActionError.archive(reason: detail)
        }
        pendingUndo = flipped
        guard !flipped.isEmpty else {
            return
        }
        undoExpiry = Task { [weak self, undoClock] in
            try? await undoClock.sleep(seconds: Self.undoWindowSeconds)
            guard let self, !Task.isCancelled else {
                return
            }
            // 🔒 The one thing this design is easiest to get backwards: expiry is not
            // undo's opposite. It only takes the toast down — the rows it named stay
            // `is_deleted = 1` exactly as `delete(ids:)` left them, and `RetentionJob`
            // hard-prunes them later on its own schedule, same as any other
            // soft-deleted row. Calling `archive.restore` here would silently bring
            // back notifications the user asked to delete and then never touched
            // again, which is the opposite of what a toast timing out means.
            pendingUndo = []
        }
    }

    /// ⌘Z while the undo toast is showing: restores exactly the ids the most recent
    /// ``delete(ids:)`` call flipped, and takes the toast down.
    ///
    /// Silently does nothing when ``pendingUndo`` is already empty — per
    /// docs/features/ACTIONS.md's keyboard shortcut table, ⌘Z is scoped to "while the
    /// toast is visible", so pressing it with no toast on screen is an ordinary
    /// keyboard miss, not a mistake worth a beep or an error.
    ///
    /// The toast is taken down before the restore write runs, and stays down even if
    /// that write throws — the same reasoning as `DigestViewModel.dismiss()`: the one
    /// click Undo promises has visibly happened by the time this returns, and leaving
    /// the toast up because the write failed underneath it would make that click a
    /// lie.
    ///
    /// - Throws: ``ActionError/archive(reason:)`` if the restore write itself failed.
    public func undoDelete() throws {
        guard !pendingUndo.isEmpty else {
            return
        }
        let ids = pendingUndo
        undoExpiry?.cancel()
        undoExpiry = nil
        pendingUndo = []
        do {
            _ = try archive.restore(ids)
        } catch {
            let detail = ArchiveError.detail(from: error)
            Log.ui.error("restore failed for \(ids.count) id(s): \(detail)")
            throw ActionError.archive(reason: detail)
        }
    }

    // MARK: Internal

    /// Whether the context menu's "Open Link" item should appear at all — a
    /// `static` function, not an instance method, because the answer depends
    /// only on the stored `deep_link` string, not on anything this handler
    /// owns (no archive read, no workspace call). A dedicated value type felt
    /// like overhead for one `Bool`: this and ``canActivateApp(bundleID:)``
    /// answer two unrelated questions about two unrelated inputs, and forcing
    /// them into one struct would make every call site build the half it
    /// does not need.
    ///
    /// Delegates to ``OpenAction/parsedURL(_:)`` and
    /// ``OpenAction/hasPathOrQuery(_:)`` so the menu's definition of "differs
    /// from plain app activation" can never drift from `OpenAction`'s own.
    static func showsOpenLink(deepLink: String?) -> Bool {
        guard let url = OpenAction.parsedURL(deepLink) else {
            return false
        }
        return OpenAction.hasPathOrQuery(url)
    }

    /// The read every action starts from: the notification and the app that sent it.
    ///
    /// Synchronous, like every other `Archive` read in this codebase (see
    /// `Archive+Timeline.swift`) — there is no `await` between a menu click and the
    /// row it acts on, so an action that turns out to be a single read should not pay
    /// for a hop to another executor. Internal rather than private because every
    /// action this handler grows (Open, Copy, Delete, Pin/Read, …) starts here, and
    /// so does ``NotificationActionHandlerTests``, which reaches it through
    /// `@testable import BackglanceUI`.
    ///
    /// - Throws: ``ActionError/notFound(notificationID:)`` when the notification or
    ///   its owning app row is gone — the ordinary result of the row having been
    ///   deleted, by this window or another, between the click and this read.
    ///   Any other failure is wrapped as ``ActionError/archive(reason:)``.
    func fetch(_ id: Int64) throws -> (ArchivedNotification, AppRecord) {
        do {
            return try archive.pool.read { db in
                guard let notification = try ArchivedNotification.fetchOne(db, key: id),
                      let app = try AppRecord.fetchOne(db, key: notification.appId)
                else {
                    throw ActionError.notFound(notificationID: id)
                }
                return (notification, app)
            }
        } catch let error as ActionError {
            Log.ui.error("fetch(id: \(id)) failed: not found")
            throw error
        } catch {
            // 🔒 `ArchiveError.detail(from:)`, never `error.localizedDescription`: in a
            // DEBUG build GRDB spells out a failing statement's bound arguments, and the
            // statement here is a notification fetch keyed by id — nothing to bind but
            // the id itself, but the habit is what keeps the next call site safe too.
            let detail = ArchiveError.detail(from: error)
            Log.ui.error("fetch(id: \(id)) failed: \(detail)")
            throw ActionError.archive(reason: detail)
        }
    }

    /// Whether the context menu's "Open in ‹App›" item should render disabled
    /// ("App not found" tooltip, per the Context Menu Specification table).
    /// Not a protocol requirement on ``ActionDispatching``: it is a question
    /// about menu state, not an action to dispatch, the same distinction that
    /// keeps ``fetch(_:)`` off the protocol too. The menu itself is a later
    /// task; this only exposes the answer it will need.
    func canActivateApp(bundleID: String) -> Bool {
        workspace.applicationURL(forBundleID: bundleID) != nil
    }

    // MARK: Private

    /// docs/features/ACTIONS.md#undo-toast: 5 seconds, fixed. Not user-configurable —
    /// a setting nobody would tune correctly under the pressure of "wait, undo!" is
    /// not worth the surface area.
    private static let undoWindowSeconds: TimeInterval = 5

    private let archive: Archive
    private let triage: any TriageEvaluating
    private let workspace: any AppLaunching
    private let pasteboard: any PasteboardWriting
    private let undoClock: any UndoClock

    /// The task counting down the current undo toast, if one is showing.
    /// `@ObservationIgnored` because a view has no business redrawing when this is
    /// replaced or cancelled — only ``pendingUndo`` changing is worth a redraw.
    @ObservationIgnored private var undoExpiry: Task<Void, Never>?
}
