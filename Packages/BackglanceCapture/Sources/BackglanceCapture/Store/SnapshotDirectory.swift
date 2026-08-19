import BackglanceCore
import Foundation

/// The private scratch directories that hold copies of Apple's notification store.
///
/// Every capture tick and every import batch works on a copy rather than Apple's live
/// database (see docs/architecture/ARCHITECTURE.md#watch-strategy-poll--dispatchsource--snapshot),
/// which means Backglance briefly holds a file containing every notification the system
/// still remembers. Two rules follow from that, and they are this type's whole job:
///
/// - **Each copy is private.** `0700` on the directory, inside the already-`0700`
///   support directory, so no other user on the Mac can read it.
/// - **No copy outlives its tick.** `StoreSnapshot.discard()` removes it on the normal
///   path, and ``fresh()`` sweeps anything older than an hour on the way in, so a crash
///   or a kill -9 mid-tick cannot leave a readable copy of the user's notifications
///   sitting on disk indefinitely. `PanicWipe` removes the whole `tmp/` tree.
public enum SnapshotDirectory {
    // MARK: Public

    /// A new, empty, `0700` directory for one snapshot, after sweeping stale ones.
    ///
    /// The sweep runs here — rather than on a timer — because this is the one moment
    /// Backglance is guaranteed to be thinking about snapshots at all: an app that
    /// crashed mid-tick yesterday cleans up on its next capture rather than never.
    public static func fresh() throws -> URL {
        try fresh(in: ArchivePaths.tmpDirectory)
    }

    // MARK: Internal

    /// How long a leftover directory is tolerated before the sweep removes it.
    ///
    /// Long enough that it can never race a snapshot still in use — the slowest
    /// plausible import batch is orders of magnitude shorter — and short enough that a
    /// crashed tick's copy is gone well before the user would notice it.
    static let staleAfter: TimeInterval = 60 * 60

    /// Testable seam: the same work against an arbitrary `tmp` directory and clock,
    /// rather than the real support directory.
    static func fresh(
        in tmpDirectory: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        sweep(tmpDirectory, now: now, fileManager: fileManager)

        let directory = tmpDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // `createDirectory(attributes:)` only applies permissions to directories it
            // actually creates, so a `tmp/` left behind with a looser mode by a stray
            // umask would keep it. Re-applying explicitly matches `ArchivePaths.prepare()`.
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw CaptureError.snapshotFailed(underlying: error.localizedDescription)
        }
        return directory
    }

    /// Removes snapshot directories older than ``staleAfter``.
    ///
    /// Deliberately non-throwing. A sweep failure means one stale copy survives another
    /// hour, which is not a reason to fail the tick that was about to archive the user's
    /// notifications — and the next sweep will try again. Nothing here is logged: the
    /// only interesting thing to say would be a count, and the caller has more useful
    /// context for that.
    static func sweep(_ tmpDirectory: URL, now: Date, fileManager: FileManager = .default) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: tmpDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [
                .isDirectoryKey, .contentModificationDateKey, .creationDateKey,
            ])
            guard values?.isDirectory == true else {
                continue
            }
            // Whichever timestamp is later: a directory whose contents were written
            // after it was created is as young as its newest write. Missing both is
            // treated as stale — an entry with no readable dates is not one we can
            // justify keeping a copy of the user's notifications inside.
            let stamps = [values?.contentModificationDate, values?.creationDate].compactMap(\.self)
            let age = now.timeIntervalSince(stamps.max() ?? .distantPast)
            if age > staleAfter {
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}
