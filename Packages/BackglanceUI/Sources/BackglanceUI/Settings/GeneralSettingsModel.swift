import Foundation
import Observation

// MARK: - LaunchAtLoginOutcome

/// What asking `SMAppService` to change actually did.
///
/// `SMAppService.register()`/`.unregister()` both `throws`, and `BackglanceUI` cannot see
/// `ServiceManagement` at all (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction)
/// — so the app shell's `LaunchAtLogin` catches the throw itself and hands back this instead,
/// the same shape `ArchiveError` reduces to a `String` for every other settings model in this
/// file's neighbourhood. `Equatable` and not `Error`-typed on purpose: tests assert on it
/// directly rather than pattern-matching an opaque `Error`.
public enum LaunchAtLoginOutcome: Sendable, Equatable {
    case success(LoginItemStatus)
    case failure(String)
}

// MARK: - LaunchAtLoginControl

/// The General pane's one write into `SMAppService`, and the one read that keeps it honest.
///
/// Bundled into one value for the reason ``BannerAuthorizing`` and ``PermissionsActions``
/// already give: same-typed closures invite a silent mis-wiring, and grouping them makes
/// that mistake unspellable rather than merely documented.
public struct LaunchAtLoginControl: Sendable {
    // MARK: Lifecycle

    public init(
        readStatus: @escaping @Sendable () -> LoginItemStatus = { .unavailable },
        setEnabled: @escaping @Sendable (Bool) -> LaunchAtLoginOutcome = { _ in
            .failure(String(localized: "Not available in this preview."))
        }
    ) {
        self.readStatus = readStatus
        self.setEnabled = setEnabled
    }

    // MARK: Public

    /// Re-reads `SMAppService.mainApp.status`. Called on appearance, because System
    /// Settings can grant the pending approval — or a managed Mac's MDM policy can revoke
    /// it — while this window sits open.
    public let readStatus: @Sendable () -> LoginItemStatus

    /// Registers or unregisters, and reports what actually happened.
    public let setEnabled: @Sendable (Bool) -> LaunchAtLoginOutcome
}

// MARK: - HotKeyControl

/// What the General pane can ask about ⌃⌥N, and the one thing it can ask it to do.
///
/// `HotKeyCenter` is Carbon-backed AppKit plumbing and lives in `Backglance/App/`, out of
/// `BackglanceUI`'s reach the same way `SMAppService` is — so this is a read and a retry,
/// not the registrar itself.
public struct HotKeyControl: Sendable {
    // MARK: Lifecycle

    public init(
        isRegistered: @escaping @Sendable () -> Bool = { true },
        retry: @escaping @Sendable () -> Bool = { false }
    ) {
        self.isRegistered = isRegistered
        self.retry = retry
    }

    // MARK: Public

    /// Whether ⌃⌥N is currently Backglance's. Re-read on appearance; the usual way this
    /// changes while Settings is open is the user quitting whatever app was holding it.
    public let isRegistered: @Sendable () -> Bool

    /// Asks `HotKeyCenter` to claim the shortcut again, and reports whether it now holds
    /// it. `HotKeyCenter.register()` is idempotent and safe to call after a failure, which
    /// is what makes "Try Again" a real button rather than one that only works once.
    public let retry: @Sendable () -> Bool
}

// MARK: - SemanticSearchControl

/// The Search section's bridge into `SearchService`, the app shell's `@Observable` object
/// (`Backglance/App/SearchService.swift`) that owns the embeddings model and the background
/// indexer.
///
/// A closure bundle rather than the object itself, for the same reason ``SearchRunning``
/// exists for the search field: `BackglanceUI` must never import `BackglanceSearch`
/// (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction), and `SearchService`
/// lives in the app target precisely because it is the one place both `BackglanceUI` and
/// `BackglanceSearch` are visible at once. Every closure is synchronous — `SearchService`'s
/// properties are plain `@MainActor` state, not `async` calls — so there is no `await`
/// anywhere in the app shell's wiring of this value.
public struct SemanticSearchControl: Sendable {
    // MARK: Lifecycle

    public init(
        isAvailable: @escaping @Sendable () -> Bool = { false },
        isEnabled: @escaping @Sendable () -> Bool = { false },
        setEnabled: @escaping @Sendable (Bool) -> Void = { _ in },
        progress: @escaping @Sendable () -> (done: Int, total: Int)? = { nil },
        deleteEmbeddings: @escaping @Sendable () -> Void = {}
    ) {
        self.isAvailable = isAvailable
        self.isEnabled = isEnabled
        self.setEnabled = setEnabled
        self.progress = progress
        self.deleteEmbeddings = deleteEmbeddings
    }

    // MARK: Public

    /// Whether this Mac has the on-device sentence model at all.
    public let isAvailable: @Sendable () -> Bool

    /// `search.semanticEnabled`, read fresh — there is no notification when it changes
    /// from elsewhere, but nothing else in the app writes it, so a read on appearance is
    /// enough.
    public let isEnabled: @Sendable () -> Bool

    /// Flips the setting on `SearchService`, which is what actually starts or stops
    /// `EmbeddingIndexer` — writing the stored preference alone would persist the choice
    /// without ever acting on it.
    public let setEnabled: @Sendable (Bool) -> Void

    /// How far the background indexer has got, or `nil` while it is not running.
    public let progress: @Sendable () -> (done: Int, total: Int)?

    public let deleteEmbeddings: @Sendable () -> Void
}

// MARK: - GeneralSettingsModel

/// Settings ▸ General's state: launch at login, the ⌃⌥N shortcut's note, semantic search,
/// and the digest it composes rather than reimplements.
///
/// This pane is where BACKGLANCE-213 and the search/digest sections that used to sit inline
/// in `SettingsView.swift` (`Backglance/Scenes/Settings/SettingsView.swift`'s stale doc
/// comment promised this "in Phase 4.3") land together. Every OS-facing read and write is
/// injected through a closure bundle — ``LaunchAtLoginControl``, ``HotKeyControl``,
/// ``SemanticSearchControl`` — because none of the three APIs behind them
/// (`ServiceManagement`, Carbon, `BackglanceSearch`) is reachable from this package
/// (docs/getting-started/DEVELOPMENT_GUIDE.md#dependency-direction). That is also what makes
/// this model testable without `SMAppService` ever running: a test hands it stub closures
/// and asserts on what they were called with.
///
/// See docs/features/PERMISSIONS_PRIVACY.md#launch-at-login,
/// docs/architecture/ARCHITECTURE.md#app-shell-backglance-target.
@MainActor
@Observable
public final class GeneralSettingsModel {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - digest: the Digest section's own model, composed rather than reimplemented — the
    ///     same relationship ``PrivacySettingsModel`` has to ``RetentionSettingsModel`` and
    ///     the others.
    ///   - search: the Search section's bridge into `SearchService`. Defaults leave the
    ///     toggle inert, for previews and tests that do not care about it.
    ///   - launchAtLogin: the app shell's `SMAppService` bridge.
    ///   - hotKey: the app shell's `HotKeyCenter` bridge.
    public init(
        digest: DigestSettingsModel,
        search: SemanticSearchControl = SemanticSearchControl(),
        launchAtLogin: LaunchAtLoginControl = LaunchAtLoginControl(),
        hotKey: HotKeyControl = HotKeyControl()
    ) {
        self.digest = digest
        self.search = search
        self.launchAtLogin = launchAtLogin
        self.hotKey = hotKey

        isSemanticAvailable = search.isAvailable()
        indexProgress = search.progress()
        isSyncingSemantic = true
        semanticEnabled = search.isEnabled()
        isSyncingSemantic = false

        // Locals, not a read of `loginItemStatus` back: every stored property has to carry
        // a value before `self` can be used for anything, including reading one of its own
        // already-assigned properties — so the initial status is threaded through a local
        // rather than reordered around that rule.
        let initialStatus = launchAtLogin.readStatus()
        loginItemStatus = initialStatus
        isSyncingLaunchAtLogin = true
        launchAtLoginEnabled = Self.isOnOrPending(initialStatus)
        isSyncingLaunchAtLogin = false

        isHotKeyRegistered = hotKey.isRegistered()
    }

    // MARK: Public

    /// The Digest section's model. Held, not owned in the sense of writing to it — this
    /// class never touches its state, only hands it to `DigestSettingsView`.
    public let digest: DigestSettingsModel

    public private(set) var isSemanticAvailable: Bool
    public private(set) var indexProgress: (done: Int, total: Int)?

    public private(set) var loginItemStatus: LoginItemStatus

    /// Set only when a register/unregister call itself failed — never for `.requiresApproval`,
    /// which is not a failure, just a state the pane's status text explains on its own.
    public private(set) var launchAtLoginFailure: String?

    public private(set) var isHotKeyRegistered: Bool

    /// Whether the on-device model runs on every notification as it arrives.
    ///
    /// Writes through `search.setEnabled(_:)` immediately, which is what actually starts or
    /// stops the background indexer — this property is not a preference that waits for an
    /// "Apply" step.
    public var semanticEnabled: Bool {
        didSet {
            guard semanticEnabled != oldValue, !isSyncingSemantic else {
                return
            }
            search.setEnabled(semanticEnabled)
            refreshIndexProgress()
        }
    }

    /// Whether Backglance opens automatically at login.
    ///
    /// Flips immediately, the same posture ``DigestSettingsModel/bannerEnabled`` takes for
    /// the same reason: a `Toggle` needs a binding that answers synchronously, and
    /// ``applyLaunchAtLogin(_:)`` corrects it afterwards if the write did not stick —
    /// `.requiresApproval` leaves it look "on" (macOS agrees it is registered, only not yet
    /// approved), and only an outright failure snaps it back.
    public var launchAtLoginEnabled: Bool {
        didSet {
            guard launchAtLoginEnabled != oldValue, !isSyncingLaunchAtLogin else {
                return
            }
            applyLaunchAtLogin(launchAtLoginEnabled)
        }
    }

    /// Re-reads everything that can change while Settings sits open: System Settings can
    /// grant the pending login-item approval, refuse or revoke it, and another app can let
    /// go of ⌃⌥N. Called on appearance.
    public func refresh() {
        isSemanticAvailable = search.isAvailable()
        isSyncingSemantic = true
        semanticEnabled = search.isEnabled()
        isSyncingSemantic = false
        refreshIndexProgress()

        loginItemStatus = launchAtLogin.readStatus()
        isSyncingLaunchAtLogin = true
        launchAtLoginEnabled = Self.isOnOrPending(loginItemStatus)
        isSyncingLaunchAtLogin = false

        isHotKeyRegistered = hotKey.isRegistered()
    }

    /// Re-reads only the indexer's progress. Split out from ``refresh()`` so a view can poll
    /// this alone while indexing runs, without re-triggering the toggle's own `didSet` or
    /// re-asking `SMAppService` on every tick — see `GeneralSettingsView`'s polling `.task`.
    public func refreshIndexProgress() {
        indexProgress = search.progress()
    }

    public func deleteEmbeddings() {
        search.deleteEmbeddings()
        refreshIndexProgress()
    }

    /// Asks `HotKeyCenter` to claim ⌃⌥N again. Idempotent on the app-shell side, so this is
    /// safe to press more than once — the usual reason it helps at all is that whatever else
    /// held the shortcut has since quit.
    public func retryHotKeyRegistration() {
        isHotKeyRegistered = hotKey.retry()
    }

    // MARK: Private

    private let search: SemanticSearchControl
    private let launchAtLogin: LaunchAtLoginControl
    private let hotKey: HotKeyControl

    /// Guards ``semanticEnabled``'s `didSet` against re-entering itself while ``refresh()``
    /// or the initializer assigns the value it just read back.
    private var isSyncingSemantic = false

    /// Same guard, for ``launchAtLoginEnabled``.
    private var isSyncingLaunchAtLogin = false

    /// `.registered` is plainly "on"; `.requiresApproval` also reads as "on" to the toggle —
    /// the write went through, macOS is only waiting on the user's own approval, and a
    /// toggle that snapped back to off would misreport a call that actually succeeded.
    private static func isOnOrPending(_ status: LoginItemStatus) -> Bool {
        status == .registered || status == .requiresApproval
    }

    /// Calls through to `SMAppService` via ``LaunchAtLoginControl/setEnabled``, and reflects
    /// whatever actually came back — success, pending approval, or a failure that puts the
    /// toggle back where it started.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        switch launchAtLogin.setEnabled(enabled) {
        case let .success(status):
            loginItemStatus = status
            launchAtLoginFailure = nil
            syncLaunchAtLoginToggle(for: status)

        case let .failure(message):
            launchAtLoginFailure = message
            // The write did not stick, so the toggle's own answer is whatever
            // `SMAppService` says right now — not the value the user just picked.
            loginItemStatus = launchAtLogin.readStatus()
            syncLaunchAtLoginToggle(for: loginItemStatus)
        }
    }

    private func syncLaunchAtLoginToggle(for status: LoginItemStatus) {
        isSyncingLaunchAtLogin = true
        launchAtLoginEnabled = Self.isOnOrPending(status)
        isSyncingLaunchAtLogin = false
    }
}
