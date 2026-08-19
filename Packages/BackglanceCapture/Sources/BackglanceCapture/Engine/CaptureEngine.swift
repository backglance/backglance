import BackglanceCore
import Foundation
import OSLog

// MARK: - CaptureEngine

/// The one thing that reads Apple's store and writes Backglance's archive.
///
/// An actor because there is exactly one of each thing it owns — the adapter, the cursor,
/// the status — and every one of them would be wrong if two ticks overlapped. A second
/// tick reading the same cursor would archive the same records twice (the unique index
/// would catch it, at the cost of a transaction each) and, worse, could persist the older
/// of two cursors and re-read a whole batch on the next wake. Serialising the engine
/// makes those races unrepresentable rather than unlikely.
///
/// Nothing outside this type touches the system store, and nothing inside it touches the
/// UI: the engine publishes a ``CaptureStatus`` and the UI renders it
/// (docs/architecture/ARCHITECTURE.md#dependency-graph).
///
/// The loop is driven entirely by ``StoreWatcher``. There is no timer here and no polling
/// of our own — the watcher already coalesces file-system events, wake, unlock and its own
/// poll into one debounced stream, so the engine's job is to consume it.
///
/// See docs/architecture/ARCHITECTURE.md#captureengine-loop.
public actor CaptureEngine {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - archive: where captured notifications and the capture state are written.
    ///   - watcher: the wake stream that drives the loop.
    ///   - exclusions: which apps may be archived. Checked before a payload is decoded.
    ///   - redactor: removes one-time codes before anything is written.
    ///   - enrichment: fills in the icon and the deep link.
    ///   - storeLocation: resolves the system store's path. Injected so tests can point
    ///     the engine at a store they built, rather than at the machine's real one.
    public init(
        archive: Archive,
        watcher: StoreWatcher,
        exclusions: any AppExclusionList = AllowAllApps(),
        redactor: any NotificationRedactor = NoRedaction(),
        enrichment: any NotificationEnricher = NoEnrichment(),
        storeLocation: @escaping @Sendable () throws -> URL = StoreLocation.current
    ) {
        self.archive = archive
        self.watcher = watcher
        self.exclusions = exclusions
        self.redactor = redactor
        self.enrichment = enrichment
        self.storeLocation = storeLocation
        let (stream, continuation) = AsyncStream.makeStream(of: CaptureStatus.self)
        statusStream = stream
        statusContinuation = continuation
    }

    deinit {
        loopTask?.cancel()
        autoResumeTask?.cancel()
        statusContinuation.finish()
    }

    // MARK: Public

    /// What the engine is doing, for the status item, the popover banner and Settings.
    public private(set) var status: CaptureStatus = .stopped

    /// Every status the engine has been in since it was created.
    ///
    /// An immutable `Sendable` `let`, so a `@MainActor` view can subscribe without
    /// awaiting the actor. Unbuffered beyond the default because a status is a *current*
    /// fact — a subscriber that misses one transition gets the next, and the engine's
    /// ``status`` is always there to read.
    nonisolated public let statusStream: AsyncStream<CaptureStatus>

    /// The last wake the loop handled. Diagnostics, and what the tests observe.
    public private(set) var lastWake: WakeReason?

    /// The adapter bootstrap chose, or `nil` while degraded. Diagnostics and tests.
    public private(set) var adapterID: String?

    /// How many store records the engine has read since it was created. A capture metric,
    /// and content-free by construction.
    public private(set) var recordsRead = 0

    /// How many of those became rows in the archive. The gap between this and
    /// ``recordsRead`` is exclusions, duplicates and records that would not parse.
    public private(set) var recordsArchived = 0

    /// How far capture has read. Settings shows its date; tests read it directly.
    public var currentCursor: StoreCursor {
        cursor
    }

    /// Starts watching and consuming wakes.
    ///
    /// Idempotent: calling it twice does not start a second loop, because two consumers of
    /// one `AsyncStream` would split the wakes between them and each would see half.
    public func start() {
        guard loopTask == nil else {
            return
        }

        watcher.start()
        bootstrapOrDegrade()

        // The stream is read once here rather than inside the task: two consumers of one
        // AsyncStream split the wakes between them, so there must only ever be one.
        let wakes = watcher.wakes
        loopTask = Task { [weak self] in
            for await reason in wakes {
                guard !Task.isCancelled else {
                    return
                }
                await self?.tick(reason: reason)
            }
        }
    }

    /// Stops watching. The archive and everything already captured are untouched, and
    /// ``start()`` can follow.
    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        cancelAutoResume()
        watcher.stop()
        transition(to: .stopped)
    }

    // MARK: Internal

    let archive: Archive
    let logger = Logger(subsystem: "app.backglance.Backglance", category: "capture")

    /// The adapter reads go through, or `nil` while degraded.
    var currentAdapter: (any StoreAdapter)? {
        adapter
    }

    /// Moves the cursor. Only the pause fast-forward and the tick loop do this.
    func setCursor(_ newCursor: StoreCursor) {
        cursor = newCursor
    }

    /// Schedules an automatic resume, replacing any already pending.
    func scheduleAutoResume(at date: Date) {
        autoResumeTask = Task { [weak self] in
            let seconds = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else {
                return
            }
            await self?.resume()
        }
    }

    /// Cancels a pending automatic resume. Called by every path that changes the status
    /// deliberately, so a stale timer cannot resume capture minutes after the user
    /// stopped it.
    func cancelAutoResume() {
        autoResumeTask?.cancel()
        autoResumeTask = nil
    }

    /// The store's path, as this engine resolves it.
    func storeURL() throws -> URL {
        try storeLocation()
    }

    /// Resolves everything a tick needs, or records why it could not.
    ///
    /// Every failure here is a *state*, never an error thrown at a caller: a missing
    /// store, a revoked Full Disk Access grant and an unrecognised schema are all things
    /// a person can fix — or that a macOS update can cause and a Backglance update can
    /// fix — while the app keeps running on what it already captured. The engine stays
    /// alive and retries on the next wake, which is what lets a user grant Full Disk
    /// Access in System Settings and see capture resume without relaunching.
    func bootstrapOrDegrade() {
        do {
            try bootstrap()
        } catch let error as CaptureError {
            transition(to: .degraded(error.degradedReason))
        } catch {
            transition(to: .degraded(.readError("\(type(of: error))")))
        }
    }

    /// Handles one wake: read whatever is new, archive it, remember how far we got.
    ///
    /// Three things about the shape of this method are deliberate.
    ///
    /// **A degraded engine retries here rather than anywhere else.** Every wake is a
    /// chance that the thing that was wrong has been fixed — Full Disk Access granted, a
    /// store that now exists, an update that added an adapter — and the watcher is
    /// already waking us on unlock, on wake from sleep and on its own poll. So there is
    /// no retry timer: the wake stream *is* the retry schedule.
    ///
    /// **The cursor is persisted once, after the batch.** Writing it per record would
    /// cost a transaction each; writing it before the inserts would permanently skip
    /// anything that failed in between. Writing it after means a crash mid-batch
    /// re-reads records that were already archived, and the unique index on
    /// `store_rec_id` turns each of those into a no-op. Losing notifications is the
    /// failure that matters; re-reading a few is not.
    ///
    /// **A read failure degrades rather than throws.** A tick runs on a wake, with no
    /// caller waiting on it, so there is nobody to throw to — the engine records why it
    /// stopped and tries again on the next wake.
    func tick(reason: WakeReason) async {
        lastWake = reason

        if case .degraded = status {
            bootstrapOrDegrade()
            return
        }

        // Paused and stopped are deliberate states: a wake must not quietly resume
        // capture behind the user's back.
        guard case .running = status, let adapter else {
            return
        }

        do {
            let batch = try readBatch(with: adapter)
            guard !batch.isEmpty else {
                return
            }

            var archived = 0
            for raw in batch {
                if await archiveOne(raw, source: .live) == .archived {
                    archived += 1
                }
                cursor = adapter.cursor(for: raw)
            }
            try archive.saveCursor(cursor)
            recordsRead += batch.count
            recordsArchived += archived

            // Bound to a local: an os_log interpolation is an autoclosure, and reaching
            // through `self` there is what the formatter and the compiler disagree about.
            let reached = cursor.lastRecID
            logger.debug(
                """
                tick \(reason.rawValue, privacy: .public): \(
                    batch.count,
                    privacy: .public
                ) records,                 through rec \(reached, privacy: .public)
                """
            )
        } catch let error as CaptureError {
            transition(to: .degraded(error.degradedReason))
        } catch {
            transition(to: .degraded(.readError("\(type(of: error))")))
        }
    }

    /// Moves to `status` and tells everyone watching.
    ///
    /// Repeated identical statuses are dropped: the engine sets `.running` on every
    /// successful bootstrap, and a UI that redrew its banner on each of those would
    /// flicker for no reason.
    func transition(to newStatus: CaptureStatus) {
        guard newStatus != status else {
            return
        }
        status = newStatus
        statusContinuation.yield(newStatus)
        logger.debug("status: \(newStatus.logDescription, privacy: .public)")
    }

    /// Parse, exclude, redact, enrich, insert — for one record.
    ///
    /// The order is the privacy model, not a preference:
    ///
    /// 1. **Exclusion first, on the raw row.** `RawStoreRecord.appIdentifier` comes from
    ///    the store's own `app` table, so an excluded app's payload is never decoded into
    ///    objects at all. A password manager's notification does not become a `String` in
    ///    this process.
    /// 2. **Then parse**, and check exclusion *again* against the parsed bundle id: the
    ///    payload's own `app` key can differ from the joined row for helper processes and
    ///    iPhone Mirroring, and the app the user excluded is the one the payload names.
    /// 3. **Redact before anything is written**, in memory and irreversibly.
    /// 4. **Enrich**, then insert the app row and the notification.
    ///
    /// One record's failure never stops the batch, and never reaches the user: it is
    /// counted, and logged by `rec_id` and a fixed reason.
    func archiveOne(_ raw: RawStoreRecord, source: ArchivedNotification.Source) async -> ArchiveOutcome {
        guard exclusions.allows(raw.appIdentifier) else {
            return .excluded
        }

        do {
            let parsed = try parser.parse(raw)
            guard exclusions.allows(parsed.bundleID) else {
                return .excluded
            }

            let (redacted, redaction) = redactor.redact(parsed)
            let enriched = await enrichment.enrich(redacted)

            let now = Date()
            let app = try archive.upsertApp(bundleID: enriched.bundleID, now: now)
            guard let appID = app.id else {
                logger.error("archive rec \(raw.recID, privacy: .public): app row has no id")
                return .failed
            }

            try archive.insert(
                ArchivedNotification(
                    parsed: enriched,
                    appID: appID,
                    storeRecID: raw.recID,
                    source: source,
                    capturedAt: now
                ),
                redaction: redaction
            )
            return .archived
        } catch ArchiveError.duplicate {
            // The import and live capture overlapping. Expected, and not worth a line.
            return .duplicate
        } catch let error as CaptureError {
            logger.error("skip rec \(raw.recID, privacy: .public): \(error.logDescription, privacy: .public)")
            return .failed
        } catch let error as ArchiveError {
            logger.error("archive rec \(raw.recID, privacy: .public): \(error.logDescription, privacy: .public)")
            return .failed
        } catch {
            logger.error("rec \(raw.recID, privacy: .public): \(String(describing: type(of: error)), privacy: .public)")
            return .failed
        }
    }

    // MARK: Private

    private let exclusions: any AppExclusionList
    private let redactor: any NotificationRedactor
    private let enrichment: any NotificationEnricher
    private let storeLocation: @Sendable () throws -> URL
    private let parser = RecordParser()
    private let watcher: StoreWatcher
    private let statusContinuation: AsyncStream<CaptureStatus>.Continuation

    /// The task consuming ``StoreWatcher/wakes``. Its presence is what "started" means.
    private var loopTask: Task<Void, Never>?

    /// The pending automatic resume, if the user paused with an end time.
    private var autoResumeTask: Task<Void, Never>?

    /// The adapter reads go through, set by ``bootstrap()``.
    private var adapter: (any StoreAdapter)?

    /// How far the archive has read. Loaded here, advanced by ticks.
    private var cursor: StoreCursor = .start

    /// One batch of records newer than the cursor, read from a fresh snapshot.
    ///
    /// A new snapshot per tick, discarded at the end of it: the copy is the user's entire
    /// notification history, and it has no business outliving the read that needed it.
    private func readBatch(with adapter: any StoreAdapter) throws -> [RawStoreRecord] {
        let snapshot = try StoreSnapshot.take(of: storeLocation())
        defer { snapshot.discard() }

        let startCursor = cursor
        return try snapshot.read { db in
            try adapter.records(after: startCursor, in: db)
        }
    }

    /// Snapshot, fingerprint, adapter, cursor — in that order, because each step's
    /// failure means something different to the user.
    private func bootstrap() throws {
        let location = try storeLocation()
        let snapshot = try StoreSnapshot.take(of: location)
        defer { snapshot.discard() }

        let resolution = try snapshot.read { db -> StoreAdapterRegistry.Resolution in
            let fingerprint = try StoreFingerprint.compute(in: db)
            // Recorded before the adapter is chosen, and whether or not one is: the
            // fingerprint of a store we do not recognise is exactly what the maintainer
            // needs from a diagnostics report to write the adapter that would.
            try archive.saveFingerprint(fingerprint)
            return StoreAdapterRegistry.resolve(fingerprint: fingerprint, probing: db)
        }

        let selected: any StoreAdapter
        switch resolution {
        case let .matched(adapter):
            selected = adapter

        case let .fallback(adapter, note):
            selected = adapter
            // Logged once per bootstrap, not per tick: it is a standing condition, and
            // the note is content-free by construction.
            logger.notice("adapter fallback: \(note, privacy: .public)")

        case let .degraded(reason):
            adapter = nil
            adapterID = nil
            throw CaptureError.degraded(reason)
        }

        adapter = selected
        adapterID = selected.adapterID
        try archive.saveAdapterID(selected.adapterID)

        // A cursor from a previous run is resumable state. Its absence means a first
        // launch, and `.start` is where an import begins.
        cursor = try archive.loadCursor() ?? .start
        transition(to: .running)
    }
}
