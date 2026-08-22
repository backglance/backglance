import BackglanceCore
import Foundation

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
/// This task delivers the coordinator skeleton only: the type, its dependencies, the
/// shared ``fetch(_:)`` helper every action will read through, and the
/// ``ActionDispatching`` seam view code reaches it by. Open, Copy, Delete/Undo,
/// Pin/Read, System Settings and Export are separate follow-up tasks — see
/// docs/features/ACTIONS.md#notificationactionhandler for the full shape this class
/// grows into.
///
/// `@MainActor` because `NSWorkspace` and `NSPasteboard` (used by the actions layered
/// on top) are main-thread APIs, and because the view layer that calls this is
/// already on the main actor — there is no path where dispatching an action from a
/// background context would be correct.
@MainActor
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
    public init(
        archive: Archive,
        triage: any TriageEvaluating = NoTriage(),
        workspace: any AppLaunching = NSWorkspaceAppLauncher()
    ) {
        self.archive = archive
        self.triage = triage
        self.workspace = workspace
    }

    // MARK: Public

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

    private let archive: Archive
    private let triage: any TriageEvaluating
    private let workspace: any AppLaunching
}
