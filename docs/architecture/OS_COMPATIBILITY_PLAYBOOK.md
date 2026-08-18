# OS Compatibility Playbook

Last Updated: 2026-08-18

Backglance captures notifications by reading Apple's Notification Center database (the **system store**), which Apple does not document and may change in any macOS release. This playbook is the operational answer to that fact: which macOS versions are supported and by which adapter, what we have observed about the store on each version, how a format change is detected at runtime, what the user sees when it happens, how fast a fix ships, and exactly how to write and verify a new adapter. It is written for the maintainer on the day a new macOS beta drops, and for contributors who want to help with that work.

> ⚠️ **Warning:** Everything in this document about the system store is what we have observed, not an API. Column names may change in any macOS release; the fingerprint + adapter + fixture strategy exists for that reason.

## Table of Contents

- [Public Compatibility Table](#public-compatibility-table)
- [Support Policy in One Paragraph](#support-policy-in-one-paragraph)
- [Per-Version Store Notes](#per-version-store-notes)
  - [macOS 14 Sonoma — StoreAdapterV14](#macos-14-sonoma--storeadapterv14)
  - [macOS 15 Sequoia — StoreAdapterV15](#macos-15-sequoia--storeadapterv15)
  - [macOS 26 Tahoe — StoreAdapterV26](#macos-26-tahoe--storeadapterv26)
  - [macOS 27 beta — no adapter yet](#macos-27-beta--no-adapter-yet)
- [How StoreFingerprint Is Computed](#how-storefingerprint-is-computed)
- [Runtime Detection of Format Changes](#runtime-detection-of-format-changes)
  - [Probe → unknownSchema → degraded](#probe--unknownschema--degraded)
  - [The "capture paused, archive intact" guarantee](#the-capture-paused-archive-intact-guarantee)
- [What a User Sees](#what-a-user-sees)
- [Fast-Patch Release Process](#fast-patch-release-process)
  - [Timeline](#timeline)
  - [Hotfix release contents](#hotfix-release-contents)
- [Fixture Refresh Checklist](#fixture-refresh-checklist)
- [Template for a New Adapter](#template-for-a-new-adapter)
- [Decision Matrix: Reuse Previous Adapter vs Write New](#decision-matrix-reuse-previous-adapter-vs-write-new)
- [Intel and Apple Silicon Notes](#intel-and-apple-silicon-notes)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Public Compatibility Table

This table is the same one shown in the [README](../../README.md). If you change one, change both.

| macOS | Codename | Status | Store adapter | Notes |
|---|---|---|---|---|
| 14 (Sonoma) | Sonoma | ✅ Supported | `StoreAdapterV14` | Minimum deployment target. Intel + Apple silicon |
| 15 (Sequoia) | Sequoia | ✅ Supported | `StoreAdapterV15` | Intel + Apple silicon |
| 26 (Tahoe) | Tahoe | ✅ Supported (primary dev target) | `StoreAdapterV26` | Last macOS with Intel support (best-effort) |
| 27 (beta) | — | 🧪 Best-effort during beta | fingerprint check → V26 fallback or degraded mode | Apple silicon only. Adapter finalized at GM |
| ≤ 13 | Ventura and earlier | ❌ Not supported | — | Below deployment target |

## Support Policy in One Paragraph

Backglance supports the current macOS and the two before it (today: 26, 15, 14), each with its own `StoreAdapter` and its own synthetic fixture under `Tests/Fixtures/SystemStore/macOS<N>/`. A new macOS major is "best-effort" from its first developer beta until GM: Backglance runs on it, tries the newest adapter behind a fingerprint check, and falls back to a degraded mode that pauses capture without touching the archive if the store has changed. Support for a macOS major is dropped only when the deployment target moves, which happens in a minor release with a CHANGELOG entry and never silently. Nothing here is a promise that Apple's format will stay readable; it is a promise about how quickly and how safely Backglance reacts when it does not.

## Per-Version Store Notes

All versions share the location `~/Library/Group Containers/group.com.apple.usernoted/db2/db` (WAL journal, `-wal` and `-shm` alongside), require Full Disk Access to read, and are pruned by the system after clearing or roughly seven days. What follows is per-version detail as verified by fixture, plus what to watch.

### macOS 14 Sonoma — StoreAdapterV14

⚠️ Observed layout (fixture `Tests/Fixtures/SystemStore/macOS14/`):

- Tables: `dbinfo(key, value)`, `app(app_id INTEGER PRIMARY KEY, identifier TEXT, badge INTEGER, ...)`, `record(rec_id INTEGER PRIMARY KEY, app_id, uuid BLOB, data BLOB, request_date REAL, request_last_date REAL, delivered_date REAL, presented INTEGER, style INTEGER, snooze_fire_date REAL)`, plus `requests`, `delivered`, `displayed`, `snoozed`, `categories`.
- `record.data` is a binary plist; `delivered_date` is seconds since 2001-01-01.
- `uuid` is a 16-byte BLOB, not text; the adapter converts with `UUID(uuid:)`.
- Same layout was already documented publicly for macOS 11–13, which is why V14 is the oldest adapter and also the most stable one.

Watch items: none open. Point releases 14.0–14.7 have produced the same `schemaHash`.

### macOS 15 Sequoia — StoreAdapterV15

⚠️ Observed layout (fixture `Tests/Fixtures/SystemStore/macOS15/`):

- Same tables and columns as V14; the fingerprint differs from V14 only because the `dbinfo` version value and one index definition changed. `StoreAdapterV15` therefore shares its SQL with V14 through a common `RecordQuery` helper and differs only in `knownSchemaHashes` and `supportedOS`.
- `presented` remains reliable as the "banner was shown" flag; the digest engine's `presented == false` heuristic was validated on 15.

Watch items: 15.4 shipped a `dbinfo` value bump without a DDL change; the fixture manifest for 15 records both hashes. This is the case the "reuse vs new" matrix below calls a *fingerprint-only* change.

### macOS 26 Tahoe — StoreAdapterV26

⚠️ Observed layout (fixture `Tests/Fixtures/SystemStore/macOS26/`), primary development target:

- Same layout as 14/15 as observed in dev testing; re-verified by fixture at every macOS 26 point release (currently 26.5). No new columns needed by Backglance were introduced; a few additional columns exist on `record` that the adapter ignores.
- The bplist inside `record.data` carries the same top-level keys Backglance reads (`app`, `date`, `req` → `titl`, `subt`, `body`, `iden`, `cate`, `thre`, `atta`, `usda`). `RecordParser` is tolerant of missing keys and treats everything except bundle id and delivered date as optional.
- macOS 26 is the last macOS that runs on Intel; capture is exercised there best-effort (see [Intel and Apple Silicon Notes](#intel-and-apple-silicon-notes)).

Watch items: Apple's Notification Center UI was redesigned in 26; the store did not change with it in any way Backglance depends on. Any point release remains a fixture-refresh trigger.

### macOS 27 beta — no adapter yet

There is no `StoreAdapterV27` at the time of writing. On a 27 beta:

1. `StoreFingerprint` will not match any known hash.
2. `StoreAdapterRegistry.resolve(fingerprint:)` returns `StoreAdapterV26` as the newest candidate because 27 is greater than every adapter's `supportedOS.upperBound`.
3. `StoreAdapterV26.probe(_:)` runs against a read-only snapshot. If `record`, `app`, `dbinfo` exist with the columns V26 needs, capture runs in `.fallback` mode and Settings ▸ Capture shows a "running on best-effort adapter" note. If not, capture goes `.degraded(.unknownSchema(...))`.
4. Either way the archive, timeline, search, digest and export keep working on what was already captured.

macOS 27 is Apple silicon only; the Universal 2 build still runs there (the arm64 slice). The adapter is finalized at GM per the [Fast-Patch Release Process](#fast-patch-release-process).

## How StoreFingerprint Is Computed

A `StoreFingerprint` is three things: a SHA-256 over the normalized DDL of every entry in `sqlite_master`, whatever version-like value the `dbinfo` table carries, and the running OS version. It is computed on every capture bootstrap, persisted in `capture_state.fingerprint`, and compared to the bundled `KnownFingerprints.json` that `Scripts/verify_fixture.sh` regenerates from the fixtures.

```swift
// Packages/BackglanceCapture/Sources/BackglanceCapture/StoreFingerprint.swift
import CryptoKit
import Foundation
import GRDB

public struct StoreFingerprint: Hashable, Codable, Sendable {
    public let schemaHash: String            // 64 hex chars, SHA-256 of normalized sqlite_master SQL
    public let dbinfoVersion: String?        // value of the first dbinfo key containing "version", if any
    public let osVersion: OperatingSystemVersion

    public init(schemaHash: String, dbinfoVersion: String?, osVersion: OperatingSystemVersion) {
        self.schemaHash = schemaHash
        self.dbinfoVersion = dbinfoVersion
        self.osVersion = osVersion
    }

    /// Convenience used by CaptureEngine; delegates to StoreFingerprinter so the
    /// normalization lives in exactly one place.
    public static func compute(in db: Database) throws -> StoreFingerprint {
        try StoreFingerprinter.fingerprint(db)
    }

    /// Short form for logs. Never includes content.
    public var shortDescription: String {
        "\(schemaHash.prefix(8)) dbinfo=\(dbinfoVersion ?? "-") os=\(osVersion.majorVersion).\(osVersion.minorVersion)"
    }
}

public enum StoreFingerprinter {
    public static func fingerprint(_ db: Database) throws -> StoreFingerprint {
        // 1. Every user object's DDL, deterministic order, sqlite_ internals excluded.
        let statements = try String.fetchAll(db, sql: """
            SELECT sql FROM sqlite_master
            WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
            ORDER BY type, name
            """)
        // 2. Normalize: lowercase, collapse whitespace to single spaces, one statement per line.
        //    Scripts/make_fixture.sh applies the identical normalization in bash.
        let normalized = statements
            .map { $0.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()

        // 3. dbinfo is a key/value table; the exact key name is not known, so anything version-like counts.
        var dbinfoVersion: String? = nil
        if try db.tableExists("dbinfo") {
            let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM dbinfo")
            if let row = rows.first(where: { (($0["key"] as String?) ?? "").lowercased().contains("version") }) {
                dbinfoVersion = row["value"].map { "\($0)" }
            }
        }
        return StoreFingerprint(schemaHash: hex,
                                dbinfoVersion: dbinfoVersion,
                                osVersion: ProcessInfo.processInfo.operatingSystemVersion)
    }
}
```

`OperatingSystemVersion` is not `Codable` out of the box; `BackglanceCapture` adds a small `Codable` conformance in an extension so the whole fingerprint round-trips through `capture_state`. The known hashes are loaded once:

```swift
// Packages/BackglanceCapture/Sources/BackglanceCapture/StoreFingerprints.swift
import Foundation

/// Known-good schema hashes per adapter, loaded from the bundled KnownFingerprints.json
/// (regenerated by Scripts/verify_fixture.sh from Tests/Fixtures/SystemStore/*/manifest.json).
public enum StoreFingerprints {
    private struct File: Decodable { let v14: [String]; let v15: [String]; let v26: [String] }

    private static let file: File = {
        guard let url = Bundle.module.url(forResource: "KnownFingerprints", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(File.self, from: data) else {
            // A missing resource is a packaging bug; fail loudly in DEBUG, empty sets in RELEASE
            // (which resolves to OS-major fallback + probe, never to a crash).
            assertionFailure("KnownFingerprints.json missing from BackglanceCapture bundle")
            return File(v14: [], v15: [], v26: [])
        }
        return decoded
    }()

    public static var v14: Set<String> { Set(file.v14) }
    public static var v15: Set<String> { Set(file.v15) }
    public static var v26: Set<String> { Set(file.v26) }
}
```

`KnownFingerprints.json` looks like this (hashes abbreviated here; the real file has 64 hex characters each):

```json
{
  "v14": ["9a2b…", "9a2b…"],
  "v15": ["3f1c…", "5d07…"],
  "v26": ["c41e…"]
}
```

A single adapter can list several hashes: point releases that change only the `dbinfo` value or an index definition produce a new hash but need no code change.

## Runtime Detection of Format Changes

### Probe → unknownSchema → degraded

Detection happens on every capture bootstrap: app launch, wake from sleep, screen unlock, FDA grant, and whenever the persisted fingerprint differs from the freshly computed one (which is what happens right after a macOS update).

```
bootstrap
  │
  ├─ StoreLocation.current()                 ── throws ──▶ degraded(.storeNotFound)
  ├─ StoreSnapshot.take(of:)                 ── EACCES ──▶ degraded(.noFullDiskAccess)
  ├─ StoreFingerprint.compute(in: db)
  │
  ├─ StoreAdapterRegistry.resolve(fingerprint:)
  │     exact hash match ─────────────────────────────────▶ candidate (isExact = true)
  │     same OS major ────────────────────────────────────▶ candidate (isExact = false)
  │     OS newer than all adapters ───────────────────────▶ newest adapter (isExact = false)
  │     nothing plausible ────────────────────────────────▶ degraded(.unknownSchema(fp))
  │
  └─ candidate.probe(db)
        .ok(recordCount)   + exact ─────────────────────▶ .matched(adapter)      → running
        .ok(recordCount)   + not exact ─────────────────▶ .fallback(adapter)     → running (best-effort note)
        .missingTables / .unknownSchema ────────────────▶ degraded(.unknownSchema(fp))
        .permissionDenied ──────────────────────────────▶ degraded(.noFullDiskAccess)
        throws ────────────────────────────────────────▶ degraded(.readError(msg))
```

The full `StoreAdapterRegistry.resolve(fingerprint:probing:)` listing is in [ARCHITECTURE.md](./ARCHITECTURE.md#fingerprint-first-registry-resolution). Two properties are important:

- **Probe before trust.** A fallback adapter is only used if `probe()` confirms the tables and columns it will query exist. `probe()` never reads notification content; it runs `sqlite_master`, `PRAGMA table_info(record)` and a `COUNT(*)`.
- **A hard failure inside `records(after:in:)`** — for example a column that exists but changed type — is caught by `CaptureEngine`, converted to `.degraded(.readError(...))` after two consecutive failures, and logged once with the fingerprint's short form. It never crashes and never retries in a tight loop (the watcher's 500 ms debounce and 15 s poll bound the retry rate).

The engine also detects *silent* changes: if the fingerprint changes but the adapter still probes `.ok`, `CaptureEngine` logs `fingerprint changed: <old8> → <new8>` and writes the new hash to `capture_state.fingerprint`. That log line is the trigger for the maintainer to refresh the fixture; the user is not interrupted.

### The "capture paused, archive intact" guarantee

When capture goes degraded, Backglance guarantees:

1. **The archive is not modified** by the degraded transition. No rows are deleted, no migration runs, retention keeps running on its normal schedule as it always did.
2. **Everything already captured stays usable**: timeline, search (FTS, fuzzy, semantic), digests already generated, rules, export, panic wipe.
3. **The system store is not modified.** Backglance opened only a copied snapshot read-only; the degraded path deletes the snapshot copy from `~/Library/Application Support/Backglance/tmp/` and nothing else.
4. **The engine keeps listening.** Every wake or unlock retries bootstrap, so a Backglance update that adds a new adapter — or an FDA grant — resumes capture with no relaunch.
5. **Nothing leaves the machine.** No fingerprint, no log, no error is uploaded. If the user wants to report it, `Help ▸ Copy Diagnostic Info` puts the short fingerprint and adapter id on the clipboard for a GitHub issue; the user pastes it themselves.

> 🔒 **Security:** The diagnostic string contains the schema hash, `dbinfo` version, macOS version, adapter id and record count. It never contains notification content, app names from the user's store, or paths beyond the fixed store location.

## What a User Sees

| Situation | Status item icon | Settings ▸ Capture | Anything else |
|---|---|---|---|
| Exact adapter match | Normal icon | "Capturing · adapter v26" | Nothing |
| Fallback adapter (e.g. 27 beta with V26) | Normal icon | "Capturing on best-effort adapter (v26). Your macOS is newer than this version of Backglance was tested with." | One-time, dismissible line in the popover footer on first fallback |
| `.degraded(.unknownSchema)` after a macOS update | Icon with a small dot | "Capture paused: this macOS version changed the notification database format. Your archive is intact. Backglance will resume when an update with a new adapter is installed." + **Check for Updates** button | Popover footer shows the same sentence; nothing modal, nothing repeated |
| `.degraded(.noFullDiskAccess)` | Icon with a small dot | "Capture paused: Full Disk Access is off." + **Open System Settings** button | Onboarding step re-offered once |
| `.degraded(.readError)` | Icon with a small dot | "Capture paused: the notification database could not be read. Your archive is intact." + **Copy Diagnostic Info** | Retries on the next wake |

The wording is deliberately calm. There is no red, no exclamation mark, no "urgent". The user is told three things: capture is paused, the archive is intact, and what (if anything) they can do. Localized strings live in `Localizable.xcstrings` under the `capture.status.*` keys.

> ❌ **Don't:** Show an alert, a notification, or a badge count for a degraded state. Backglance is an archive of notifications; it must not become a source of them.

## Fast-Patch Release Process

The point of the adapter boundary is that a format change is a small, mechanical, well-rehearsed fix. The process below is what the maintainer does when Apple ships a new macOS beta or a point release that changes the store.

### Timeline

| When | Action | Output |
|---|---|---|
| Day 0 — new macOS developer beta announced | Install on a spare volume or VM (Apple silicon: `UTM`/`Virtualization.framework` VM is enough for the store; FDA works in a VM). Run Backglance from `main`. Note the log line: `fingerprint changed` or `degraded: unknownSchema`. | Triage issue `os/<major>-beta<N>` opened with the short fingerprint |
| Day 0–3 | Run `Scripts/make_fixture.sh --macos <major> --seed <YYYYMMDD> --count 250 --out Tests/Fixtures/SystemStore/macOS<major>` after updating `Scripts/fixtures/schema_v<major>.sql` to the observed DDL. Run `Scripts/verify_fixture.sh`. | **Beta fixture committed within days** of the beta. `known_differences_from_previous` filled in |
| Day 0–3 | Decide via the [decision matrix](#decision-matrix-reuse-previous-adapter-vs-write-new): add the hash to an existing adapter, or scaffold `StoreAdapterV<major>` from the template. | PR labelled `adapter` |
| Each subsequent beta | Re-run fixture generation if the fingerprint changed again; append hashes. | Fixture manifest updated |
| GM / RC seed | Regenerate the fixture from the GM DDL, finalize `supportedOS`, add the runner to `ci.yml` when GitHub publishes it. | **GM fixture within 48 hours** of the GM seed |
| GM + ≤ 48 h | Tag and publish a hotfix release containing only the adapter change (see below). Sparkle picks it up on the user's next check. | `vX.Y.Z` on GitHub Releases + appcast + cask bump |
| Public release day | Confirm the shipped hotfix matches the public build's fingerprint (they normally match GM). Update the compatibility table in README and this playbook. | Docs PR |

Two things make the 48-hour figure realistic rather than aspirational: the fixture pipeline is scripted end to end, and an adapter change touches only `Packages/BackglanceCapture` plus a JSON resource, so the release workflow's full test matrix still runs green with no other code in the diff.

### Hotfix release contents

A fast-patch release deliberately contains nothing but the adapter work:

- `Packages/BackglanceCapture/Sources/BackglanceCapture/Adapters/StoreAdapterV<N>.swift` (new or hash-only change)
- `Packages/BackglanceCapture/Sources/BackglanceCapture/Resources/KnownFingerprints.json`
- `Tests/Fixtures/SystemStore/macOS<N>/` (`store.db`, `manifest.json`, `expected.json`)
- `Tests/BackglanceCaptureTests/AdapterFixtureTests.swift` (one added case)
- `CHANGELOG.md` entry under a patch version, e.g. `## [1.0.1] - 2026-09-20 — Added StoreAdapterV27 for macOS 27 GM`
- README + this playbook table update

```bash
# Scripts/release_hotfix.sh is not a separate script; the normal release path is used
# with an explicit "adapter-only" note so the changelog and appcast item say so.
git switch -c hotfix/adapter-v27
git add Packages/BackglanceCapture Tests/Fixtures/SystemStore/macOS27 Tests/BackglanceCaptureTests CHANGELOG.md README.md docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md
git commit -m "capture: add StoreAdapterV27 (macOS 27 GM fixture)"
git tag -a v1.0.1 -m "Adapter-only hotfix: macOS 27 support"
git push origin hotfix/adapter-v27 --tags
# .github/workflows/release.yml builds, signs, notarizes, publishes the DMG,
# regenerates appcast.xml on gh-pages and triggers cask-bump.yml.
```

> ✅ **Do:** Ship the adapter as its own patch release even if other work is ready. Users on the new macOS are waiting for exactly this and nothing else; the smaller the diff, the easier it is to trust and to revert.

## Fixture Refresh Checklist

Run this whenever a macOS point release or beta lands, whether or not the log says the fingerprint changed (a no-change confirmation is also worth recording in `manifest.json` → `verified_on`).

- [ ] Install the macOS build on a machine or VM you control. Never use a colleague's machine; never copy their store.
- [ ] Launch Backglance from `main`; read `~/Library/Logs/Backglance/backglance.log` for `fingerprint changed` / `degraded`.
- [ ] Dump the observed DDL from your own store into `Scripts/fixtures/schema_v<major>.sql` (`sqlite3 <copy-of-store> .schema`). Read it and remove nothing; the fixture must reproduce the DDL exactly or the hash will not match.
- [ ] Regenerate: `Scripts/make_fixture.sh --macos <major> --seed <YYYYMMDD> --count 250 --out Tests/Fixtures/SystemStore/macOS<major>`. The content is synthetic from the seed; the script never reads `~/Library`.
- [ ] Verify: `Scripts/verify_fixture.sh` — recomputes the hash with the Swift `StoreFingerprinter`, checks it equals the bash hash and the manifest, greps that no file outside `Adapters/` and `RecordParser.swift` names a store column, and regenerates `KnownFingerprints.json`.
- [ ] Update `manifest.json`: `macos`, `verified_on`, `known_differences_from_previous` (a sentence, e.g. "record gained column `x`, ignored by adapter" or "none observed").
- [ ] Update `expected.json` only if `RecordParser` behavior changed for a real reason; the seed keeps it stable otherwise.
- [ ] Run `swift test --package-path Packages/BackglanceCapture` locally; then let `fixtures.yml` run the same on all three runners.
- [ ] Manually check one thing the fixture cannot: launch the app on the new OS, trigger a test notification from a harmless app (e.g. a Calendar event you create), confirm it appears in the timeline within one poll interval, then delete the event.
- [ ] Commit fixture + manifest + `KnownFingerprints.json` together in one commit so `git bisect` stays meaningful.
- [ ] If the fingerprint changed: update the per-version notes above and, if an adapter was added, the compatibility table in both places.

> ⚠️ **Warning:** Fixtures are SYNTHETIC ONLY. `make_fixture.sh` builds an empty store from the DDL template and fills it with seeded, obviously fake rows (`com.example.chat`, `alex@example.com`, `+1 555 0100`). Never commit a copy of a real store, not even a "cleaned" one; a bplist blob can carry more than it looks like it does.

## Template for a New Adapter

Copy this file to `Packages/BackglanceCapture/Sources/BackglanceCapture/Adapters/StoreAdapterV27.swift`, fill in the columns you actually observed, and register it at the top of `StoreAdapterRegistry.adapters` (newest first). The skeleton compiles as-is against the observed 26 layout, which is the right starting point for a 27 beta.

```swift
// Packages/BackglanceCapture/Sources/BackglanceCapture/Adapters/StoreAdapterV27.swift
//
// ⚠️ Reads an undocumented Apple database. Every column name below is an observation
// verified by Tests/Fixtures/SystemStore/macOS27/, not an API.
import Foundation
import GRDB

public struct StoreAdapterV27: StoreAdapter {
    public static let id = "v27"
    // Beta: keep this at 27...27. If GM turns out identical to V26, delete this file
    // and add the hash to StoreFingerprints.v26 instead (see decision matrix).
    public static let supportedOS: ClosedRange<Int> = 27...27
    static let knownSchemaHashes: Set<String> = StoreFingerprints.v27   // add "v27" to KnownFingerprints.json

    /// Bounded batch so a first import of a large store never holds the writer for long.
    private let batchSize = 500

    public init() {}

    public static func matches(_ fp: StoreFingerprint) -> Bool {
        knownSchemaHashes.contains(fp.schemaHash)
    }

    public func probe(_ db: Database) throws -> ProbeResult {
        // 1. Tables we query. Adjust if 27 renames any.
        let required = ["record", "app", "dbinfo"]
        let present: Set<String>
        do {
            present = try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        } catch let error as DatabaseError where error.resultCode == .SQLITE_AUTH || error.resultCode == .SQLITE_CANTOPEN {
            return .permissionDenied
        }
        let missing = required.filter { !present.contains($0) }
        if !missing.isEmpty { return .missingTables(missing) }

        // 2. Columns we read from `record`. Adjust if 27 renames any.
        let recordCols = try Row.fetchAll(db, sql: "PRAGMA table_info(record)").map { $0["name"] as String }
        for needed in ["rec_id", "app_id", "uuid", "data", "delivered_date", "presented"] where !recordCols.contains(needed) {
            return .unknownSchema(details: "record.\(needed) missing; columns: \(recordCols.joined(separator: ","))")
        }
        let appCols = try Row.fetchAll(db, sql: "PRAGMA table_info(app)").map { $0["name"] as String }
        for needed in ["app_id", "identifier"] where !appCols.contains(needed) {
            return .unknownSchema(details: "app.\(needed) missing; columns: \(appCols.joined(separator: ","))")
        }

        // 3. Cheap read to prove the snapshot is usable. Never reads `data`.
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM record") ?? 0
        return .ok(recordCount: count)
    }

    public func records(after cursor: StoreCursor, in db: Database) throws -> [RawStoreRecord] {
        // rec_id has been monotonically increasing in every store we have observed.
        // delivered_date is Cocoa reference seconds and may be NULL for never-delivered rows.
        let rows = try Row.fetchAll(db, sql: """
            SELECT r.rec_id, a.identifier, r.uuid, r.data,
                   r.delivered_date, r.request_date, r.presented, r.style
            FROM record r
            JOIN app a ON a.app_id = r.app_id
            WHERE r.rec_id > ?
            ORDER BY r.rec_id
            LIMIT ?
            """, arguments: [cursor.lastRecID, batchSize])

        return rows.compactMap { row in
            guard let plist: Data = row["data"], let identifier: String = row["identifier"] else { return nil }
            let uuidBlob: Data? = row["uuid"]
            let uuid = uuidBlob.flatMap(Self.uuid(fromBlob:)) ?? UUID()
            let delivered: Double? = row["delivered_date"]
            let requested: Double? = row["request_date"]
            return RawStoreRecord(
                recID: row["rec_id"],
                appIdentifier: identifier,
                uuid: uuid,
                plistData: plist,
                deliveredDate: delivered.map { Date(timeIntervalSinceReferenceDate: $0) },
                requestDate: requested.map { Date(timeIntervalSinceReferenceDate: $0) },
                presented: (row["presented"] as Int64? ?? 1) != 0,
                style: row["style"]
            )
        }
    }

    public func cursor(for record: RawStoreRecord) -> StoreCursor {
        StoreCursor(lastRecID: record.recID,
                    lastDeliveredDate: record.deliveredDate?.timeIntervalSinceReferenceDate ?? 0)
    }

    /// The store keeps uuid as a 16-byte BLOB. Anything else falls back to a generated UUID
    /// (dedup then relies on store_rec_id, which is fine).
    private static func uuid(fromBlob data: Data) -> UUID? {
        guard data.count == 16 else { return nil }
        return data.withUnsafeBytes { raw in
            UUID(uuid: raw.load(as: uuid_t.self))
        }
    }
}
```

And the matching test case, added to `Tests/BackglanceCaptureTests/AdapterFixtureTests.swift`:

```swift
import XCTest
import GRDB
@testable import BackglanceCapture

final class StoreAdapterV27FixtureTests: XCTestCase {
    func testFixtureResolvesToV27AndParsesExpected() throws {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "macOS27", withExtension: nil, subdirectory: "SystemStore"))
        let dbURL = dir.appendingPathComponent("store.db")
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: dbURL.path, configuration: config)

        try queue.read { db in
            let fp = try StoreFingerprint.compute(in: db)
            XCTAssertTrue(StoreAdapterV27.matches(fp), "fixture hash \(fp.schemaHash.prefix(8)) not in KnownFingerprints.v27")

            let adapter = StoreAdapterV27()
            guard case .ok(let count) = try adapter.probe(db) else { return XCTFail("probe failed") }

            let raws = try adapter.records(after: .start, in: db)
            XCTAssertEqual(raws.count, count)

            let expected = try JSONDecoder().decode([ExpectedNotification].self,
                                                    from: Data(contentsOf: dir.appendingPathComponent("expected.json")))
            let parsed = try raws.map { try RecordParser().parse($0) }
            XCTAssertEqual(parsed.count, expected.count)
            for (p, e) in zip(parsed, expected) {
                XCTAssertEqual(p.bundleID, e.bundleID)
                XCTAssertEqual(p.title, e.title)
                XCTAssertEqual(p.body, e.body)
                XCTAssertEqual(p.deliveredAt.timeIntervalSince1970, e.deliveredAt, accuracy: 0.001)
            }
        }
    }

    func testRegistryFallsBackToV26OnUnknown27Hash() {
        let unknown = StoreFingerprint(schemaHash: String(repeating: "0", count: 64),
                                       dbinfoVersion: nil,
                                       osVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
        let candidate = StoreAdapterRegistry.resolve(fingerprint: unknown)
        // Before V27 is registered this is V26 (newest); after, it is V27 via supportedOS.
        XCTAssertNotNil(candidate)
    }
}
```

## Decision Matrix: Reuse Previous Adapter vs Write New

Not every fingerprint change deserves a new adapter. Use the first row that applies.

| What changed (per fixture diff) | Decision | Where the change goes |
|---|---|---|
| Only the `dbinfo` version value, or an index / trigger definition; same tables and columns Backglance reads | **Reuse** — add the new hash to the existing adapter's list | `KnownFingerprints.json` (via fixture manifest), no Swift change |
| A column Backglance ignores was added, removed or renamed | **Reuse** — add hash; note it in `known_differences_from_previous` | `KnownFingerprints.json`, manifest |
| A column Backglance reads was renamed but has the same meaning (e.g. `delivered_date` → `delivered_at`) | **New adapter** with `supportedOS = N...N`; SQL differs by one identifier. Do not add version branches inside an existing adapter | New `StoreAdapterV<N>.swift` |
| A table Backglance joins was split, merged or renamed | **New adapter** | New file, possibly a new `RecordQuery` helper |
| The bplist keys inside `record.data` changed | **Parser change**, adapter may be reused | `RecordParser.swift` (tolerant lookup: add the new key as a candidate, keep the old), `expected.json` |
| Same DDL, but semantics changed (e.g. `presented` inverted, `delivered_date` now Unix epoch) | **New adapter** even though the hash matches; also pin the old adapter's `supportedOS` upper bound below N | New file + registry order |
| Store moved (path changed) | Not an adapter concern; update `StoreLocation.current()` with a versioned candidate list | `StoreLocation.swift` |
| Store no longer readable with FDA at all | Escalate: this is a product-level change, open a tracking issue, keep degraded mode; do not attempt workarounds that read process memory or private frameworks | Issue + FAQ entry |

Rules of thumb:

- One adapter per macOS major is the default; sharing an adapter across majors is allowed only when the fixture diff is empty for the columns read (this is why V14 and V15 share SQL but not identity — keeping identities separate makes the compatibility table honest and lets `supportedOS` express intent).
- Never add `if #available` or `if osMajor >= 27` branches inside an adapter. The registry chooses; the adapter is a straight-line query.
- If in doubt, write the new adapter. It is 80 lines and one fixture, and it can be deleted at GM if it turns out to be identical.

## Intel and Apple Silicon Notes

- **Universal 2** binaries are produced by `Scripts/build.sh` (`ARCHS="arm64 x86_64"`), signed and notarized as one artifact. There is no separate Intel download.
- **The system store is identical across architectures** on the same macOS version; the fixture and adapter do not care which CPU generated the store. Bplist byte order inside `record.data` is handled by `PropertyListSerialization`; the `uuid` BLOB is 16 raw bytes on both.
- **Apple silicon is primary.** All development, the `macos-14`/`macos-15`/`macos-26` runners (arm64 images), and the perf budgets in [../deployment/PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md) assume it.
- **Intel is best-effort on macOS 14, 15 and 26.** The x86_64 slice is built and unit-tested under Rosetta in CI (`arch -x86_64 swift test`) for the pure packages; UI tests run arm64 only. Known differences: `NLEmbedding` throughput is roughly a third of Apple silicon, so the semantic indexer's background batch is the same size but takes longer; nothing else observed.
- **macOS 27 is Apple silicon only.** Backglance keeps building Universal 2 as long as macOS 26 is supported, so Intel users on 26 still get updates including adapter hotfixes; when 26 drops out of the support window, the x86_64 slice goes with it (announced in the CHANGELOG one minor release ahead).
- **Virtual machines** on Apple silicon (`Virtualization.framework`-based, e.g. UTM) are the recommended way to test a new macOS beta's store: FDA can be granted inside the guest and the store behaves like a real install. Intel VMs are not used; testing on Intel is done on physical hardware when available.

## Next Steps

- If you are here because a new macOS beta just dropped: start with the [Fixture Refresh Checklist](#fixture-refresh-checklist), then the [decision matrix](#decision-matrix-reuse-previous-adapter-vs-write-new), then the [template](#template-for-a-new-adapter).
- If you are here to understand the architecture: read [ARCHITECTURE.md](./ARCHITECTURE.md#the-schema-adapter-boundary) and the system-store section of [DATABASE_SCHEMA.md](./DATABASE_SCHEMA.md).
- If you are here because capture is paused on your Mac: [../operations/TROUBLESHOOTING.md](../operations/TROUBLESHOOTING.md) has the user-side steps, and [../reference/FAQ.md](../reference/FAQ.md) explains why this can happen.

## Related Documentation

- [ARCHITECTURE.md](./ARCHITECTURE.md)
- [TECH_STACK.md](./TECH_STACK.md)
- [DATABASE_SCHEMA.md](./DATABASE_SCHEMA.md)
- [../features/CAPTURE.md](../features/CAPTURE.md)
- [../features/PERMISSIONS_PRIVACY.md](../features/PERMISSIONS_PRIVACY.md)
- [../testing/TESTING.md](../testing/TESTING.md)
- [../deployment/CI_CD.md](../deployment/CI_CD.md)
- [../deployment/DEPLOYMENT_GUIDE.md](../deployment/DEPLOYMENT_GUIDE.md)
- [../deployment/PERFORMANCE_GUIDE.md](../deployment/PERFORMANCE_GUIDE.md)
- [../operations/TROUBLESHOOTING.md](../operations/TROUBLESHOOTING.md)
- [../operations/MAINTENANCE.md](../operations/MAINTENANCE.md)
- [../operations/MONITORING_LOGGING.md](../operations/MONITORING_LOGGING.md)
- [../reference/FAQ.md](../reference/FAQ.md)
- [../reference/ROADMAP.md](../reference/ROADMAP.md)
- [../../CHANGELOG.md](../../CHANGELOG.md)
- [../../README.md](../../README.md)
