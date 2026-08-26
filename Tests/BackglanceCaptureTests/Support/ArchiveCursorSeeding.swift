@testable import BackglanceCapture
import BackglanceCore
import Foundation

extension Archive {
    /// Positions live capture at the beginning of the store instead of at its tail.
    ///
    /// Production does the opposite. A fresh archive starts live capture at the *tail*,
    /// because everything already in the store predates the install and backfilling it is
    /// `importExisting()`'s job — an explicit step the user consents to, recorded with
    /// `source = 'import'` (docs/features/CAPTURE.md#the-system-store-import).
    ///
    /// That makes "put rows in a store, then start the engine, then assert they were
    /// archived" a no-op in production semantics, which is exactly what most of these
    /// tests want to do: they are about what the pipeline does *to* a record, not about
    /// where capture begins. So they say "read what is already there" out loud, with this.
    ///
    /// A **saved** `.start` is the documented way to mean "read from the beginning"; the
    /// row's *absence* means "never read anything", and only the absence triggers tail
    /// positioning. ``Archive/clearCursor()`` documents that distinction — this helper
    /// depends on it.
    func captureFromTheStartOfTheStore() throws {
        try saveCursor(.start)
    }
}
