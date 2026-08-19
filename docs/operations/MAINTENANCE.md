# Maintenance

Last Updated: 2026-08-18

This document is the routine-care manual for Backglance: what the app does on its own to keep the archive small and healthy, what the developer does on a cadence (dependency updates, security patches, fixture refresh when a new macOS ships, migration testing), what a user should know about backups and uninstalling, and the yearly chores that come with a signed, notarized, free macOS app maintained by one person. Nothing here requires a server; every job runs on the user's Mac or in GitHub Actions.

## Table of Contents

- [Archive Vacuuming and Pruning](#archive-vacuuming-and-pruning)
  - [The Retention Job](#the-retention-job)
  - [Vacuum Policy](#vacuum-policy)
  - [FTS Optimize](#fts-optimize)
- [Routine Health Checks](#routine-health-checks)
- [Log Rotation, Icon Cache, Snapshot Cleanup](#log-rotation-icon-cache-snapshot-cleanup)
- [Dependency Updates](#dependency-updates)
- [Security Patching](#security-patching)
- [Fixture Refresh When a New macOS Ships](#fixture-refresh-when-a-new-macos-ships)
- [Archive Migrations Maintenance](#archive-migrations-maintenance)
- [Backup Guidance for Users](#backup-guidance-for-users)
- [Uninstall](#uninstall)
- [Yearly Tasks](#yearly-tasks)
- [On-Call for One Person](#on-call-for-one-person)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Archive Vacuuming and Pruning

### The Retention Job

Retention is enforced by `RetentionJob` in `BackglanceCore`. It runs **on launch** (after migrations, before capture starts) and then **every 6 hours** while the app is running. It never runs while a panic wipe or an integrity check is in progress.

Policy resolution per notification: the app's `apps.retention` if not `'inherit'`, else the global default (`RetentionPolicy.days30` unless changed). `forever` means never delete; `never` means never *store* (the app is excluded at capture time, so nothing reaches retention). Pinned notifications (`is_pinned = 1`) are exempt from retention.

Deletion is two-phase:

1. **Soft delete** — expired rows get `is_deleted = 1`. They vanish from the timeline and search immediately (every query filters `is_deleted = 0`) but survive for a grace period so a user who notices "wait, I needed that" can raise the app's retention within 24 hours and get them back.
2. **Hard delete** — rows with `is_deleted = 1` older than the 24-hour grace period are `DELETE`d. The FTS `_ad` trigger removes their index entries; `ON DELETE CASCADE` clears `redactions`, `digest_items`, `snoozes`, `embeddings`.

```swift
// BackglanceCore/Retention/RetentionJob.swift
import Foundation
import GRDB

public struct RetentionJob: Sendable {
    public struct Report: Sendable, Equatable {
        public var softDeleted = 0
        public var hardDeleted = 0
        public var vacuumed = false
        public var duration: TimeInterval = 0
    }

    public enum Trigger: String, Sendable { case launch, timer, manual }

    private let archive: Archive
    private let now: () -> Date
    private let gracePeriod: TimeInterval = 24 * 3600
    private let vacuumPolicy: VacuumPolicy

    public init(archive: Archive, vacuumPolicy: VacuumPolicy = .default, now: @escaping () -> Date = Date.init) {
        self.archive = archive
        self.vacuumPolicy = vacuumPolicy
        self.now = now
    }

    public func run(trigger: Trigger) async throws -> Report {
        let started = Date()
        var report = Report()
        let nowUnix = now().timeIntervalSince1970
        let defaultPolicy = try await archive.read { db in try Settings.defaultRetention(db) }

        // Phase 1: soft delete. One UPDATE per policy bucket keeps it index-friendly.
        try await archive.write { db in
            for policy in RetentionPolicy.allCases {
                guard let seconds = policy.seconds else { continue }   // forever/never: skip
                let cutoff = nowUnix - seconds
                let effective = policy == defaultPolicy ? "'inherit', '\(policy.rawValue)'" : "'\(policy.rawValue)'"
                report.softDeleted += try db.execute(literal: """
                    UPDATE notifications SET is_deleted = 1
                    WHERE is_deleted = 0 AND is_pinned = 0
                      AND delivered_at < \(cutoff)
                      AND app_id IN (SELECT id FROM apps WHERE retention IN (\(sql: effective)))
                    """).changesCount
            }
        }

        // Phase 2: hard delete rows that have been soft-deleted longer than the grace period.
        // We use captured_at as a lower bound: soft-deleted rows do not carry a deleted_at
        // column in v1, so "older than grace" is measured against delivered_at + policy.
        try await archive.write { db in
            let graceCutoff = nowUnix - gracePeriod
            report.hardDeleted = try db.execute(literal: """
                DELETE FROM notifications
                WHERE is_deleted = 1 AND delivered_at < \(graceCutoff)
                """).changesCount
            try db.execute(sql: "UPDATE apps SET notification_count = (SELECT COUNT(*) FROM notifications n WHERE n.app_id = apps.id AND n.is_deleted = 0)")
        }

        // Phase 3: reclaim space according to policy.
        report.vacuumed = try await vacuumPolicy.applyIfNeeded(archive: archive, trigger: trigger)

        report.duration = Date().timeIntervalSince(started)
        Log.archive.info("retention trigger=\(trigger.rawValue) soft=\(report.softDeleted) hard=\(report.hardDeleted) vacuum=\(report.vacuumed) ms=\(Int(report.duration * 1000))")
        return report
    }
}

extension RetentionPolicy: CaseIterable {
    /// Seconds a notification is kept, or nil when the policy is not time-based.
    var seconds: TimeInterval? {
        switch self {
        case .hours24: return 24 * 3600
        case .days7:   return 7 * 24 * 3600
        case .days30:  return 30 * 24 * 3600
        case .forever, .never: return nil
        }
    }
}
```

The 6-hour timer is a `DispatchSourceTimer` on a utility queue with 10 % leeway; on wake from sleep the next tick is allowed to fire immediately if more than 6 hours have elapsed.

> ℹ️ **Info:** Changing an app's retention to something *shorter* takes effect at the next job run (at most 6 hours, or immediately via Settings ▸ Advanced ▸ "Run Retention Now"). Changing it to something *longer* within 24 hours restores soft-deleted rows: the Settings action runs `UPDATE notifications SET is_deleted = 0 WHERE app_id = ? AND is_deleted = 1 AND delivered_at >= <new cutoff>`.

### Vacuum Policy

The archive is created with `PRAGMA auto_vacuum = INCREMENTAL` (must be set before the first table exists — it is in migration `v1_initial`) and `PRAGMA secure_delete = ON` (set on every connection open, so deleted content is overwritten with zeros rather than left in free pages).

| Operation | When | Cost | Why |
|---|---|---|---|
| `PRAGMA incremental_vacuum(N)` | After every hard-delete phase, `N = 256` pages per run | Milliseconds; no exclusive lock beyond a normal write | Keeps free pages from accumulating without ever blocking the UI |
| `VACUUM` | Monthly, **or** when `freelist_count / page_count > 0.20`, only on `trigger == .launch` or `.manual` | Rewrites the file; needs 2× free disk; takes seconds at 100k rows | Defragments and shrinks the file; incremental vacuum reclaims pages but does not repack |

```swift
// BackglanceCore/Retention/VacuumPolicy.swift
import Foundation
import GRDB

public struct VacuumPolicy: Sendable {
    public var incrementalPagesPerRun = 256
    public var fullVacuumInterval: TimeInterval = 30 * 24 * 3600
    public var freePageRatioThreshold = 0.20
    public static let `default` = VacuumPolicy()

    /// Returns true when a full VACUUM ran.
    func applyIfNeeded(archive: Archive, trigger: RetentionJob.Trigger) async throws -> Bool {
        // Always trim a bounded number of free pages.
        try await archive.write { db in
            try db.execute(sql: "PRAGMA incremental_vacuum(\(incrementalPagesPerRun))")
        }

        // Full VACUUM only at launch or on explicit request; never from the 6 h timer
        // because it briefly blocks writers and can take seconds on a large archive.
        guard trigger != .timer else { return false }

        let (pageCount, freelist, lastVacuum) = try await archive.read { db -> (Int, Int, Double) in
            let pages = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 1
            let free = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            let last = try Double.fetchOne(db, sql: "SELECT value FROM schema_meta WHERE key = 'last_vacuum_at'") ?? 0
            return (pages, free, last)
        }
        let ratio = Double(freelist) / Double(max(pageCount, 1))
        let due = Date().timeIntervalSince1970 - lastVacuum > fullVacuumInterval
        guard due || ratio > freePageRatioThreshold else { return false }

        do {
            // VACUUM cannot run inside a transaction; Archive.vacuum() uses a raw connection.
            try await archive.vacuum()
            try await archive.write { db in
                try db.execute(sql: "INSERT OR REPLACE INTO schema_meta (key, value) VALUES ('last_vacuum_at', ?)",
                               arguments: [Date().timeIntervalSince1970])
            }
            Log.archive.notice("vacuum ok pages=\(pageCount) free=\(freelist) ratio=\(String(format: "%.2f", ratio))")
            return true
        } catch {
            // Not fatal: the archive is still consistent, only larger than it needs to be.
            Log.archive.error("vacuum failed code=\((error as? DatabaseError)?.resultCode.rawValue ?? -1)")
            return false
        }
    }
}
```

> ⚠️ **Warning:** `VACUUM` on a WAL database needs free disk equal to the archive size. If `NSFileManager.volumeAvailableCapacityForImportantUsage` reports less than 2× the archive size, `Archive.vacuum()` throws `ArchiveError.insufficientDiskSpace` and the job logs and moves on.

### FTS Optimize

Every hard-delete phase and every import (`CaptureEngine.importExisting()`) leaves the FTS5 index with extra b-tree segments. After each retention run that hard-deleted anything, and after any import larger than 1,000 rows, the job issues:

```sql
INSERT INTO notifications_fts(notifications_fts) VALUES('optimize');
```

This merges segments and keeps `FTS p95 < 50 ms` at 100k notifications (see [`../deployment/PERFORMANCE_GUIDE.md`](../deployment/PERFORMANCE_GUIDE.md)). It runs in the same write transaction as the hard delete so a crash between the two leaves nothing half-done. Once a month, alongside `VACUUM`, the job also runs `INSERT INTO notifications_fts(notifications_fts) VALUES('rebuild')` if `PRAGMA integrity_check` on the FTS table (`INSERT INTO notifications_fts(notifications_fts) VALUES('integrity-check')`) reports a problem.

## Routine Health Checks

| Check | Schedule | On failure |
|---|---|---|
| `PRAGMA quick_check` | Every launch, before migrations | Falls back to `integrity_check`; if that fails → corruption path below |
| `PRAGMA integrity_check` | Weekly (with the first retention run after 7 days since last), and on demand from Settings ▸ Status ▸ "Run Integrity Check" | Corruption path below |
| FTS `integrity-check` | Monthly | `rebuild` |
| Snapshot dir sweep | Every launch + every retention run | Delete files older than 1 hour |
| Icon cache sweep | Weekly | Delete icons for bundle IDs no longer in `apps` |
| Adapter probe | Every launch + after wake | `.degraded` status, banner, Status pane row |

**What happens on corruption.** If `integrity_check` returns anything but `ok`, or opening the archive throws `SQLITE_CORRUPT`/`SQLITE_NOTADB`:

1. Capture is stopped (`CaptureStatus.stopped`).
2. The archive files are **renamed**, not deleted: `archive.sqlite` → `archive.corrupt-2026-08-17T091244.sqlite` (plus `-wal`/`-shm` with the same suffix). Nothing is destroyed; a Time Machine restore or a `sqlite3 .recover` remains possible.
3. A fresh, empty archive is created and migrated; capture restarts with `importExisting()` so whatever is still in the system store is recovered.
4. The user is told with a non-modal banner in the popover: *"Your archive could not be read and was set aside as `archive.corrupt-<date>.sqlite`. Backglance started a new one. See Troubleshooting for recovery options."* with a *Reveal in Finder* button.
5. `Log.archive.fault("archive corrupt: renamed to .corrupt-<date>")` is written.

The recovery steps for the user are in [`./TROUBLESHOOTING.md`](./TROUBLESHOOTING.md#archive-migration-failures).

## Log Rotation, Icon Cache, Snapshot Cleanup

- **Log rotation** — `FileLogSink` rotates at 2 MB, keeps 5 files, in `~/Library/Logs/Backglance/`. Rotation is size-based only; there is no age-based deletion because five files of two megabytes is the whole budget. Details in [`./MONITORING_LOGGING.md`](./MONITORING_LOGGING.md#the-file-log).
- **Icon cache** — `~/Library/Application Support/Backglance/icons/<bundle-id>.png`. Weekly sweep removes icons for bundle IDs absent from `apps`. Users can delete the whole directory at any time; icons are re-fetched via `NSWorkspace` on next display. A stale icon (app updated its icon) is refreshed when the cached file is older than 30 days *and* the app's bundle `CFBundleVersion` changed.
- **Snapshot cleanup** — `StoreWatcher` copies Apple's store db + wal to `~/Library/Application Support/Backglance/tmp/snapshot-<uuid>/` before opening the copy read-only (`Configuration.readonly` + `PRAGMA query_only = 1`, plain path — not `?immutable=1`, which would hide the WAL rows). The copy is deleted after each batch. If the app is killed mid-batch, orphaned snapshots remain; the launch sweep deletes anything in `tmp/` older than one hour. Snapshots contain raw system store rows, so `tmp/` is `0700` and its contents are never included in diagnostics.

> 🔒 **Security:** The snapshot directory is the one place on disk where other apps' notification content sits *outside* the archive's `0600` file, briefly. That is why the sweep runs at launch and not only on the timer, and why `PanicWipe.execute()` deletes `tmp/` as well.

## Dependency Updates

Two third-party packages, both via SPM:

| Package | Pinned | Cadence | Notes |
|---|---|---|---|
| GRDB.swift | `from: "7.0.0"` | Review monthly; adopt patch releases within a week, minor releases after the test suite passes on all three CI runners | Watch the changelog for `DatabaseMigrator` and FTS5 behavior changes; run the migration-fixture tests (below) before merging |
| Sparkle | `from: "2.7.0"` | Adopt security releases within 48 h; others monthly | Every Sparkle bump is tested with a real updater upgrade (below) before release |

Dependabot for SPM (`.github/dependabot.yml`):

```yaml
version: 2
updates:
  - package-ecosystem: "swift"
    directory: "/"
    schedule:
      interval: "weekly"
      day: "monday"
      time: "07:00"
      timezone: "Europe/Istanbul"
    open-pull-requests-limit: 5
    labels: ["dependencies"]
    commit-message:
      prefix: "deps"
    groups:
      grdb:
        patterns: ["GRDB*"]
      sparkle:
        patterns: ["Sparkle*"]
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "monthly"
    labels: ["ci"]
```

**Testing an updater upgrade** (do this for every Sparkle bump and every release candidate):

1. Build the *previous* release tag locally, sign it with the Developer ID identity, and install it to `/Applications` — this is the "old" app.
2. Build the candidate, run `Scripts/sign_and_notarize.sh` and `Scripts/make_appcast.sh` against a **local** appcast: `Scripts/make_appcast.sh --output /tmp/appcast-test/appcast.xml`, then serve it with `python3 -m http.server 8000 --directory /tmp/appcast-test`.
3. Launch the old app with the feed overridden: `defaults write app.backglance.Backglance SUFeedURL http://localhost:8000/appcast.xml`.
4. Settings ▸ Updates ▸ *Check for Updates…* — confirm the EdDSA signature is accepted, the download installs, the app relaunches, the archive migrates without error, and Settings ▸ Status shows the new version.
5. Remove the override: `defaults delete app.backglance.Backglance SUFeedURL`.

Details of the release pipeline are in [`../deployment/DEPLOYMENT_GUIDE.md`](../deployment/DEPLOYMENT_GUIDE.md).

## Security Patching

What counts as a security fix for Backglance:

- Any change to what is written to logs or diagnostics (a content leak is a security bug, not a logging bug).
- Any change to archive file permissions, the snapshot directory, or `PanicWipe`.
- Upstream fixes in **SQLite** (shipped with macOS — nothing to do except note the macOS version that fixes it), **SQLCipher** (v1.x optional build; bump `GRDB.swift/SQLCipher`), and **Sparkle** (updater signature/installation flaws).
- Sandbox-adjacent issues: the app is not sandboxed and holds FDA, so anything that lets untrusted input (a notification body, a `backglance://` URL) reach a file path, a shell, or a `NSWorkspace.open` without validation.

**Expedited release**: for a security fix, skip the normal beta soak. Tag `vX.Y.Z`, let `release.yml` build/sign/notarize, publish the appcast, bump the cask, and post a GitHub Security Advisory. Target: fix published within 72 hours of confirmation, 48 hours for Sparkle upstream advisories.

**CVE watch**: subscribe to GitHub Security Advisories for `sparkle-project/Sparkle`, `groue/GRDB.swift`, and `sqlcipher/sqlcipher`; check the SQLite release notes at each macOS point release. Reports to Backglance itself go through [`../security/SECURITY.md`](../security/SECURITY.md).

## Fixture Refresh When a New macOS Ships

⚠️ Capture reads Apple's ⚠️ undocumented system store. Every macOS release — betas included — can change it. This checklist links to the detailed procedure in [`../architecture/OS_COMPATIBILITY_PLAYBOOK.md`](../architecture/OS_COMPATIBILITY_PLAYBOOK.md); the short form lives here so it is not forgotten.

- [ ] **Beta 1 (June):** install on a test volume or VM, run `Scripts/verify_fixture.sh --live` to compute the `StoreFingerprint`; compare `schemaHash` and `dbinfoVersion` against `Tests/Fixtures/SystemStore/macOS26/manifest.json`. Record the result in the playbook's fingerprint table.
- [ ] **Fixture generation:** if the fingerprint changed, run `Scripts/make_fixture.sh --os 27 --seed 42` to produce `Tests/Fixtures/SystemStore/macOS27/{store.db,manifest.json,expected.json}` — **synthetic only**, generated with a seeded RNG, never a copy of a real store.
- [ ] **Adapter decision:** if `StoreAdapterV26.probe()` returns `.ok` on the new fixture → add `27` to `supportedOS`; if `.missingTables`/`.unknownSchema` → create `StoreAdapterV27`. Registry order: fingerprint match, then OS-major fallback with `probe()`.
- [ ] **CI matrix:** add `macos-27` to `ci.yml` and `fixtures.yml` as `continue-on-error: true` until GM, then required.
- [ ] **Compat table:** update the OS compatibility table (identical copy in `README.md` and the playbook) — status `🧪 Best-effort during beta` until GM, then `✅ Supported`.
- [ ] **README:** update the "Supported macOS" line and the Homebrew cask `depends_on macos` if the minimum changes (it does not for macOS 27; deployment target stays 14.0).
- [ ] **Intel:** macOS 27 is Apple silicon only; note in the compat table that Intel support ends at macOS 26 (still built Universal 2).
- [ ] **GM:** re-run fingerprint, finalize adapter, remove `continue-on-error`, ship a release the same week.

## Archive Migrations Maintenance

Rules that do not bend:

- **Never delete or edit a released migration.** `v1_initial`, `v1_fts`, `v2_saved_searches`, `v3_snoozes`, `v4_embeddings`, `v5_sync_metadata` — once shipped, a migration's body is frozen. Fix mistakes with a new migration.
- **Never rename a migration identifier.** GRDB tracks applied migrations by name in `grdb_migrations`; renaming re-runs it.
- `eraseDatabaseOnSchemaChange = true` is `#if DEBUG` only. A release build that hits an unknown schema state stops with `ArchiveError.migrationFailed` and the corruption path above — it never erases.

**Test upgrade from every released version.** `Tests/Fixtures/Archive/` keeps one small archive per released version, created by that exact release and filled with synthetic rows:

```
Tests/Fixtures/Archive/
├── v1.0.0.sqlite
├── v1.0.0.sqlite-README.md    # how it was made, row counts, seed
├── v1.1.0.sqlite
└── ...
```

The test copies each fixture to a temp path, opens it with the current `ArchiveMigrations`, and asserts:

```swift
// Tests/BackglanceCoreTests/ArchiveUpgradeTests.swift
import XCTest
import GRDB
@testable import BackglanceCore

final class ArchiveUpgradeTests: XCTestCase {
    func testUpgradeFromEveryReleasedArchive() throws {
        let fixtures = try FileManager.default.contentsOfDirectory(
            at: Bundle.module.resourceURL!.appendingPathComponent("Archive"),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "sqlite" }
        XCTAssertFalse(fixtures.isEmpty, "no archive fixtures found")

        for fixture in fixtures {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
            try FileManager.default.copyItem(at: fixture, to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }

            let archive = try Archive(path: tmp.path)          // runs migrations
            let (version, integrity, count) = try archive.readSync { db -> (String, String, Int) in
                let v = try String.fetchOne(db, sql: "SELECT value FROM schema_meta WHERE key = 'archive_version'") ?? ""
                let i = try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? ""
                let c = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notifications") ?? -1
                return (v, i, c)
            }
            XCTAssertEqual(version, ArchiveMigrations.currentVersion, "\(fixture.lastPathComponent) did not reach current version")
            XCTAssertEqual(integrity, "ok", "\(fixture.lastPathComponent) integrity after upgrade")
            XCTAssertGreaterThan(count, 0, "\(fixture.lastPathComponent) lost rows during upgrade")
        }
    }
}
```

Adding a fixture is part of the release checklist: after tagging `vX.Y.Z`, run the released build against a fresh profile with `BACKGLANCE_FIXTURE_SEED=42 BACKGLANCE_HOME=/tmp/bg-fixture` (a debug hook that inserts 500 synthetic notifications), copy the resulting `archive.sqlite` into `Tests/Fixtures/Archive/vX.Y.Z.sqlite`, and commit. See [`../architecture/DATABASE_SCHEMA.md`](../architecture/DATABASE_SCHEMA.md) for the migration list.

## Backup Guidance for Users

- **Time Machine covers it.** Everything Backglance stores is under `~/Library/Application Support/Backglance/` (archive, icons, tmp) and `~/Library/Preferences/app.backglance.Backglance.plist`. Time Machine backs these up by default; nothing to configure. The WAL file is checkpointed on quit, so a backup taken while the app is not running is always consistent; one taken while running is consistent as of the last checkpoint (at most a few minutes behind).
- **Manual export.** Timeline ▸ File ▸ Export… (CSV or JSON, date range or selection) produces a human-readable copy. It is *not* re-importable in v1.0 — it is for your records, not a restore path.
- **Moving to a new Mac.** Quit Backglance on both machines. Copy `~/Library/Application Support/Backglance/archive.sqlite` (and `archive.sqlite-wal` if present) to the same path on the new Mac, then launch. Migrations run if the new Mac has a newer Backglance. Migration Assistant does this automatically for the home folder. Grant FDA again on the new Mac — TCC permissions never travel.
- **Before a panic wipe.** If there is any chance you will want the archive back, quit the app and copy `archive.sqlite` somewhere first — the wipe uses `secure_delete` and there is no undo. Wipe deletes archive, WAL, SHM, icons, tmp snapshots, and embeddings.
- **CloudKit sync is not a backup** (v1.x, opt-in). Sync propagates deletions; a wipe or a retention-pruned notification on one Mac disappears from the others. Sync also carries only notifications within the retention window. Use Time Machine.

> 💡 **Tip:** To make a consistent manual backup while the app is running: `sqlite3 ~/Library/Application\ Support/Backglance/archive.sqlite ".backup ~/Desktop/backglance-backup.sqlite"` — the `.backup` command uses SQLite's online backup API and produces a single-file copy.

## Uninstall

Homebrew:

```bash
brew uninstall --zap --cask backglance
# --zap removes the app plus the paths listed in the cask's zap stanza:
# ~/Library/Application Support/Backglance, ~/Library/Logs/Backglance,
# ~/Library/Preferences/app.backglance.Backglance.plist,
# ~/Library/Caches/app.backglance.Backglance
```

Manual:

```bash
osascript -e 'quit app "Backglance"'
rm -rf /Applications/Backglance.app
rm -rf ~/Library/Application\ Support/Backglance
rm -rf ~/Library/Logs/Backglance
rm -f  ~/Library/Preferences/app.backglance.Backglance.plist
rm -rf ~/Library/Caches/app.backglance.Backglance
# Remove the Full Disk Access grant (optional; the row otherwise lingers greyed-out)
tccutil reset SystemPolicyAllFiles app.backglance.Backglance
# Remove the login item registration if it was enabled
# (SMAppService unregisters on app removal at next login; to force it now:)
sfltool resetbtm 2>/dev/null || true
```

Keychain: v1.0 stores nothing in the Keychain. If v1.x SQLCipher was enabled, delete the item `app.backglance.Backglance.archive-key` in Keychain Access.

## Yearly Tasks

| When | Task | Notes |
|---|---|---|
| Program anniversary | Renew the Apple Developer Program membership | Without it, notarization and new Developer ID certificates stop. Existing notarized builds keep launching. |
| Certificate expiry (Developer ID Application certs are valid **5 years**) | Create a new Developer ID certificate, update `DEVELOPER_ID_CERT_P12_BASE64` / `DEVELOPER_ID_CERT_PASSWORD` in GitHub secrets, ship one release signed with the new cert before the old one expires | Already-notarized builds keep working after expiry (the notarization ticket, not the certificate date, is what Gatekeeper checks). Sparkle updates from an old-cert build to a new-cert build work as long as the Team ID is unchanged. |
| Yearly | Rotate the Sparkle EdDSA key? **No.** | Rotating the key would break updates for every installed copy. Keep it in a password manager and offline backup. Only rotate on compromise, with a two-hop appcast (old key signs a release that ships the new key). |
| Yearly | Rotate `NOTARY_PASSWORD` (app-specific password) and `HOMEBREW_TAP_TOKEN` | Cheap; do it when renewing the program |
| Yearly (June) | macOS beta fixture cycle | See above |
| Yearly | Re-read the `LICENSE` headers and the compatibility table for stale claims | Boring; also where the truth drifts |

Plan the certificate renewal a full release cycle ahead: check `security find-identity -v -p codesigning` for the expiry date and put a calendar reminder 90 days before.

## On-Call for One Person

There is no rotation; there is a solo developer and a phone. This is the routine for the morning a macOS update ships and capture breaks for everyone at once.

**Detection (before coffee):**
- GitHub issues with the `capture-degraded` label spike, and users paste `adapter.json` from the diagnostics export showing `ProbeResult.unknownSchema` or `.missingTables`.
- The app itself is already in `.degraded(.unknownSchema(fp))` — nothing is written to the archive that could be wrong, and the archive is untouched. The user-facing banner says so. That is the design working, not failing.

**Triage (30 minutes):**
1. Pin an issue: "macOS 26.x changed the notification store; capture is degraded; archive is safe; hotfix ETA." Link the troubleshooting scenario.
2. Update the test Mac (or VM) to the new build. Run `Scripts/verify_fixture.sh --live` and read the diff against the last fixture manifest — table renamed? column dropped? `dbinfo` bumped?
3. Decide: extend the existing adapter's `matches()` (column rename), or a new adapter (structural change).

**Fix (hours, not days):**
4. Generate a synthetic fixture for the new schema, write the adapter or the patch, run the fixture matrix locally.
5. Bump patch version, tag, let `release.yml` build/notarize, publish the appcast, bump the cask. Users on auto-update get it within their check interval; the pinned issue tells everyone else to use "Check for Updates".
6. Update the playbook fingerprint table and the compat table.

**After:**
7. Close the pinned issue with what changed and the fingerprint hash. Add the fixture to `fixtures.yml`.
8. If the change was structural, write it into [`../architecture/OS_COMPATIBILITY_PLAYBOOK.md`](../architecture/OS_COMPATIBILITY_PLAYBOOK.md) so the next one is faster.

> ✅ **Do:** keep a spare test volume with the previous macOS point release around, so a fingerprint diff is always available without relying on memory of "what it used to look like".

## Next Steps

- User-facing symptoms of every job in this document are catalogued in [`./TROUBLESHOOTING.md`](./TROUBLESHOOTING.md).
- What each job logs, and how to read it, is in [`./MONITORING_LOGGING.md`](./MONITORING_LOGGING.md).
- The release pipeline that ships hotfixes is in [`../deployment/DEPLOYMENT_GUIDE.md`](../deployment/DEPLOYMENT_GUIDE.md) and [`../deployment/CI_CD.md`](../deployment/CI_CD.md).

## Related Documentation

- [`./MONITORING_LOGGING.md`](./MONITORING_LOGGING.md)
- [`./TROUBLESHOOTING.md`](./TROUBLESHOOTING.md)
- [`../architecture/OS_COMPATIBILITY_PLAYBOOK.md`](../architecture/OS_COMPATIBILITY_PLAYBOOK.md)
- [`../architecture/DATABASE_SCHEMA.md`](../architecture/DATABASE_SCHEMA.md)
- [`../features/PRIVACY_CONTROLS.md`](../features/PRIVACY_CONTROLS.md)
- [`../features/CLOUDKIT_SYNC.md`](../features/CLOUDKIT_SYNC.md)
- [`../deployment/DEPLOYMENT_GUIDE.md`](../deployment/DEPLOYMENT_GUIDE.md)
- [`../deployment/PACKAGING_NOTARIZATION.md`](../deployment/PACKAGING_NOTARIZATION.md)
- [`../deployment/CI_CD.md`](../deployment/CI_CD.md)
- [`../deployment/PERFORMANCE_GUIDE.md`](../deployment/PERFORMANCE_GUIDE.md)
- [`../security/SECURITY.md`](../security/SECURITY.md)
- [`../testing/TESTING.md`](../testing/TESTING.md)
- [`../../CHANGELOG.md`](../../CHANGELOG.md)
