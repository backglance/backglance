# Troubleshooting

Last Updated: 2026-08-18

This is the scenario catalogue for when Backglance misbehaves. Each entry follows the same shape — **Symptoms / Cause / Fix / Prevention** — so you can scan for yours. If capture is the problem and you are not sure which entry applies, start with the [decision tree](#decision-tree-capture-isnt-working) near the end. When you are ready to file an issue, [Collecting information for a bug report](#collecting-information-for-a-bug-report) tells you exactly what to attach (never any notification content).

## Table of Contents

- [Capture stopped after a macOS update](#capture-stopped-after-a-macos-update)
- [Full Disk Access reset or broken](#full-disk-access-reset-or-broken)
- [Missing or wrong app icons](#missing-or-wrong-app-icons)
- [Sync conflicts (v1.x CloudKit)](#sync-conflicts-v1x-cloudkit)
- [Archive migration failures](#archive-migration-failures)
- [Popover not opening / hotkey conflict](#popover-not-opening--hotkey-conflict)
- [Unread badge stuck](#unread-badge-stuck)
- [Digest never appears](#digest-never-appears)
- [Digest appears too often](#digest-appears-too-often)
- [Duplicate notifications after import](#duplicate-notifications-after-import)
- [OTP was redacted but I wanted it](#otp-was-redacted-but-i-wanted-it)
- [High CPU usage](#high-cpu-usage)
- [Sparkle "update failed"](#sparkle-update-failed)
- ["Backglance is damaged and can't be opened"](#backglance-is-damaged-and-cant-be-opened)
- [Homebrew cask sha256 mismatch](#homebrew-cask-sha256-mismatch)
- [Launch at login not working](#launch-at-login-not-working)
- [Decision tree: capture isn't working](#decision-tree-capture-isnt-working)
- [Collecting information for a bug report](#collecting-information-for-a-bug-report)
- [Related Documentation](#related-documentation)

---

## Capture stopped after a macOS update

**Symptoms**
- After installing a macOS update, the menu bar icon shows a small warning triangle.
- A banner in the popover reads: *"Capture is paused: this macOS update changed the system notification store in a way Backglance doesn't recognize yet. Your archive is safe and searchable. An update is usually available within days."*
- Settings ▸ Status shows *Capture: Degraded — Unknown store schema* and a store fingerprint hash.
- New notifications stop appearing in the timeline; everything already archived still works.

**Cause**
⚠️ Backglance reads Apple's *undocumented* notification store (`usernoted` database). Apple can — and occasionally does — change its schema in any macOS release. When the store's fingerprint no longer matches any shipped adapter and the OS-major fallback fails its `probe()` sanity check, Backglance deliberately enters degraded mode instead of guessing. Nothing is written, nothing is corrupted; it stops reading rather than misread.

**Fix**
1. Check Settings ▸ Status. If it says *Degraded — Unknown store schema*, this scenario applies; note the fingerprint shown (e.g. `9f2c…4b1a`).
2. Settings ▸ Updates ▸ **Check for Updates**. Schema breaks are hotfix priority; a fix typically ships within days of a macOS release (see the "On-Call for One Person" section of [`./MAINTENANCE.md`](./MAINTENANCE.md#on-call-for-one-person)).
3. If no update is available yet, check the pinned issue at https://github.com/backglance/backglance/issues — there will be one within hours of a widespread break, with an ETA.
4. Your archive is intact. Search, timeline, digest history, rules — all keep working. The only thing missing is *new* capture, and once the update lands, Backglance runs a catch-up import that recovers whatever is still in the system store (the system prunes its own records after clearing / roughly 7 days, so don't wait weeks).
5. Optionally help: Settings ▸ Advanced ▸ **Export Diagnostics…** and attach the zip to the pinned issue. It contains the fingerprint, adapter probe result, and capture status history — **no notification content, ever** (the export is built and tested to exclude it; see [`./MONITORING_LOGGING.md`](./MONITORING_LOGGING.md#diagnostics-export)). Mentioning the fingerprint hash in a comment is enough if you'd rather not attach anything.

**Prevention**
- Keep "Automatically check for updates" enabled so the hotfix arrives on its own.
- If you run macOS betas: expect this every June. The compatibility table in the [`../../README.md`](../../README.md) marks beta OS versions as best-effort.

---

## Full Disk Access reset or broken

**Symptoms**
- Banner: *"Backglance needs Full Disk Access to read notification history."* — even though you granted it before.
- Settings ▸ Status shows *Full Disk Access: Not granted*.
- Common after: a macOS update, moving `Backglance.app` to a different folder, reinstalling, or updating to a build signed with a different certificate.

**Cause**
macOS ties TCC permission grants to the app's location and code signature. A macOS upgrade sometimes resets or re-prompts FDA grants wholesale; moving or re-signing the app makes the existing grant point at an app that no longer exists as far as TCC is concerned. You can also end up with several stale rows for the same app.

**Fix**

The straightforward path:
1. System Settings ▸ Privacy & Security ▸ Full Disk Access.
2. If the **Backglance row is present but the toggle is off** — turn it on, then quit and relaunch Backglance.
3. If the **row is present but greyed out** (can't toggle) — select it, click the **−** button to remove it, then click **+** and add `/Applications/Backglance.app` again. Greyed rows are stale entries pointing at an old copy of the app.
4. If there are **duplicate Backglance entries** — remove all of them with **−**, then add the one in `/Applications` fresh.
5. Quit and relaunch Backglance after any change; TCC grants are read at process start.

The clean-slate path, when the pane misbehaves:

```bash
# Wipe every FDA decision recorded for Backglance, then re-grant from scratch
tccutil reset SystemPolicyAllFiles app.backglance.Backglance
```

Then relaunch Backglance and follow its prompt (it deep-links to the right pane and offers to reveal the app in Finder for drag-and-drop).

**Prevention**
- Keep Backglance in `/Applications` and don't move it after granting FDA.
- After every major macOS upgrade, glance at Settings ▸ Status — Backglance will also tell you itself if the grant went missing.
- Official builds are always signed with the same Developer ID, so updates via Sparkle or Homebrew do not invalidate the grant. Self-built copies have a different (or no) signature and will need their own grant.

---

## Missing or wrong app icons

**Symptoms**
- Some notifications show a generic grey icon instead of the app's icon.
- An app changed its icon in an update but Backglance still shows the old one.

**Cause**
Three distinct cases:
1. **The app is no longer installed.** `NSWorkspace` can't resolve the bundle ID to an app on disk, so there is nothing to fetch. Old notifications from uninstalled apps keep a generic icon (with the bundle ID shown on hover).
2. **The notification came from an iPhone/iPad app** (iPhone Mirroring or Continuity). The bundle ID belongs to an iOS app that has no Mac counterpart on disk.
3. **The icon cache is stale.** Backglance caches icons in `~/Library/Application Support/Backglance/icons/` and refreshes them lazily.

**Fix**
- Cases 1 and 2 are expected behavior — the generic icon is correct because there is no local icon to show.
- Case 3: clear the cache and let it rebuild:

```bash
osascript -e 'quit app "Backglance"'
rm -rf ~/Library/Application\ Support/Backglance/icons/
open -a Backglance
```

Icons repopulate as notifications are displayed. Nothing else is affected — the cache holds only PNG icons keyed by bundle ID.

**Prevention**
- None needed; the weekly cache sweep (see [`./MAINTENANCE.md`](./MAINTENANCE.md#log-rotation-icon-cache-snapshot-cleanup)) removes orphans, and stale icons refresh automatically within 30 days of an app version change.

---

## Sync conflicts (v1.x CloudKit)

> ℹ️ **Status:** Planned for v1.x — not in v1.0. CloudKit sync is opt-in and off by default.

**Symptoms**
- A notification you marked read (or pinned) on one Mac shows as unread (or unpinned) on another, and later flips.
- A notification deleted on one Mac briefly reappears on another before disappearing.

**Cause**
Sync carries flags (`is_read`, `is_pinned`, per-app settings) and deletions between your Macs via your private iCloud database. Conflict resolution is deliberately simple:
- **Flags: last-writer-wins.** The most recent change to a flag, by wall clock of the change, is what all Macs converge to.
- **Delete wins.** If one Mac deletes a notification and another edits its flags, the delete prevails everywhere.

Brief flip-flops are the visible half-second of convergence, not data loss. Notification *content* is never merged — each notification is immutable after capture, so only flags can conflict.

**Fix**
- To see what happened: Settings ▸ Sync ▸ **Conflict Log** lists the last 100 resolved conflicts (timestamp, field, which device won — device names only, no content).
- If convergence seems stuck: Settings ▸ Sync ▸ **Sync Now**; if still stuck, toggle sync off and on (this re-fetches server state; it does not delete anything locally).
- To stop syncing entirely: Settings ▸ Sync ▸ turn off "Sync flags between my Macs". Each Mac keeps its local archive as-is from that moment.

**Prevention**
- Remember sync is not a backup — see [`./MAINTENANCE.md`](./MAINTENANCE.md#backup-guidance-for-users). Deletions propagate.
- Details of what syncs and what never does: [`../features/CLOUDKIT_SYNC.md`](../features/CLOUDKIT_SYNC.md).

---

## Archive migration failures

**Symptoms**
- On launch (usually the first launch after an update) a dialog appears: *"Your archive could not be upgraded. It was set aside unchanged as `archive.corrupt-2026-08-17T091244.sqlite`, and Backglance started a fresh archive. Your old data was not deleted."*
- The timeline is empty or missing history after the dialog.

**Cause**
Either the archive file was corrupted on disk (power loss, disk error, third-party "cleaner" apps touching WAL files) and the pre-migration integrity check failed, or a GRDB migration threw. Backglance never deletes a failing archive — it renames it with a `.corrupt-<date>` infix and starts fresh, so recovery is always possible.

**Fix**
1. Don't panic and don't delete anything. The old file is sitting next to the new one:

```bash
ls -la ~/Library/Application\ Support/Backglance/
# archive.sqlite                          <- the fresh one
# archive.corrupt-2026-08-17T091244.sqlite  <- your old data
```

2. Check whether the old file is actually corrupt — **read-only**, on a copy, never on the original:

```bash
cp ~/Library/Application\ Support/Backglance/archive.corrupt-2026-08-17T091244.sqlite /tmp/check.sqlite
sqlite3 /tmp/check.sqlite "PRAGMA integrity_check;"
```

- If it prints `ok`: the file is fine and the failure was in a migration. This is a bug — file an issue with the diagnostics export and the exact error text from the dialog. GRDB migration errors carry SQLite result codes (e.g. `SQLITE_CONSTRAINT` (19), `SQLITE_ERROR` (1)); the dialog and the log line `archive` category include the code. Keep the `.corrupt` file; once the bug is fixed, renaming it back to `archive.sqlite` (with Backglance quit) and relaunching will migrate it.
- If it prints errors: the file is genuinely damaged. Restore from Time Machine: enter Time Machine in the `~/Library/Application Support/Backglance/` folder, pick a date before the problem, restore `archive.sqlite` (quit Backglance first, move the fresh empty one aside). Alternatively, `sqlite3`'s `.recover` command can often salvage most rows from a damaged file — ask in the issue tracker for help with that.

3. Whichever way it goes, capture into the fresh archive continues meanwhile, so you lose nothing new.

**Prevention**
- Let Time Machine run; the archive directory is covered by default.
- Don't point "disk cleaner" utilities at `~/Library/Application Support/Backglance/` — deleting a `-wal` file out from under a live SQLite database is a classic corruption source.
- Released migrations are frozen and every release is upgrade-tested from every previous release's archive fixture ([`./MAINTENANCE.md`](./MAINTENANCE.md#archive-migrations-maintenance)), which is why this scenario is rare.

---

## Popover not opening / hotkey conflict

**Symptoms**
- Pressing ⌃⌥N does nothing, or triggers something in another app.
- Clicking the menu bar icon works fine (or: the icon is missing entirely).

**Cause**
- The default hotkey ⌃⌥N (Control-Option-N) is registered globally via Carbon `RegisterEventHotKey`. If another app registered it first, registration fails and Backglance logs `hotkey registration failed status=-9878` in the `ui` category; the shortcut silently does nothing.
- If the *icon* is missing: the menu bar is full (laptops with a notch hide overflow items), or the app isn't running.

**Fix**
- Hotkey conflict: Settings ▸ General ▸ **Popover shortcut** — click the recorder and press a new combination. Backglance verifies registration immediately and shows an inline error if the new one is also taken.
- To find the squatter: common ⌃⌥N holders include window managers and note-taking apps; check their shortcut settings.
- Missing icon with the app running: remove some other menu bar items or use a menu bar manager; Backglance's icon has no special priority.
- Icon present, popover won't open on click: check `log stream --predicate 'subsystem == "app.backglance.Backglance" AND category == "ui"'` while clicking and file an issue with what appears.

**Prevention**
- Pick a shortcut no other tool wants and leave it; the setting survives updates.

---

## Unread badge stuck

**Symptoms**
- The menu bar badge shows a count (say 12, or 99+) that doesn't clear after opening the popover, or shows a count when the timeline has nothing new.

**Cause**
The badge counts notifications with `is_read = 0` delivered since the last popover open. Opening the popover marks *visible* rows read as you scroll past them; rows further down stay unread by design. A genuinely stuck badge (count with nothing unread visible) usually means unread rows are hidden by a filter (a muted app, or an active search) or, rarely, the badge count query cached a stale value.

**Fix**
1. Open the popover and clear any active search/filter — the unread rows are probably filtered out of view.
2. Timeline ▸ right-click ▸ **Mark All as Read** (or Edit ▸ Mark All as Read in the timeline window) resets `is_read` for everything.
3. If the badge shows a number with truly zero unread rows: quit and relaunch; if it comes back, that's a bug — file it with the diagnostics export.

**Prevention**
- If you use mute rules heavily, remember muted apps still count as unread; there is a setting — Settings ▸ General ▸ "Badge ignores muted apps" — to exclude them.

---

## Digest never appears

**Symptoms**
- You lock your Mac, come back an hour later, notifications arrived — no "What did I miss" digest.

**Cause**
The digest shows only when an away session was *detected* and its contents pass the threshold. Reasons it legitimately doesn't show:
1. **Session under the threshold.** Default: away ≥ 5 minutes with ≥ 1 notification. Sessions shorter than 5 minutes or with zero notifications are auto-suppressed.
2. **Setting.** Settings ▸ Digest ▸ "Show digest" is set to *never*, or "only after ≥ N min" with a large N.
3. **Away not detected.** Detection listens for screen lock/unlock, sleep/wake, Focus, and presenting. If you just walked away without locking (no screensaver-lock, no sleep), there is no signal — macOS provides no "user left" event.
4. ⚠️ **Focus detection is fragile.** Focus sessions are detected by watching `~/Library/DoNotDisturb/DB/Assertions.json` and `ModeConfigurations.json` — undocumented files. If they're missing or their format changed in a macOS update, Focus-based away sessions won't be created (lock/sleep detection still works). Settings ▸ Status shows *Focus detection: unavailable* when the assertion file can't be read.
5. **One digest per away session.** If you already saw (or dismissed) the digest for this session, it won't reappear — check the digest history: popover ▸ clock icon ▸ "Past digests".

**Fix**
- Check Settings ▸ Digest: "Show digest" should be *always* or a threshold you actually cross.
- Lock your screen (⌃⌘Q) when stepping away — it is the most reliable away signal.
- For Focus-based detection marked unavailable: file an issue with your macOS version; that's a fixture-refresh situation on the developer's side.
- To verify detection works at all: lock the screen for 6 minutes while a notification arrives (ask a friend to message you, or use Script Editor: `display notification "test" with title "test"` from another app context), unlock, and the digest should appear.

**Prevention**
- Keep the threshold realistic; "only after ≥ 60 min" quietly hides most digests.

---

## Digest appears too often

**Symptoms**
- Every short absence — grabbing coffee, a 5-minute Focus — produces a digest banner, and it feels naggy.

**Cause**
The threshold is set at (or defaulted to) 5 minutes and your rhythm produces many qualifying sessions. Multiple monitors sleeping/waking or aggressive screen-lock timeouts can also produce more away sessions than you'd expect.

**Fix**
- Settings ▸ Digest ▸ "Show digest: only after ≥ N min" — raise N to 15 or 30.
- Or "never", and read digests on demand from the popover's clock icon instead; they are still built and archived, just not shown proactively.

**Prevention**
- The design guarantee is one digest banner max per away session and none for empty sessions — if you ever see two banners for one absence, that's a bug worth reporting.

---

## Duplicate notifications after import

**Symptoms**
- After first launch (or after re-granting FDA), some notifications appear twice in the timeline with identical text and near-identical timestamps.

**Cause**
The initial `importExisting()` reads what's in the system store; live capture then watches for new records. Dedup normally catches overlap via the store's `rec_id` (unique index `idx_notifications_store_rec`) and the notification `uuid`. Duplicates can slip through when the system store itself re-issued a record with a new `rec_id` and a new UUID (⚠️ observed occasionally around macOS updates when `usernoted` rebuilds its database) — then both copies look distinct to every dedup key.

**Fix**
- Select the duplicates in the timeline and delete one of each (right-click ▸ Delete). Deletion is a soft delete; retention hard-prunes later.
- Bulk case (hundreds of pairs after an OS update): Settings ▸ Advanced ▸ **Deduplicate Archive…** runs a conservative pass that collapses rows with identical `(app, title, subtitle, body, delivered_at within 2 s)`, keeping the earlier row and preserving pins/read state from either copy. It shows a count and asks before touching anything.

**Prevention**
- Nothing user-side; the dedup keys handle the normal path. The deduplicate pass exists precisely for the store-rebuild edge case.

---

## OTP was redacted but I wanted it

**Symptoms**
- A verification-code message from Messages or Mail shows `[code redacted]` where the code was.

**Cause**
OTP redaction is **on by default** for `com.apple.MobileSMS` (Messages) and `com.apple.mail`, because an archive of every one-time code you've ever received is a real liability — anyone with your unlocked Mac (or your archive file) could read historic codes, and codes are useless within minutes anyway. Redaction happens in memory *before* the notification is written to the archive; the digits are never stored anywhere, which also means:

> ⚠️ **Warning:** Redaction is irreversible. There is no "show original" — the original never touched disk. Turning the setting off only affects *future* notifications.

**Fix**
- If you need the code right now: it's still in Messages/Mail itself — Backglance redacts its own archive copy, not the source app.
- To stop redacting future codes for an app: Settings ▸ Privacy ▸ Per-app settings ▸ select the app ▸ untick "Redact one-time codes". You can also add redaction to other apps there.
- The redaction event itself (which pattern matched, when — never the code) is visible per-notification via right-click ▸ "Why is this redacted?".

**Prevention**
- Consider leaving it on. Codes expire in minutes; the archive lives for your retention window. See [`../features/PRIVACY_CONTROLS.md`](../features/PRIVACY_CONTROLS.md) for the pattern list and rationale.

---

## High CPU usage

**Symptoms**
- Activity Monitor shows Backglance above ~1 % CPU sustained while idle, or fans spin up with the app in the background.

**Cause**
Three usual suspects, in order of likelihood:
1. **Semantic indexing in progress.** If you just enabled "Semantic search" (or just imported thousands of notifications), the embedding index is being built in background batches of 50. This is bounded and finishes — expect minutes for tens of thousands of notifications, at low QoS.
2. **A very large archive plus aggressive polling.** At hundreds of thousands of rows with retention `forever`, each poll and each search does more work.
3. **The file-watch fallback poll running hot.** Default poll interval is 15 s (60 s in Low Power Mode); if a third-party tool is continuously touching the system store's WAL, the DispatchSource fires repeatedly and each debounce (500 ms) triggers a snapshot copy.

**Fix**
1. Check Settings ▸ Status — an "Indexing… n of m" line means case 1; just let it finish (plugging into power helps; indexing pauses on battery below 20 %).
2. Case 2: set a finite retention (Settings ▸ General ▸ default retention 30 days is the design point; budgets assume ~100k notifications, see [`../deployment/PERFORMANCE_GUIDE.md`](../deployment/PERFORMANCE_GUIDE.md)), then Settings ▸ Advanced ▸ Run Retention Now.
3. Case 3: raise the poll interval — Settings ▸ Advanced ▸ "Poll interval" to 30 s or 60 s. Capture latency rises accordingly; the DispatchSource path still catches most events instantly.
4. Still hot? Grab 10 seconds of evidence for the issue: `sample Backglance 10 -f ~/Desktop/backglance-sample.txt` and attach it with the diagnostics export (the sample contains stack traces, not notification content — but read it before attaching, as with anything).

**Prevention**
- The idle budget is < 0.1 % average. Anything sustained above that with indexing finished is a bug, not a tuning problem — report it.

---

## Sparkle "update failed"

**Symptoms**
- Settings ▸ Updates ▸ Check for Updates finds the new version, but installation ends with *"An error occurred while installing the update."*

**Cause**
The three that account for nearly all cases:
1. **The app has been moved or renamed** since launch — Sparkle can't replace an app bundle whose path changed mid-flight, and translocated apps (launched from `~/Downloads` or a DMG) can't self-update at all.
2. **Disk permissions** — the app sits in a folder the current user can't write to (e.g. `/Applications` on a managed Mac, or owned by a different user account).
3. **Gatekeeper/quarantine hiccup** — the downloaded update failed its signature or notarization check. Sparkle verifies the EdDSA signature from the appcast *and* macOS verifies the code signature; a corrupted download fails here.

**Fix**
1. Make sure Backglance is in `/Applications` (drag it there, launch it from there once, then update).
2. Check ownership: `ls -la /Applications/ | grep Backglance` — if it's owned by another user, `sudo chown -R "$(whoami)" /Applications/Backglance.app`.
3. Retry the update — transient download corruption resolves on retry.
4. Fallback that always works: download the latest release from https://github.com/backglance/backglance/releases (or `brew upgrade --cask backglance`), quit Backglance, replace the app. The archive is untouched by reinstalls; FDA survives because the signature and location are unchanged.
5. If it keeps failing, run `log stream --predicate 'subsystem == "app.backglance.Backglance" AND category == "updater"' --level debug` during the attempt and include the output in an issue.

**Prevention**
- Install to `/Applications` and leave it there.

---

## "Backglance is damaged and can't be opened"

**Symptoms**
- Launching shows Gatekeeper's *"Backglance is damaged and can't be opened. You should move it to the Trash."*

**Cause**
Almost always a **self-built or unsigned copy** carrying the quarantine attribute: macOS applies `com.apple.quarantine` to files downloaded by a browser, and an unsigned/ad-hoc-signed app with that flag gets the scary "damaged" message rather than the normal unidentified-developer one. Official releases are Developer ID signed *and* notarized, so they never show this. If an *official* download shows it, the download is genuinely corrupted — re-download, and see the cask sha mismatch entry below if via Homebrew.

**Fix**
For your own local/unsigned build that you trust (you built it, you know what's in it):

```bash
xattr -d com.apple.quarantine /Applications/Backglance.app
```

Then launch normally. For an official download showing this message: delete it, re-download from GitHub Releases, and verify before opening:

```bash
spctl -a -vv /Applications/Backglance.app
# expected: accepted, source=Notarized Developer ID,
# origin=Developer ID Application: Backglance (TEAMID1234)
```

**Prevention**
- Build from source via `Scripts/build.sh` and run from the build products, or install official builds via Homebrew — both paths avoid the quarantine trap. See [`../getting-started/SETUP_GUIDE.md`](../getting-started/SETUP_GUIDE.md).

> ❌ **Don't:** run `xattr -d com.apple.quarantine` on apps you didn't build or can't verify. It disables a real safety check.

---

## Homebrew cask sha256 mismatch

**Symptoms**
- `brew install --cask backglance/tap/backglance` fails with `SHA256 mismatch` showing an expected and an actual checksum.

**Cause**
The cask pins the sha256 of the release zip. A mismatch means the download didn't match the pin: usually a stale Homebrew cache or a partially downloaded file; occasionally the cask bump lagged a re-cut release for a few minutes (the `cask-bump.yml` workflow updates the tap automatically on each release, but there is a window).

**Fix**

```bash
# Clear the cached download and retry
brew cleanup --prune=all backglance 2>/dev/null
rm -f ~/Library/Caches/Homebrew/downloads/*[Bb]ackglance*
brew update
brew install --cask backglance/tap/backglance
```

If it still mismatches after `brew update`, wait a few minutes (cask bump in flight) or check the tap repo `backglance/homebrew-tap` for an open bump PR. A mismatch that *persists* against the current cask is worth reporting immediately — it would mean the released artifact changed after publication, which should never happen.

**Prevention**
- Run `brew update` before installing; the tap and the release move together within minutes.

---

## Launch at login not working

**Symptoms**
- Settings ▸ General ▸ "Launch at login" is on, but after a reboot Backglance isn't running.

**Cause**
Backglance registers via `SMAppService.mainApp`. macOS may hold the registration at `.requiresApproval` — the user has to approve it in **System Settings ▸ General ▸ Login Items & Extensions** — and that approval can be silently reset when the app is moved, re-signed, or after some macOS updates. Managed Macs can also block login items by MDM policy.

**Fix**
1. Open System Settings ▸ General ▸ **Login Items & Extensions**. Under "Open at Login" / "Allow in the Background", find Backglance and enable it.
2. If it's not listed: toggle the setting off and on in Backglance's Settings ▸ General — that re-registers with `SMAppService` and repopulates the pane. Backglance surfaces the status it gets back (`.enabled`, `.requiresApproval`, `.notFound`) right under the toggle.
3. Still nothing after a reboot: `sfltool dumpbtm | grep -A4 -i backglance` shows what launchd's background task manager thinks; include that output in an issue.

**Prevention**
- Keep the app in `/Applications`; re-approve in Login Items after moving or rebuilding it.

---

## Decision tree: capture isn't working

Start at the top; each answer routes you to a scenario above.

```
"New notifications are not showing up in Backglance"
│
├─ Is the menu bar icon showing a PAUSE bar?
│   └─ YES → You (or a hotkey/URL) paused capture.
│            Click icon → Resume. Done.
│
├─ Is the icon showing a WARNING triangle?
│   ├─ Open Settings ▸ Status. What does "Capture" say?
│   │
│   ├─ "Degraded — No Full Disk Access"
│   │   └─ → Full Disk Access reset or broken (above).
│   │        Re-grant in System Settings, relaunch.
│   │
│   ├─ "Degraded — Unknown store schema"
│   │   └─ → Capture stopped after a macOS update (above).
│   │        Check for Updates; archive is safe; wait for hotfix.
│   │
│   ├─ "Degraded — Store not found"
│   │   └─ Rare: the system store file is missing at its
│   │      expected path. Reboot first (usernoted recreates it).
│   │      Persists after reboot → file an issue with diagnostics.
│   │
│   └─ "Degraded — Read error"
│       └─ Transient I/O problem reading the store snapshot.
│          Check free disk space (snapshots need a little room).
│          Persists → diagnostics export + issue.
│
├─ Icon looks NORMAL, but nothing new arrives?
│   ├─ Do notifications from that app reach Notification
│   │  Center at all? (Check the system's own panel.)
│   │   ├─ NO → macOS isn't delivering them. Check the app's
│   │   │       notification permission and Focus modes.
│   │   │       Backglance can only archive what macOS delivers.
│   │   └─ YES ↓
│   ├─ Is the app on your exclusion list?
│   │   └─ Settings ▸ Privacy ▸ Excluded apps. Excluded apps
│   │      (password managers by default) are never stored.
│   ├─ Is a search or filter active in the timeline?
│   │   └─ Clear it — new rows may be filtered from view.
│   └─ Wait one poll interval (15 s default; 60 s in Low
│      Power Mode). Still nothing → next branch.
│
└─ None of the above?
    └─ Run:  log stream --predicate
         'subsystem == "app.backglance.Backglance" AND
          (category == "capture" OR category == "adapter")'
          --level debug
       Trigger a test notification, watch for a batch line.
       Whatever appears (or doesn't) goes in your bug report ↓
```

---

## Collecting information for a bug report

File issues at https://github.com/backglance/backglance/issues. A useful report contains, in this order:

1. **Versions.** Backglance version and build (Settings ▸ About, or `defaults read /Applications/Backglance.app/Contents/Info.plist CFBundleShortVersionString`), exact macOS version (` ▸ About This Mac`), Apple silicon or Intel.
2. **The diagnostics export.** Settings ▸ Advanced ▸ **Export Diagnostics…**. This zip is designed for exactly this purpose: it contains the adapter ID, store fingerprint, capture status history, per-app *counts* (anonymous unless you opt in), archive statistics, the last 500 content-free log lines, and a settings snapshot — and it provably contains **no notification content** (see [`./MONITORING_LOGGING.md`](./MONITORING_LOGGING.md#diagnostics-export) for the full contents table, the exclusion guarantees, and how to review the zip yourself before attaching).
3. **What you saw vs. expected**, with the scenario name from this page if one matched.
4. **Timestamps** of when the problem occurred, so the capture status history lines up.
5. If asked for more, targeted log output — commands are in [`./MONITORING_LOGGING.md`](./MONITORING_LOGGING.md#viewing-logs). Paste log lines rather than screenshots.
6. For crashes only: the newest matching file from `~/Library/Logs/DiagnosticReports/` — Backglance has no crash reporter, so this manual attachment is the only way a crash reaches the developer. Read it before attaching (it contains stack traces and loaded-library paths, not notification content).

> ✅ **Do:** review everything before attaching. The export is built to be content-free and is tested for it, but it's your data and your call — every file in the zip is short, human-readable JSON or text.

> ❌ **Don't:** paste notification text, screenshots of your timeline, or your archive file into an issue. Nobody needs them to fix a bug, and issues are public forever.

## Related Documentation

- [`./MONITORING_LOGGING.md`](./MONITORING_LOGGING.md)
- [`./MAINTENANCE.md`](./MAINTENANCE.md)
- [`../features/PERMISSIONS_PRIVACY.md`](../features/PERMISSIONS_PRIVACY.md)
- [`../features/PRIVACY_CONTROLS.md`](../features/PRIVACY_CONTROLS.md)
- [`../features/CAPTURE.md`](../features/CAPTURE.md)
- [`../features/MISSED_DIGEST.md`](../features/MISSED_DIGEST.md)
- [`../features/CLOUDKIT_SYNC.md`](../features/CLOUDKIT_SYNC.md)
- [`../architecture/OS_COMPATIBILITY_PLAYBOOK.md`](../architecture/OS_COMPATIBILITY_PLAYBOOK.md)
- [`../architecture/DATABASE_SCHEMA.md`](../architecture/DATABASE_SCHEMA.md)
- [`../deployment/PERFORMANCE_GUIDE.md`](../deployment/PERFORMANCE_GUIDE.md)
- [`../getting-started/SETUP_GUIDE.md`](../getting-started/SETUP_GUIDE.md)
- [`../reference/FAQ.md`](../reference/FAQ.md)
- [`../../README.md`](../../README.md)
