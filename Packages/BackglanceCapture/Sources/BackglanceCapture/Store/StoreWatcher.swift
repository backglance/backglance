import AppKit
import BackglanceCore
import Foundation

// MARK: - WakeReason

/// Why the watcher asked for a capture tick.
///
/// Carried through to `CaptureEngine.tick(reason:)` and logged: a reason is a fixed
/// keyword, never anything derived from a notification.
public enum WakeReason: String, Sendable {
    /// `db` or `db-wal` changed on disk. The common case.
    case fileChanged

    /// The fallback timer fired. Catches anything the file sources missed.
    case poll

    /// The Mac woke from sleep.
    case didWake

    /// The screen was unlocked.
    case screenUnlocked

    /// Settings ▸ Capture ▸ "Check now", or a `backglance://resume`.
    case manual
}

// MARK: - StoreWatcher

/// Notices that Apple's notification store changed, and says so at most a few times a
/// second.
///
/// Four triggers feed one debounced stream (see
/// docs/architecture/ARCHITECTURE.md#watch-strategy-poll--dispatchsource--snapshot):
///
/// | Trigger | Why it exists |
/// |---|---|
/// | `DispatchSource` on `db` and `db-wal` | Sub-second latency at near-zero idle cost |
/// | A directory watch on `db2/` | Re-arms the file sources when `usernoted` recreates or checkpoints the files,
/// leaving the old fds pointing at a dead inode |
/// | Poll timer, 15 s (60 s in Low Power Mode) | Belt and braces: missed events, checkpoints, writes that do not touch
/// the watched inode |
/// | Wake and unlock | Immediate catch-up when the user comes back |
///
/// The watcher never reads the store — it only says "something happened". Everything
/// that opens a database goes through `StoreSnapshot`, which is also where a missing
/// file or a denied permission is diagnosed. That division is why `start()` cannot fail
/// and why a file source that will not arm is a `notice`, not an error: without Full
/// Disk Access the fds simply never open, the poll timer keeps firing, and the engine
/// reports the real reason from the snapshot copy.
///
/// > Note: the design documents describe the directory watch as an `FSEventStream` with
/// > `kFSEventStreamCreateFlagFileEvents`. It is implemented here as a `DispatchSource`
/// > on the directory's own descriptor, which delivers the same signal — "an entry under
/// > `db2/` appeared, vanished or was renamed" — using the primitive the file watches
/// > already use, and without the C callback and `Unmanaged` pointer an `FSEventStream`
/// > requires. Nothing downstream can tell the difference: the only thing either
/// > mechanism does here is re-arm and wake.
public final class StoreWatcher: @unchecked Sendable {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - location: the store's `db` file, from `StoreLocation.current()`.
    ///   - debounce: how long to coalesce a burst before waking. An app can post fifty
    ///     notifications in a second; the engine only needs to be told once, because one
    ///     tick reads everything that accumulated.
    ///   - pollInterval: overrides the Low-Power-Mode-aware default. Tests set it so they
    ///     do not have to wait fifteen seconds to observe a poll.
    public init(location: URL, debounce: TimeInterval = 0.5, pollInterval: TimeInterval? = nil) {
        self.location = location
        self.debounce = debounce
        pollIntervalOverride = pollInterval
        let (stream, continuation) = AsyncStream.makeStream(
            of: WakeReason.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        wakes = stream
        self.continuation = continuation
    }

    deinit {
        // Deliberately *not* dispatched onto `queue`. Every block scheduled there captures
        // `self` strongly, so deinit cannot run while one is pending or executing, and by
        // definition no other reference is left to race with — direct access is safe here
        // and dispatching would instead resurrect `self` inside the block.
        //
        // Without this, a watcher released without `stop()` left its `O_EVTONLY`
        // descriptors on `db`/`db-wal`/`db2/` open, its poll timer running, and its three
        // system observers registered for the lifetime of the process.
        teardown()
        continuation.finish()
    }

    // MARK: Public

    /// The debounced wake stream.
    ///
    /// `bufferingNewest(1)` means the engine can never fall behind: if a tick is still
    /// running when the next wake arrives, exactly one wake is queued, and that one wake
    /// reads everything that accumulated in the meantime. A deeper buffer would only
    /// queue redundant ticks.
    public let wakes: AsyncStream<WakeReason>

    /// Arms every trigger. Idempotent — arming twice replaces the sources rather than
    /// doubling them.
    public func start() {
        queue.async { [self] in
            armFileSources()
            armDirectorySource()
            armPollTimer()
            armSystemEvents()
        }
    }

    /// Tears every trigger down. The stream stays open, so `start()` can follow.
    public func stop() {
        queue.async { [self] in teardown() }
    }

    /// Asks for a tick now, skipping the debounce.
    ///
    /// Settings ▸ Capture ▸ "Check now" and `backglance://resume` land here, and both are
    /// a person waiting for something to happen.
    public func poke() {
        queue.async { [self] in scheduleWake(.manual, immediate: true) }
    }

    // MARK: Internal

    /// 15 s normally, 60 s in Low Power Mode — re-read on every arm, because the mode can
    /// flip while the app runs.
    var pollInterval: TimeInterval {
        if let pollIntervalOverride {
            return pollIntervalOverride
        }
        return ProcessInfo.processInfo.isLowPowerModeEnabled ? 60 : 15
    }

    // MARK: Private

    private let location: URL
    private let debounce: TimeInterval
    private let pollIntervalOverride: TimeInterval?

    private let continuation: AsyncStream<WakeReason>.Continuation
    private let queue = DispatchQueue(label: "app.backglance.Backglance.store-watcher", qos: .utility)
    // All of the following are touched only on `queue`, which is what makes the
    // `@unchecked Sendable` conformance honest.
    private var fileSources: [DispatchSourceFileSystemObject] = []
    private var directorySource: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    /// When the burst currently being coalesced started, or `nil` if nothing is pending.
    private var pendingSince: Date?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var defaultObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    /// The longest a trigger may be held back by further triggers. Four debounces —
    /// long enough that an ordinary burst still collapses to one tick, short enough that
    /// sustained activity is never swallowed entirely.
    private var maxWait: TimeInterval {
        debounce * 4
    }

    // MARK: Triggers

    /// Watches `db` and `db-wal` for writes.
    ///
    /// A descriptor that will not open is expected, not exceptional: without Full Disk
    /// Access none of them will, and a checkpointed store has no `-wal` at all. Either
    /// way the poll timer still fires and the engine still diagnoses the real cause, so
    /// this is logged at `notice` with an errno and nothing more.
    private func armFileSources() {
        for source in fileSources {
            source.cancel()
        }
        fileSources.removeAll()

        for path in [location.path, location.path + "-wal"] {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else {
                let name = URL(fileURLWithPath: path).lastPathComponent
                Log.capture.notice("watch \(name) unavailable, errno \(errno)")
                continue
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename, .delete],
                queue: queue
            )
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else {
                    return
                }
                if !source.data.isDisjoint(with: [.rename, .delete]) {
                    // usernoted checkpointed or recreated the file, so this descriptor now
                    // points at a dead inode. Re-arm on the new one — after a beat, so the
                    // replacement is actually in place.
                    queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                        self?.armFileSources()
                    }
                }
                scheduleWake(.fileChanged)
            }
            source.setCancelHandler {
                close(descriptor)
            }
            source.resume()
            fileSources.append(source)
        }
    }

    /// Watches `db2/` so that files appearing or being replaced re-arms the file sources.
    ///
    /// Without this, a store recreated while Backglance was running would leave every
    /// file source pointing at a dead inode, and capture would quietly fall back to
    /// polling for the rest of the session.
    private func armDirectorySource() {
        directorySource?.cancel()
        directorySource = nil

        let directory = location.deletingLastPathComponent()
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Log.capture.notice("watch store directory unavailable, errno \(errno)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else {
                return
            }
            armFileSources()
            scheduleWake(.fileChanged)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        directorySource = source
    }

    private func armPollTimer() {
        pollTimer?.cancel()
        let interval = pollInterval
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Generous leeway: this timer is a backstop, and letting the system coalesce it
        // with other work is most of why idle cost stays negligible. Proportional rather
        // than the flat two seconds the design documents suggest — two seconds of slack
        // on a two-second timer means the timer may simply never be the thing that fires,
        // which matters for the short intervals tests use and costs nothing at the real
        // 15 s and 60 s (1.5 s and a capped 2 s).
        let leeway = min(interval / 10, 2)
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .microseconds(Int(leeway * 1_000_000))
        )
        timer.setEventHandler { [weak self] in
            self?.scheduleWake(.poll)
        }
        timer.resume()
        pollTimer = timer
    }

    /// Cancels every source and removes every observer. Leaves the stream open.
    ///
    /// Must be called on ``queue``, or from `deinit` — see the note there.
    private func teardown() {
        for source in fileSources {
            source.cancel()
        }
        fileSources.removeAll()
        directorySource?.cancel()
        directorySource = nil
        pollTimer?.cancel()
        pollTimer = nil
        pending?.cancel()
        pending = nil
        pendingSince = nil
        removeSystemObservers()
    }

    /// Unregisters the wake, unlock and power-state observers.
    ///
    /// Split out because ``armSystemEvents()`` needs it too: unlike the three `arm*`
    /// helpers that replace their source, adding an observer only ever appends, so
    /// re-arming without this leaves the previous registration in place and every unlock
    /// schedules two wakes.
    private func removeSystemObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspace.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        for observer in defaultObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        defaultObservers.removeAll()

        let distributed = DistributedNotificationCenter.default()
        for observer in distributedObservers {
            distributed.removeObserver(observer)
        }
        distributedObservers.removeAll()
    }

    private func armSystemEvents() {
        // Idempotent like its three siblings: `start()` promises that arming twice
        // replaces the triggers rather than doubling them, and observers only append.
        removeSystemObservers()

        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else {
                return
            }
            queue.async { self.scheduleWake(.didWake, immediate: true) }
        })

        // Low Power Mode moves the poll interval between 15 s and 60 s, so the timer has
        // to be rebuilt when it flips.
        defaultObservers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else {
                return
            }
            queue.async { self.armPollTimer() }
        })

        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else {
                return
            }
            queue.async { self.scheduleWake(.screenUnlocked, immediate: true) }
        })
    }

    // MARK: Debounce

    /// Coalesces a burst into one wake, but never postpones one indefinitely.
    ///
    /// Each new trigger cancels the pending one, so fifty notifications arriving in a
    /// second produce a single tick — and that tick reads all fifty. `immediate` skips
    /// the wait for the triggers a person is waiting on: a manual check, a wake, an
    /// unlock.
    ///
    /// > Important: the cancel-and-reschedule on its own is a starvation bug, not just a
    /// > delay. Under *sustained* activity — an app posting steadily, or any trigger
    /// > recurring faster than the debounce — every rescheduling cancels the wake that
    /// > was about to fire, and the engine is never told anything at all. So the wake is
    /// > also capped: once a trigger has been waiting ``maxWait``, it fires regardless of
    /// > what keeps arriving. Coalescing a burst is the goal; swallowing one is not.
    ///
    /// Must be called on ``queue``.
    private func scheduleWake(_ reason: WakeReason, immediate: Bool = false) {
        pending?.cancel()

        let now = Date()
        let waitingSince = pendingSince ?? now
        pendingSince = waitingSince

        let delay: TimeInterval = if immediate {
            0
        } else {
            // The sooner of "one debounce from now" and "maxWait from the first trigger
            // in this burst".
            max(0, min(debounce, waitingSince.addingTimeInterval(maxWait).timeIntervalSince(now)))
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            pendingSince = nil
            continuation.yield(reason)
        }
        pending = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
