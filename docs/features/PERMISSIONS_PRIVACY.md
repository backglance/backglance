# Permissions & Privacy

Last Updated: 2026-08-18

This document explains every permission Backglance asks for, why it needs it, what it reads on disk (precisely), what it never touches, how a user can verify that, and how the app behaves when a permission is missing. It also specifies the first-run onboarding flow that walks a user through granting Full Disk Access (FDA), including the exact user-facing wording. Backglance is a native macOS menu bar utility that keeps a local, searchable archive of every notification; the only permission it *needs* is FDA, and the reason is a single directory that macOS protects.

## Table of Contents

- [Feature Overview](#feature-overview)
- [Permission Matrix](#permission-matrix)
- [Why Full Disk Access Is Required](#why-full-disk-access-is-required)
- [Architecture](#architecture)
- [What Backglance Reads and What It Never Touches](#what-backglance-reads-and-what-it-never-touches)
- [How to Verify Our Claims](#how-to-verify-our-claims)
- [Granting Full Disk Access](#granting-full-disk-access)
- [Runtime Detection: FullDiskAccessProbe](#runtime-detection-fulldiskaccessprobe)
- [Degraded Mode Without FDA](#degraded-mode-without-fda)
- [Onboarding Flow](#onboarding-flow)
- [Other Permissions](#other-permissions)
- [Archive Tables Involved](#archive-tables-involved)
- [UI Components](#ui-components)
- [Business Logic](#business-logic)
- [Edge Cases and Error Handling](#edge-cases-and-error-handling)
- [Testing Approach](#testing-approach)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Feature Overview

Backglance reads Apple's Notification Center database (the **system store**) to archive notifications. That store lives inside a group container that macOS's TCC (Transparency, Consent, and Control) subsystem protects. Without Full Disk Access the file is not readable — not by a sandboxed app, not by an unsandboxed app, not by a shell script running as the user. There is no narrower entitlement, no "Notifications history" privacy category, and no public API that exposes delivered-notification history to third-party apps. FDA is the only door, so it is the only permission Backglance requires.

Everything else is optional or not needed:

- Backglance's *own* local notifications (digest banner, snooze reminders) use `UNUserNotificationCenter` and require the normal Notifications permission — optional.
- Launch at login uses `SMAppService.mainApp` — optional, approved in System Settings ▸ General ▸ Login Items.
- **Accessibility is not needed.** Backglance does not observe other apps' UI, does not synthesize input, and does not read the screen. The global hotkey (⌃⌥N) uses Carbon `RegisterEventHotKey`, which does not require Accessibility.
- No Screen Recording, no Input Monitoring, no Contacts, no Calendar (unless the user opts into the v1.x Reminders export), no Location, no Camera/Microphone.

> 🔒 **Security:** Full Disk Access is a broad grant. Backglance treats that as a responsibility, not a licence. The whole app is GPL-3.0 open source, the file paths it opens are enumerated below, and the only network access in the binary is the Sparkle updater, which can be turned off. This is also why Backglance is not on the Mac App Store: FDA is incompatible with App Sandbox, and there is no sandbox-compatible way to read the store.

## Permission Matrix

| Permission | Needed for | Required? | Where the user grants it | Failure mode |
|---|---|---|---|---|
| Full Disk Access | Reading the system store (`usernoted` db) and Focus assertions | **Yes** (core capture) | System Settings ▸ Privacy & Security ▸ Full Disk Access | Capture status `.degraded(.noFullDiskAccess)`; browsing/search of existing archive still works |
| Notifications (own) | Digest banner, snooze reminders, "capture paused" reminder | No | System prompt via `UNUserNotificationCenter`, or System Settings ▸ Notifications ▸ Backglance | Digest opens the popover instead of posting a banner |
| Login Items | Launch at login | No | System Settings ▸ General ▸ Login Items (approval), toggled from Backglance Settings | User starts Backglance manually |
| Accessibility | — | **No** | — | — |
| Screen Recording | — | **No** | — | — |
| Reminders (EventKit) | v1.x optional export of snoozes to Reminders | No (v1.x, opt-in) | System prompt | Snooze stays local |

## Why Full Disk Access Is Required

The system store path is:

```
~/Library/Group Containers/group.com.apple.usernoted/db2/db      (SQLite, WAL mode)
~/Library/Group Containers/group.com.apple.usernoted/db2/db-wal
~/Library/Group Containers/group.com.apple.usernoted/db2/db-shm
```

Three facts, stated plainly:

1. **TCC protects it.** Since macOS Mojave, `~/Library/Group Containers/` (along with Mail, Messages, Safari, Time Machine backups, and several other locations) is under TCC's `SystemPolicyAllFiles` class. Reading it requires the *process* to be granted Full Disk Access. POSIX file permissions look fine (`0700` on the directory, owned by the user), but `open(2)` returns `EPERM` (errno 1, "Operation not permitted") for a process without FDA.
2. **Not sandboxed does not help.** Backglance is not sandboxed, and that is necessary for other reasons, but it is not sufficient. TCC applies to every process regardless of sandbox status. `cat "$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"` from Terminal.app fails the same way unless Terminal has FDA.
3. **There is no narrower door.** Apple provides no entitlement, no privacy category, and no public framework (`UserNotifications`, `NotificationCenter`, private or otherwise that we would be willing to ship against) that returns the history of notifications delivered *to other apps*. `UNUserNotificationCenter.getDeliveredNotifications` returns only your own app's notifications. The store is the only source, and FDA is the only way to read it.

> ⚠️ **Warning:** The store is an undocumented system database. Its path, tables and columns are what we have observed, not an API. Column names may change in any macOS release; the fingerprint + adapter + fixture strategy described in [CAPTURE.md](./CAPTURE.md) and [../architecture/OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md) exists for that reason. FDA is required for the *path*; the *contents* are a separate fragility.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│ App launch / activation / onboarding visible                            │
└───────────────┬──────────────────────────────────────────────────────────┘
                │
                ▼
      ┌────────────────────┐    open(2) O_RDONLY on store path
      │ FullDiskAccessProbe│──────────────────────────────────────┐
      └─────────┬──────────┘                                      │
                │ .granted / .denied / .storeMissing               ▼
                │                                    ~/Library/Group Containers/
                ▼                                     group.com.apple.usernoted/db2/db
      ┌────────────────────┐
      │ PermissionsModel   │  @MainActor @Observable
      │  fdaState          │◄──── polls every 30 s while onboarding visible
      │  notifAuthState    │◄──── NSApplication.didBecomeActiveNotification
      │  loginItemState    │
      └───┬──────────┬─────┘
          │          │
          ▼          ▼
  ┌──────────────┐  ┌──────────────────┐   .degraded(.noFullDiskAccess)
  │ OnboardingView│  │ CaptureEngine    │──────────────────────────────┐
  │ (5 screens)   │  │ (BackglanceCapture)                             │
  └──────────────┘  └──────────────────┘                              ▼
                                                    ┌──────────────────────────┐
                                                    │ StatusItemController     │ icon: "eye.slash" variant
                                                    │ MenuBarPopoverView       │ persistent FDA banner
                                                    │ Settings ▸ Permissions   │ re-entry point
                                                    └──────────────────────────┘
```

Responsibilities:

| Component | Module | Role |
|---|---|---|
| `FullDiskAccessProbe` | `BackglanceCapture` | Pure function: attempt to open the store read-only, classify the result |
| `PermissionsModel` | `Backglance` app target (`Scenes/Onboarding/`) | Observable state for FDA, notifications, login item; owns the polling timer |
| `OnboardingView` + `OnboardingStep` | `Backglance` (`Scenes/Onboarding/`) | Five-screen state machine, "Skip for now", "Grant" that opens the pane and waits |
| `CaptureEngine` | `BackglanceCapture` | Consumes probe result on `start()`; publishes `.degraded(.noFullDiskAccess)` |
| `FDABanner` | `BackglanceUI` | Persistent, non-nagging banner used in popover and window |
| `Settings ▸ Permissions` | `Backglance` (`Scenes/Settings/`) | Re-entry to onboarding, `tccutil` hint, "Open Full Disk Access settings" |

## What Backglance Reads and What It Never Touches

### Reads (complete list)

| Path | Why | Mode |
|---|---|---|
| `~/Library/Group Containers/group.com.apple.usernoted/db2/db` | The system store | Read-only, and only via a snapshot copy (see below) |
| `~/Library/Group Containers/group.com.apple.usernoted/db2/db-wal` | WAL pages not yet checkpointed into `db` | Read-only, copied with the db |
| `~/Library/Group Containers/group.com.apple.usernoted/db2/db-shm` | Shared-memory index for the WAL | Read-only, copied with the db |
| `~/Library/DoNotDisturb/DB/Assertions.json` | Focus detection for away sessions | Read-only (⚠️ undocumented) |
| `~/Library/DoNotDisturb/DB/ModeConfigurations.json` | Focus mode names for the digest header | Read-only (⚠️ undocumented) |
| `/Applications/**` and other app bundles via `NSWorkspace.urlForApplication(withBundleIdentifier:)` | App icons and display names for enrichment | Read-only, standard API, no FDA involved |

That is the whole list of paths outside Backglance's own directories. Backglance additionally reads and writes its own files under `~/Library/Application Support/Backglance/` (archive, icon cache, tmp snapshots), `~/Library/Logs/Backglance/`, and its `UserDefaults` suite `app.backglance.Backglance`.

The store is never opened live. `StoreSnapshot` copies `db` and `db-wal` (never `db-shm`) into `~/Library/Application Support/Backglance/tmp/<uuid>/`, opens the copy read-only, reads new records, and deletes the copy. Apple's file is opened with `O_RDONLY` for the copy and never for write. See [CAPTURE.md](./CAPTURE.md) for the code.

### Never touches

Even with FDA granted, Backglance does **not** open:

- Mail's databases (`~/Library/Mail/`)
- Messages' database (`~/Library/Messages/chat.db`) — notification *text* from Messages arrives through the store, and OTP codes in it are redacted before insert; the Messages database itself is never read
- Safari history, bookmarks, or cookies (`~/Library/Safari/`)
- Photos libraries
- `~/Documents`, `~/Desktop`, `~/Downloads` (except the v1.x export writing *to* `~/Downloads` after explicit confirmation)
- The keychain (Backglance stores no secrets in v1.0; the v1.x SQLCipher key would be a single Backglance-owned item)
- Any other app's container under `~/Library/Containers/` or `~/Library/Group Containers/`
- Time Machine backups, Trash, or other users' home directories

> ✅ **Do:** If you audit the code, start with `Packages/BackglanceCapture/Sources/BackglanceCapture/StoreLocation.swift` and grep for `FileManager` and `open(` across `Packages/`. Every path is constructed from `StoreLocation.current()` or from Backglance's own support directory.

## How to Verify Our Claims

Backglance is designed so a user does not have to trust the README:

1. **Read the code.** Single repo, GPL-3.0: `https://github.com/backglance/backglance`. The capture path is small and lives in `Packages/BackglanceCapture/`.
2. **Watch file access live.** Both tools below need `sudo`; the app's process name is `Backglance`.

   ```bash
   # Show every file Backglance opens, live (Ctrl-C to stop)
   sudo fs_usage -w -f filesys Backglance

   # Alternative: DTrace-based opensnoop (requires SIP allowing dtrace, or a dev machine)
   sudo opensnoop -n Backglance
   ```

   You should see the store path (`.../group.com.apple.usernoted/db2/db*`), Backglance's own support directory, the two Focus JSON files, and app bundles for icons. Nothing else.
3. **Watch the network.** With Little Snitch, LuLu, or `nettop -p $(pgrep -x Backglance)`, the only connection ever made is to the Sparkle appcast host (`backglance.github.io`, later `backglance.app`) when checking for updates. Disable automatic update checks in Settings ▸ Updates and there is no network access at all. There is no telemetry, no crash-reporting service, no analytics endpoint.
4. **Verify the binary.** The official release is Developer ID signed and notarized:

   ```bash
   codesign -dv --verbose=4 /Applications/Backglance.app 2>&1 | grep -E 'Identifier|TeamIdentifier|Authority'
   spctl -a -vv /Applications/Backglance.app
   ```

   Expect `Identifier=app.backglance.Backglance` and `Authority=Developer ID Application: Backglance (TEAMID1234)`. Or build from source and skip trusting the binary entirely — [../getting-started/SETUP_GUIDE.md](../getting-started/SETUP_GUIDE.md).

## Granting Full Disk Access

### System Settings path

**System Settings ▸ Privacy & Security ▸ Full Disk Access**, then enable the toggle next to **Backglance**. On macOS 14, 15 and 26 this pane is a list of apps with toggles; if Backglance is not listed, click **+** and pick `/Applications/Backglance.app`, or drag the app into the list. macOS asks you to quit and reopen the app after granting; Backglance detects the change without a relaunch in most cases, but relaunching is the safe path and the onboarding screen offers a **Relaunch** button.

### Deep link

Backglance opens the pane directly with:

```
x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles
```

```swift
import AppKit

enum SystemSettingsLinks {
    static let fullDiskAccess = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static let notifications  = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
    static let loginItems     = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    /// Opens the Full Disk Access pane. Returns false if the URL could not be opened
    /// (very old or very locked-down systems); callers then show the manual path.
    @discardableResult
    static func openFullDiskAccess() -> Bool {
        NSWorkspace.shared.open(fullDiskAccess)
    }
}
```

> ℹ️ **Info:** There is no API to *request* Full Disk Access. Unlike Notifications, Camera or Accessibility, TCC has no prompt for `SystemPolicyAllFiles`. An app can only detect the state and guide the user to the pane. Anything that looks like an "Allow" button inside Backglance is a button that opens System Settings.

### Resetting the grant (for testing or troubleshooting)

```bash
# Forget Backglance's FDA decision. Run in Terminal; no sudo needed for your own user.
tccutil reset SystemPolicyAllFiles app.backglance.Backglance

# Nuclear option: forget ALL apps' FDA decisions (you will re-grant everything).
tccutil reset SystemPolicyAllFiles
```

After a reset, Backglance's next probe returns `.denied` and the onboarding re-entry banner appears. `Scripts/grant_fda_hint.sh` in the repo prints these commands and the deep link for developers who bounce between debug and release builds (each build with a different signature is a different TCC identity — see [Edge Cases](#edge-cases-and-error-handling)).

## Runtime Detection: FullDiskAccessProbe

Detection is an attempt to open the store read-only. `FileManager.isReadableFile(atPath:)` is *not* reliable for TCC-protected paths (it can return `true` because it consults `access(2)`, which reflects POSIX permissions, not TCC), so the probe uses `open(2)` and inspects `errno`.

```swift
import Foundation
import Darwin

/// Result of probing whether this process can read the system store.
public enum FullDiskAccessState: Equatable, Sendable {
    /// The store file opened read-only. FDA is granted (or the file is somehow world-readable).
    case granted
    /// open(2) failed with EPERM/EACCES: TCC is blocking us. FDA is not granted.
    case denied
    /// The store path does not exist. Either macOS layout changed or Notification Center has
    /// never run for this user. This is NOT a permission problem.
    case storeMissing
}

public struct FullDiskAccessProbe: Sendable {
    public init() {}

    /// Synchronous, cheap (one open/close). Safe to call from any thread.
    public func probe(storeURL: URL? = nil) -> FullDiskAccessState {
        let url: URL
        do {
            url = try storeURL ?? StoreLocation.current()
        } catch {
            return .storeMissing
        }
        // Use the parent directory as a second signal: if we can't even list the
        // container directory, TCC is denying us regardless of the file's existence.
        let path = url.path
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        if fd >= 0 {
            close(fd)
            return .granted
        }
        switch errno {
        case EPERM, EACCES:
            return .denied
        case ENOENT:
            // File missing. Distinguish "no FDA, so we cannot even see it" from "truly absent"
            // by attempting the directory. Without FDA, opendir on the group container also fails EPERM.
            let dirFD = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
            if dirFD >= 0 {
                close(dirFD)
                return .storeMissing
            }
            return errno == EPERM || errno == EACCES ? .denied : .storeMissing
        default:
            // EBUSY/EINTR/etc. — treat as denied for UI purposes; the capture engine will retry.
            return .denied
        }
    }
}
```

Usage with both outcomes handled:

```swift
let probe = FullDiskAccessProbe()
switch probe.probe() {
case .granted:
    await captureEngine.start()                       // normal path
case .denied:
    await captureEngine.markDegraded(.noFullDiskAccess)
    permissionsModel.fdaState = .denied               // drives banner + onboarding
case .storeMissing:
    await captureEngine.markDegraded(.storeNotFound)  // different message, no FDA nag
}
```

The probe is invoked:

- on app launch, before `CaptureEngine.start()`;
- on `NSApplication.didBecomeActiveNotification` (user came back from System Settings);
- every 30 seconds while any onboarding screen is visible;
- when the user clicks **Check again** in the banner or Settings;
- from `StoreWatcher` when a read fails with `EPERM` mid-run (FDA revoked → degrade).

## Degraded Mode Without FDA

Backglance is fully usable without FDA except for capture:

| Area | Without FDA |
|---|---|
| Timeline / browsing existing archive | Works |
| Search (FTS, fuzzy, semantic) | Works |
| Rules, retention, export, panic wipe | Work |
| Settings | Work |
| Live capture | Off — `CaptureStatus.degraded(.noFullDiskAccess)` |
| Late import on first launch | Off until FDA is granted; runs automatically the first time the probe flips to `.granted` |
| Digest | Only from notifications already archived; away sessions still tracked |
| Menu bar icon | Degraded variant (`bell.slash` glyph, template image); tooltip "Backglance — Full Disk Access needed" |
| Banner | One persistent banner at the top of the popover and window: no modal, no repeated toasts, no badge on the status item |

Banner wording (exact):

> **Full Disk Access needed to capture new notifications.**
> Your existing archive still works. Backglance can only guide you to the setting — macOS has no prompt for this permission.
> [Open System Settings] [Check again] [Learn why]

The banner is dismissible per session with the small × (it comes back on next launch — that is deliberate, since capture is silently off). "Learn why" opens onboarding screen 2 in a sheet.

> ❌ **Don't:** Never re-prompt with a modal, never post a local notification about FDA, never bounce the Dock icon (there is no Dock icon — `LSUIElement = YES`), never gate unrelated features behind FDA to pressure the user.

## Onboarding Flow

Onboarding runs on first launch (`UserDefaults` key `onboarding.completedVersion` unset) and can be re-entered from Settings ▸ Permissions ▸ **Show setup again**. It is a single `NSWindow` (`level: .floating`, non-resizable, 640 × 480 pt) hosting `OnboardingView`. Screenshots live in `Backglance/Resources/Onboarding/` (`onboarding-fda-pane@2x.png`, `onboarding-fda-toggle@2x.png`, `onboarding-menubar@2x.png`).

### Screens and copy

**Screen 1 — Welcome**

> **Backglance**
> The notification history macOS never had.
>
> macOS deletes notifications the moment you dismiss them. Backglance keeps a private, local archive so you can search what you missed — nothing leaves your Mac.
>
> Setup takes about a minute and needs one permission.
>
> [Continue] · Skip for now

`[screenshot: onboarding-menubar@2x.png — the menu bar popover with a few placeholder notifications]`

**Screen 2 — Why Full Disk Access**

> **One permission: Full Disk Access**
>
> Notification history lives in a system database that macOS protects. There is no narrower permission and no API for it — Full Disk Access is the only way any app can read it. This is also why Backglance is not in the Mac App Store.
>
> Backglance is open source (GPL-3.0). You can read exactly what it opens, and watch it with `fs_usage` if you like.
>
> [Continue] · Back · Skip for now

**Screen 3 — What we read, and never read**

> **What Backglance reads**
> • The Notification Center database (`~/Library/Group Containers/group.com.apple.usernoted/db2/db`, plus its `-wal` and `-shm` files) — copied read-only, never modified.
> • Two Focus files (`~/Library/DoNotDisturb/DB/Assertions.json`, `ModeConfigurations.json`) — to know when you were in a Focus.
> • App icons, via the standard `NSWorkspace` API.
>
> **What Backglance never reads**
> Mail, Messages, Safari, Photos, Documents, the keychain, or any other app's data. It makes no network connections except checking for updates, which you can turn off.
>
> [Continue] · Back · Skip for now

**Screen 4 — Grant**

> **Grant Full Disk Access**
>
> 1. Click **Open System Settings** below.
> 2. Turn on the switch next to **Backglance**. If it isn't listed, click **+** and choose Backglance from Applications.
> 3. Come back here — this screen updates by itself.
>
> `[screenshot: onboarding-fda-pane@2x.png — Privacy & Security ▸ Full Disk Access list with Backglance toggle highlighted]`
>
> Status: ○ Waiting for permission…  (→ ● Granted, thanks!)
>
> [Open System Settings] · Check again · Back · Skip for now
>
> Backglance can't request this permission for you; macOS only lets apps point you to the setting.

When the probe returns `.granted`, the status line switches to "● Granted, thanks!", the primary button becomes **Continue**, and the view auto-advances after 1.5 s (user can click earlier). If macOS insists on a relaunch (probe still `.denied` 10 s after the pane was opened, but the user reports toggling), a secondary **Relaunch Backglance** button appears with the copy "macOS sometimes needs the app to restart after granting. Your setup progress is saved."

**Screen 5 — Done + first import**

> **You're set.**
>
> Backglance is importing what macOS still has — usually the last few days, since the system prunes older notifications. From now on every notification is archived as it arrives.
>
> Imported 143 notifications from 12 apps.  ← live count
> This is everything the system still had.
>
> Backglance lives in your menu bar (⌃⌥N opens it). Optional: [Launch at login] [Allow Backglance to notify you about missed notifications]
>
> [Open Backglance]

Screen 5 triggers `CaptureEngine.importExisting()` and shows progress (`ProgressView` with the running count). Both optional toggles are off by default; the second one triggers the `UNUserNotificationCenter` request only when toggled.

### "Skip for now" path

Every screen has "Skip for now". Skipping sets `onboarding.completedVersion` to the current onboarding version, sets `onboarding.skippedFDA = true`, closes the window, and leaves the app in degraded mode with the persistent banner. There is no follow-up reminder besides the banner. Re-entry: click the banner's **Open System Settings** / **Learn why**, or Settings ▸ Permissions ▸ **Show setup again** (starts at screen 2 if FDA is still missing, screen 5 if it is granted but import never ran).

### After macOS updates

FDA grants normally persist across macOS updates (they are keyed by the app's code signature and bundle identifier). Two things can still change:

- A major update may reset TCC decisions for some apps. Backglance re-probes on every launch and every activation, so the banner appears if the grant is gone; nothing else changes.
- A major update may change the store schema. That is a different degraded reason (`.unknownSchema(fingerprint)`) with a different message ("Backglance doesn't recognise this macOS version's notification database yet") — see [CAPTURE.md](./CAPTURE.md).

> 💡 **Tip:** After a macOS upgrade, open the popover once. If the banner is not there and the icon is not the degraded variant, capture is running.

### `OnboardingView` state machine

```swift
import SwiftUI
import BackglanceCapture

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome = 1, whyFDA, whatWeRead, grant, done
    var id: Int { rawValue }
}

@MainActor
@Observable
final class OnboardingModel {
    var step: OnboardingStep = .welcome
    var fdaState: FullDiskAccessState = .denied
    var importedCount: Int = 0
    var importFinished = false
    var showRelaunchHint = false

    private let probe = FullDiskAccessProbe()
    private var pollTask: Task<Void, Never>?
    private var paneOpenedAt: Date?
    private let capture: CaptureEngine
    private let defaults: UserDefaults

    init(capture: CaptureEngine, defaults: UserDefaults = UserDefaults(suiteName: "app.backglance.Backglance")!) {
        self.capture = capture
        self.defaults = defaults
        // Resume where the user left off; skip straight to Grant if FDA is the only thing missing.
        fdaState = probe.probe()
        if defaults.bool(forKey: "onboarding.skippedFDA"), fdaState != .granted {
            step = .whyFDA
        }
    }

    // MARK: Navigation

    func next() {
        switch step {
        case .welcome:    step = .whyFDA
        case .whyFDA:     step = .whatWeRead
        case .whatWeRead: step = .grant
        case .grant:      guard fdaState == .granted else { return }; step = .done; startImport()
        case .done:       finish(skipped: false)
        }
    }

    func back() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    func skip() { finish(skipped: true) }

    // MARK: FDA

    func openSettingsPane() {
        paneOpenedAt = Date()
        if !SystemSettingsLinks.openFullDiskAccess() {
            // Deep link failed: still poll; the screen shows the manual path text.
            showRelaunchHint = false
        }
    }

    func checkAgain() { refreshFDA() }

    /// Called by the view's .onAppear / .onDisappear so polling only runs while onboarding is visible.
    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshFDA()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stopPolling() { pollTask?.cancel(); pollTask = nil }

    private func refreshFDA() {
        let previous = fdaState
        fdaState = probe.probe()
        if fdaState == .granted, previous != .granted, step == .grant {
            // Auto-advance after a short confirmation beat.
            Task { try? await Task.sleep(for: .seconds(1.5)); if self.step == .grant { self.next() } }
        }
        if fdaState != .granted, let opened = paneOpenedAt, Date().timeIntervalSince(opened) > 10 {
            showRelaunchHint = true
        }
    }

    // MARK: Import (screen 5)

    private func startImport() {
        Task {
            do {
                for try await progress in await capture.importExisting() {
                    importedCount = progress.imported
                }
                importFinished = true
            } catch {
                // Import failure is not fatal for onboarding; the timeline shows the archive banner.
                importFinished = true
            }
        }
    }

    private func finish(skipped: Bool) {
        defaults.set(OnboardingVersion.current, forKey: "onboarding.completedVersion")
        defaults.set(skipped && fdaState != .granted, forKey: "onboarding.skippedFDA")
        stopPolling()
        NSApp.sendAction(#selector(AppDelegate.closeOnboarding(_:)), to: nil, from: nil)
    }
}

enum OnboardingVersion { static let current = 1 }
```

```swift
struct OnboardingView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .welcome:    WelcomeStep()
                case .whyFDA:     WhyFDAStep()
                case .whatWeRead: WhatWeReadStep()
                case .grant:      GrantStep(model: model)
                case .done:       DoneStep(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            Divider()
            footer
        }
        .frame(width: 640, height: 480)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
        // Re-probe the instant the user comes back from System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.checkAgain()
        }
    }

    private var footer: some View {
        HStack {
            if model.step != .welcome && model.step != .done {
                Button("Back") { model.back() }
            }
            Spacer()
            if model.step != .done {
                Button("Skip for now") { model.skip() }
                    .buttonStyle(.link)
                    .accessibilityHint("Closes setup. You can grant Full Disk Access later from Settings.")
            }
            Button(model.step == .done ? "Open Backglance" : "Continue") { model.next() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.step == .grant && model.fdaState != .granted)
        }
        .padding()
    }
}

struct GrantStep: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Grant Full Disk Access").font(.title2.bold())
            Text("1. Click **Open System Settings** below.\n2. Turn on the switch next to **Backglance**. If it isn't listed, click **+** and choose Backglance from Applications.\n3. Come back here — this screen updates by itself.")
            Image("onboarding-fda-pane").resizable().scaledToFit().frame(maxHeight: 180)
                .accessibilityLabel("Screenshot of System Settings, Privacy & Security, Full Disk Access, with the Backglance toggle highlighted")
            HStack(spacing: 8) {
                switch model.fdaState {
                case .granted:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Granted, thanks!")
                case .denied:
                    ProgressView().controlSize(.small)
                    Text("Waiting for permission…")
                case .storeMissing:
                    Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                    Text("Permission looks fine, but the notification database wasn't found. Capture will start when it appears.")
                }
            }
            .font(.callout)
            HStack {
                Button("Open System Settings") { model.openSettingsPane() }
                Button("Check again") { model.checkAgain() }
                if model.showRelaunchHint {
                    Button("Relaunch Backglance") { AppRelauncher.relaunch() }
                }
            }
            if model.showRelaunchHint {
                Text("macOS sometimes needs the app to restart after granting. Your setup progress is saved.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("Backglance can't request this permission for you; macOS only lets apps point you to the setting.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
    }
}
```

`AppRelauncher.relaunch()` spawns `/usr/bin/open -n <bundle path>` after a 0.5 s delay via `Process`, then calls `NSApp.terminate(nil)`. Onboarding progress survives because `step` is derived from `UserDefaults` and the probe on the next launch.

## Other Permissions

### Notifications (Backglance's own local notifications)

Used for: the digest banner ("You missed 7 notifications while away"), snooze reminders (v1.x), and an optional "capture is paused" reminder. Requested lazily — the first time the user enables a feature that needs it, never at launch.

```swift
import UserNotifications

enum LocalNotificationAuthorizer {
    /// Requests banner + sound. Returns the resulting authorization state.
    /// Never throws to the caller for "denied": denial is a normal, respected outcome.
    static func requestIfNeeded() async -> UNAuthorizationStatus {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return settings.authorizationStatus
        case .denied:
            return .denied                       // do not re-request; Settings shows a "Open Notifications settings" link
        case .notDetermined, .ephemeral:
            break
        @unknown default:
            break
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            return granted ? .authorized : .denied
        } catch {
            // e.g. UNErrorDomain notificationsNotAllowed on managed Macs. Fall back gracefully.
            Log.permissions.error("UNUserNotificationCenter request failed: \(error.localizedDescription, privacy: .public)")
            return .denied
        }
    }
}
```

If denied, the digest still works: instead of posting a banner, Backglance sets the status item badge and opens the digest in the popover the next time it is shown. Nothing nags.

### Login Items

`SMAppService.mainApp.register()` / `.unregister()`. On macOS 14+ the first registration triggers the system's "Backglance was added as a login item" notification and the toggle appears in System Settings ▸ General ▸ Login Items. If the status comes back `.requiresApproval`, Settings shows "Approve in System Settings" with a link. See `Backglance/App/LaunchAtLogin.swift`.

### Accessibility — not needed

Stated once more because users assume menu bar utilities need it: Backglance does not use `AXUIElement`, does not post `CGEvent`s, and does not read window contents. If a future feature ever needed Accessibility it would be opt-in and documented here first.

## Archive Tables Involved

Permissions do not have their own table. Related state:

| Table / store | Keys | Purpose |
|---|---|---|
| `UserDefaults` suite `app.backglance.Backglance` | `onboarding.completedVersion`, `onboarding.skippedFDA`, `notifications.digestBannerEnabled`, `launchAtLogin.enabled` | Onboarding progress and optional-permission preferences |
| `capture_state` | `last_import_at` | Whether the first import (screen 5) has run; drives "run import when FDA appears later" |
| `capture_state` | `adapter_id`, `fingerprint` | Written by capture once FDA allows a probe |

## UI Components

| Component | Location | Notes |
|---|---|---|
| `OnboardingWindowController` | `Backglance/Scenes/Onboarding/` | AppKit window hosting `OnboardingView`; floating, centred |
| `OnboardingView`, `WelcomeStep`, `WhyFDAStep`, `WhatWeReadStep`, `GrantStep`, `DoneStep` | `Backglance/Scenes/Onboarding/` | SwiftUI |
| `FDABanner` | `Packages/BackglanceUI` | Reused by popover and full window; VoiceOver label "Full Disk Access needed. Capture is off." |
| `PermissionsSettingsView` | `Backglance/Scenes/Settings/` | Status rows for FDA / Notifications / Login Items, "Show setup again", "Open Full Disk Access settings", `tccutil` hint in a disclosure |
| Status item degraded icon | `Backglance/App/StatusItemController.swift` | Template image swap; tooltip |

## Business Logic

- Probe result → `CaptureEngine` status is the single source of truth. UI derives from `CaptureStatus`, not from its own probe calls, so banner and icon can never disagree with capture.
- Polling cadence: 30 s only while onboarding is visible; otherwise event-driven (activation, watcher EPERM). Idle CPU budget (< 0.1 %) forbids continuous polling.
- First import runs exactly once per archive: guarded by `capture_state.last_import_at`. If FDA is granted days later, the import runs at that moment and the popover shows a one-line "Imported N notifications the system still had."
- Notifications permission is requested only from an explicit user action; digest defaults to in-popover presentation.

## Edge Cases and Error Handling

| Case | Behaviour |
|---|---|
| Debug build vs release build | Different signatures ⇒ different TCC identities. Developers grant FDA to the Xcode-built app separately; `Scripts/grant_fda_hint.sh` prints the reset commands. Documented in [../getting-started/DEVELOPMENT_GUIDE.md](../getting-started/DEVELOPMENT_GUIDE.md) |
| App moved/renamed after granting | TCC keys on signature + bundle id, so moving `/Applications/Backglance.app` is fine; a re-signed binary (Homebrew upgrade of the same signed release is fine, a self-built one is not) needs re-granting |
| User grants FDA but probe still `.denied` | macOS occasionally requires relaunch; after 10 s the Relaunch button appears |
| FDA revoked while running | `StoreWatcher` read hits `EPERM` → `CaptureEngine` → `.degraded(.noFullDiskAccess)`; icon + banner update; no data loss in the archive; on re-grant, capture resumes from the persisted cursor and picks up whatever the store still has |
| Store path missing with FDA granted | `.storeMissing` → `.degraded(.storeNotFound)`; message does not mention permissions; watcher keeps polling the parent directory every 60 s |
| Managed Mac (MDM PPPC profile) | If the profile *grants* `SystemPolicyAllFiles` for `app.backglance.Backglance`, the probe returns `.granted` with no user action; if the profile *denies*, the pane toggle is greyed out — Settings copy adds "This may be managed by your organisation." when the deep link opens but the state does not change after 60 s |
| Deep link fails to open | Show the manual path text in place of the button |
| Onboarding window closed via ⌘W mid-flow | Treated as "Skip for now" |
| Notifications permission denied | Digest opens in popover; no re-request |
| `UNUserNotificationCenter` unavailable (rare, e.g. running from a non-bundle path) | Caught, logged, treated as denied |

Errors are typed where they cross module boundaries:

```swift
public enum PermissionError: Error, Equatable {
    case fullDiskAccessDenied
    case storeMissing
    case notificationsDenied
    case loginItemRequiresApproval
    case settingsPaneUnavailable
}
```

Log lines never include paths beyond the store's fixed path and never include notification content:

```swift
Log.permissions.notice("FDA probe: \(String(describing: state), privacy: .public)")
```

## Testing Approach

- **Unit (`BackglanceCaptureTests`)** — `FullDiskAccessProbeTests`: probe against a temp file (expect `.granted`), a `chmod 000` file (expect `.denied` — POSIX EACCES exercises the same branch), a non-existent path with existing parent (expect `.storeMissing`), a non-existent path with non-existent parent (expect `.storeMissing`).
- **Unit (`OnboardingModelTests`)** — state machine transitions; `next()` on `.grant` is a no-op while `.denied`; auto-advance after `.granted`; `skip()` writes `onboarding.skippedFDA`; re-entry starts at `.whyFDA`. The probe is injected as a closure `() -> FullDiskAccessState` for these tests.
- **XCUITest (`BackglanceUITests/OnboardingUITests`)** — walk screens 1→5 with a launch argument `-uiTestFDAState granted`, verify copy, verify "Skip for now" leaves the banner visible in the popover, verify VoiceOver labels.
- **Manual matrix (release checklist)** — on macOS 14, 15, 26: fresh user, grant, revoke via `tccutil`, re-grant, upgrade path from previous Backglance version.
- **CI** — GitHub Actions runners do not have FDA for the test binary; probe tests use temp files, never the real store. Fixture-based store tests do not need FDA at all.

## Next Steps

- Read [CAPTURE.md](./CAPTURE.md) for what happens once FDA is granted.
- Read [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md) for exclusion list, OTP redaction, retention, and panic wipe.
- Read [../security/SECURITY.md](../security/SECURITY.md) for the threat model and disclosure policy.

## Related Documentation

- [CAPTURE.md](./CAPTURE.md)
- [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md)
- [MISSED_DIGEST.md](./MISSED_DIGEST.md)
- [../architecture/ARCHITECTURE.md](../architecture/ARCHITECTURE.md)
- [../architecture/OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md)
- [../security/SECURITY.md](../security/SECURITY.md)
- [../security/LEGAL_COMPLIANCE.md](../security/LEGAL_COMPLIANCE.md)
- [../getting-started/QUICK_START.md](../getting-started/QUICK_START.md)
- [../getting-started/DEVELOPMENT_GUIDE.md](../getting-started/DEVELOPMENT_GUIDE.md)
- [../operations/TROUBLESHOOTING.md](../operations/TROUBLESHOOTING.md)
- [../reference/FAQ.md](../reference/FAQ.md)
- [../reference/ACCESSIBILITY.md](../reference/ACCESSIBILITY.md)
- [../testing/TESTING.md](../testing/TESTING.md)
