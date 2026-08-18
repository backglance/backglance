import Foundation

/// Module marker for `BackglanceCore`.
///
/// SPM needs at least one source file per target, and the real types (`Archive`,
/// the models, the rules and digest engines) land in Phase 1. Until then this file
/// carries the one fact the module already knows about itself.
public enum BackglanceCore {
    /// Schema version of the archive this build of the module can open.
    ///
    /// Bumped by `ArchiveMigrations` when a migration is added; the archive refuses
    /// to open a file written by a newer build.
    public static let archiveSchemaVersion = 0
}
