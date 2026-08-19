import Foundation

/// A private, read-only copy of the system store taken for one capture tick or import
/// batch.
///
/// > ❌ Never open Apple's live `db` directly, not even read-only. A read-only handle
/// > still participates in the WAL and wal-index locking protocol on a file owned by
/// > `usernoted`, and a stray write path would put the user's Notification Center at
/// > risk. Backglance copies first, always.
///
/// The copy is cheap: `FileManager.copyItem` goes through `copyfile(3)` with
/// `COPYFILE_CLONE`, so on APFS even a large store becomes a copy-on-write clone in
/// milliseconds. See docs/features/CAPTURE.md#snapshot-copy.
public struct StoreSnapshot: Sendable {
    // MARK: Public

    /// The private `tmp/<uuid>/` directory holding the copy. Removed by ``discard()``.
    public let directory: URL

    /// The copied database, inside ``directory``.
    public let databaseURL: URL

    /// Copies the store at `location` into a fresh private directory.
    ///
    /// `db` and `-wal` are copied; `-shm` deliberately is not. The `-wal` carries the
    /// uncheckpointed rows — the most recent notifications, exactly the ones capture is
    /// after — while `-shm` is a live wal-index belonging to another process, and a
    /// stale one could point at WAL frames this copy does not contain. SQLite rebuilds
    /// the wal-index from the copied `-wal` on open.
    ///
    /// Every failure removes the partial copy before throwing, so a failed tick never
    /// leaves a fragment of the user's notifications behind.
    public static func take(of location: URL) throws -> StoreSnapshot {
        try take(of: location, into: SnapshotDirectory.fresh())
    }

    /// Removes the copy. Safe to call twice, and safe to call after a failed read.
    ///
    /// Non-throwing on purpose: a snapshot that cannot be removed is picked up by
    /// ``SnapshotDirectory``'s sweep within the hour, which is a better outcome than a
    /// throwing cleanup path that callers would end up writing `try?` in front of anyway.
    public func discard() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Internal

    /// Testable seam: copies into an already-created directory, so tests do not write
    /// into the real support directory just to exercise the copy and its error mapping.
    static func take(
        of location: URL,
        into directory: URL,
        fileManager: FileManager = .default
    ) throws -> StoreSnapshot {
        let target = directory.appendingPathComponent("db")
        do {
            try fileManager.copyItem(at: location, to: target)
            let wal = URL(fileURLWithPath: location.path + "-wal")
            if fileManager.fileExists(atPath: wal.path) {
                try fileManager.copyItem(at: wal, to: URL(fileURLWithPath: target.path + "-wal"))
            }
        } catch let error as NSError where isPermissionDenied(error) {
            // The classic "no Full Disk Access" symptom, and the reason `StoreLocation`
            // does not try to answer this question itself.
            try? fileManager.removeItem(at: directory)
            throw CaptureError.fullDiskAccessDenied
        } catch let error as NSError where isNoSuchFile(error) {
            // The store was there when the path resolved and is gone now — the user
            // deleted it, or `usernoted` replaced it between the two. Degrade and retry.
            try? fileManager.removeItem(at: directory)
            throw CaptureError.storeNotFound(location)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw CaptureError.snapshotFailed(underlying: error.localizedDescription)
        }
        return StoreSnapshot(directory: directory, databaseURL: target)
    }

    /// Whether `error` is a permission denial, however Foundation chose to phrase it.
    ///
    /// This is the app's most consequential error mapping — it decides whether a user
    /// is told to grant Full Disk Access or is shown a generic "couldn't read the
    /// database" — so it matches on the POSIX errno underneath rather than trusting a
    /// single Cocoa code.
    ///
    /// `FileManager.copyItem` with a source it cannot read reports
    /// `NSFileWriteNoPermissionError` (513), *not* the `NSFileReadNoPermissionError`
    /// (257) one would expect: Foundation attributes the failure to the destination and
    /// even words the message that way ("you don't have permission to access
    /// <destination>"). Matching only 257 would send every FDA-denied user to a generic
    /// read error instead of the one fix that works. Both codes are accepted, and the
    /// underlying `EACCES`/`EPERM` is what actually decides.
    ///
    /// The destination is a directory Backglance created moments ago at `0700`, so a
    /// permission denial on this copy has no plausible cause other than the source.
    static func isPermissionDenied(_ error: NSError) -> Bool {
        if
            error.domain == NSCocoaErrorDomain,
            error.code == NSFileReadNoPermissionError || error.code == NSFileWriteNoPermissionError
        {
            return true
        }
        guard let code = posixCode(of: error) else {
            return false
        }
        return code == EACCES || code == EPERM
    }

    /// Whether `error` means the source is not there, by Cocoa code or errno.
    static func isNoSuchFile(_ error: NSError) -> Bool {
        if
            error.domain == NSCocoaErrorDomain,
            error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError
        {
            return true
        }
        return posixCode(of: error) == ENOENT
    }

    // MARK: Private

    /// The errno at the bottom of a Cocoa error's `NSUnderlyingError` chain, if any.
    private static func posixCode(of error: NSError) -> Int32? {
        if error.domain == NSPOSIXErrorDomain {
            return Int32(error.code)
        }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return nil
        }
        return posixCode(of: underlying)
    }
}
