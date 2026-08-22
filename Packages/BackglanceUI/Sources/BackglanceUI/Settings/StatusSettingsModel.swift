import BackglanceCore
import Foundation
import Observation

// MARK: - CaptureHealth

/// What the Status pane knows about capture.
///
/// Filled by the app shell from the engine's status and metrics, because `BackglanceUI` cannot
/// see `BackglanceCapture`. Every field is content-free by construction — a status, an adapter
/// id, a schema hash prefix, a time and a count — which is the same set the diagnostics export
/// writes. That is deliberate: what the user sees here is what the maintainer receives.
public struct CaptureHealth: Sendable, Equatable {
    // MARK: Lifecycle

    public init(
        status: TimelineCaptureState = .stopped,
        adapterID: String? = nil,
        fingerprint: String? = nil,
        lastTickAt: Date? = nil,
        lastTickRecords: Int = 0
    ) {
        self.status = status
        self.adapterID = adapterID
        self.fingerprint = fingerprint
        self.lastTickAt = lastTickAt
        self.lastTickRecords = lastTickRecords
    }

    // MARK: Public

    public var status: TimelineCaptureState

    /// Which adapter is reading Apple's store, or `nil` while degraded.
    public var adapterID: String?

    /// A prefix of the store's schema hash. Not content — a digest of Apple's *schema* plus
    /// version numbers — and the first thing worth knowing when a macOS update breaks capture.
    public var fingerprint: String?

    public var lastTickAt: Date?
    public var lastTickRecords: Int
}

// MARK: - ArchiveSummary

/// The archive's size and shape, as one row.
public struct ArchiveSummary: Sendable, Equatable {
    // MARK: Lifecycle

    public init(byteCount: Int64 = 0, notificationCount: Int = 0, integrityOK: Bool? = nil, checkedAt: Date? = nil) {
        self.byteCount = byteCount
        self.notificationCount = notificationCount
        self.integrityOK = integrityOK
        self.checkedAt = checkedAt
    }

    // MARK: Public

    public var byteCount: Int64
    public var notificationCount: Int

    /// `nil` until a check has run this launch — "not checked yet" is a different answer from
    /// "checked and fine", and a pane that showed a tick for the first would be lying.
    public var integrityOK: Bool?
    public var checkedAt: Date?
}

// MARK: - StatusSettingsModel

/// Settings ▸ Status: is this working, and if not, what would you need to know.
///
/// The pane exists because capture fails silently by nature. Nothing arrives to tell a user
/// that the store schema changed under a macOS update — the timeline simply stops growing, and
/// weeks can pass before anyone notices. Somewhere has to answer "is it running" plainly.
///
/// It reads the same values ``BackglanceCore/DiagnosticsExport`` writes, so what the user sees
/// is what the maintainer receives. That is worth more than it looks: a support conversation
/// where the two disagree is one nobody can make progress in.
///
/// See docs/operations/MONITORING_LOGGING.md#health-indicators-in-the-ui.
@MainActor
@Observable
public final class StatusSettingsModel {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - archive: where the size, the count and the integrity check come from.
    ///   - readCaptureHealth: the engine's status and metrics, mirrored into a UI value.
    ///   - readFullDiskAccess: the probe.
    ///   - saveDiagnostics: shows a save panel and writes the bundle. Returns where it landed,
    ///     or `nil` if the user cancelled. The app shell's, because a save panel is AppKit and
    ///     because the user must choose the destination before anything is written.
    public init(
        archive: Archive?,
        readCaptureHealth: @escaping @Sendable () async -> CaptureHealth = { CaptureHealth() },
        readFullDiskAccess: @escaping @Sendable () -> FullDiskAccessDisplayState = { .denied },
        saveDiagnostics: @escaping @Sendable (DiagnosticsExport.Options) async -> URL? = { _ in nil }
    ) {
        self.archive = archive
        self.readCaptureHealth = readCaptureHealth
        self.readFullDiskAccess = readFullDiskAccess
        self.saveDiagnostics = saveDiagnostics
    }

    // MARK: Public

    public private(set) var health = CaptureHealth()
    public private(set) var summary = ArchiveSummary()
    public private(set) var fdaState: FullDiskAccessDisplayState = .denied

    /// Set while an integrity check or an export runs, so the buttons disable rather than
    /// letting someone queue a second `PRAGMA integrity_check` over a large archive.
    public private(set) var isBusy = false

    public private(set) var failure: String?

    /// Where the last export landed, so the pane can offer to reveal it.
    public private(set) var lastExport: URL?

    /// Whether the export names apps. Off by default — see
    /// ``BackglanceCore/DiagnosticsExport``.
    public var includeAppIdentifiers = false

    public var canRunChecks: Bool {
        archive != nil && !isBusy
    }

    /// Reads everything cheap. The integrity check is *not* here: it is a full scan of the
    /// file, which on a large archive takes long enough that running it every time someone
    /// opens Settings would be its own performance bug. It has a button.
    public func load() async {
        fdaState = readFullDiskAccess()
        health = await readCaptureHealth()
        guard let archive else {
            return
        }
        do {
            let space = try archive.spaceReport()
            let count = try await archive.pool.read { database in try ArchivedNotification.fetchCount(database) }
            summary.byteCount = space.byteCount
            summary.notificationCount = count
            failure = nil
        } catch {
            failure = (error as? ArchiveError)?.userMessage ?? String(localized: "Couldn’t read the archive.")
        }
    }

    /// The full `PRAGMA integrity_check`, on demand.
    public func runIntegrityCheck() async {
        guard let archive, !isBusy else {
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let health = try archive.checkIntegrity(level: .full)
            summary.integrityOK = health.ok
            summary.checkedAt = Date()
            failure = nil
        } catch {
            summary.integrityOK = nil
            failure = (error as? ArchiveError)?.userMessage ?? String(localized: "The integrity check couldn’t run.")
        }
    }

    /// Builds the diagnostics bundle and asks the shell to save it.
    public func exportDiagnostics() async {
        guard !isBusy else {
            return
        }
        isBusy = true
        defer { isBusy = false }
        lastExport = await saveDiagnostics(.init(includeAppIdentifiers: includeAppIdentifiers))
    }

    // MARK: Private

    private let archive: Archive?
    private let readCaptureHealth: @Sendable () async -> CaptureHealth
    private let readFullDiskAccess: @Sendable () -> FullDiskAccessDisplayState
    private let saveDiagnostics: @Sendable (DiagnosticsExport.Options) async -> URL?
}
