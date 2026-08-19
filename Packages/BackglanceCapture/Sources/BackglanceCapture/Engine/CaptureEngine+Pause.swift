import BackglanceCore
import Foundation

// MARK: - CaptureEngine + pause

public extension CaptureEngine {
    /// Stops archiving until `date`, or until the user says otherwise.
    ///
    /// Pause is a promise — *nothing delivered while paused is archived* — and keeping it
    /// takes more than stopping the loop. The system keeps delivering notifications and
    /// the store keeps accumulating rows either way; Backglance has no say in that. What
    /// it controls is whether those rows are ever read, and the answer is no: the cursor
    /// freezes here, and ``resume()`` moves it to the store's tail rather than reading
    /// what accumulated.
    ///
    /// The watcher keeps running. It costs nothing, its wakes reach a `tick` that returns
    /// immediately while the status is not `.running`, and leaving it armed means resume
    /// is instant rather than waiting for the next poll.
    ///
    /// - Parameter date: when to resume by itself, or `nil` to stay paused until asked.
    func pause(until date: Date? = nil) {
        cancelAutoResume()
        transition(to: .paused(until: date))

        guard let date else {
            return
        }
        scheduleAutoResume(at: date)
    }

    /// Starts archiving again, skipping whatever arrived during the pause.
    ///
    /// The fast-forward is the point. Reading from the frozen cursor would archive every
    /// notification the pause was meant to exclude, days later and all at once — so the
    /// cursor jumps to the store's current tail instead, and those rows are skipped for
    /// good. A user who later decides they wanted them cannot have them back, which is
    /// the honest consequence of a promise that "paused" means paused.
    ///
    /// An engine with no adapter — paused while degraded, or never bootstrapped — takes
    /// the bootstrap path instead, which ends in `.running` or in the degraded reason.
    func resume() {
        cancelAutoResume()

        guard currentAdapter != nil else {
            bootstrapOrDegrade()
            return
        }

        do {
            try fastForwardCursor()
            transition(to: .running)
        } catch let error as CaptureError {
            transition(to: .degraded(error.degradedReason))
        } catch {
            transition(to: .degraded(.readError("\(type(of: error))")))
        }
    }
}

// MARK: - Fast-forward

extension CaptureEngine {
    /// Moves the cursor to the store's last record without reading any of them.
    ///
    /// Done with the adapter's own batched read rather than a `MAX(rec_id)` query,
    /// because `rec_id` is the adapter's column to know about: a future store that
    /// numbers its rows differently changes one adapter, not this method.
    func fastForwardCursor() throws {
        guard let adapter = currentAdapter else {
            return
        }

        let snapshot = try StoreSnapshot.take(of: storeURL())
        defer { snapshot.discard() }

        var tail = currentCursor
        while true {
            let batch = try snapshot.read { db in
                try adapter.records(after: tail, in: db)
            }
            guard let last = batch.last else {
                break
            }
            tail = adapter.cursor(for: last)
        }

        setCursor(tail)
        try archive.saveCursor(tail)
    }
}
