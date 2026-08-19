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
    public init(archive: Archive, watcher: StoreWatcher) {
        self.archive = archive
        self.watcher = watcher
        let (stream, continuation) = AsyncStream.makeStream(of: CaptureStatus.self)
        statusStream = stream
        statusContinuation = continuation
    }

    deinit {
        loopTask?.cancel()
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

    /// Starts watching and consuming wakes.
    ///
    /// Idempotent: calling it twice does not start a second loop, because two consumers of
    /// one `AsyncStream` would split the wakes between them and each would see half.
    public func start() {
        guard loopTask == nil else {
            return
        }

        watcher.start()

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
        watcher.stop()
        transition(to: .stopped)
    }

    // MARK: Internal

    /// Handles one wake.
    ///
    /// The body arrives with the bootstrap and read paths; for now it records what woke
    /// the engine, which is what the loop's own wiring can be tested through.
    func tick(reason: WakeReason) {
        lastWake = reason
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

    // MARK: Private

    private let archive: Archive
    private let watcher: StoreWatcher
    private let logger = Logger(subsystem: "app.backglance.Backglance", category: "capture")
    private let statusContinuation: AsyncStream<CaptureStatus>.Continuation

    /// The task consuming ``StoreWatcher/wakes``. Its presence is what "started" means.
    private var loopTask: Task<Void, Never>?
}
