# Missed Digest — "What did I miss"

Last Updated: 2026-08-18

This document specifies Backglance's signature feature: the digest. When you come back to your Mac — after it was locked, asleep, in a Focus, or being used for a presentation or screen share — Backglance shows one quiet summary of the notifications that arrived while you weren't looking, grouped by app, VIPs first, dismissible with one click, and never repeated. It covers the away-session model, every detection source with an honest account of how reliable it is, session merging, the `DigestEngine` selection and ranking logic, the archive tables it writes, the presentation rules (including the explicit "never nagging" contract), edge cases, error handling and the test strategy.

## Table of Contents

- [Feature Overview](#feature-overview)
- [Architecture](#architecture)
- [Archive Tables Involved](#archive-tables-involved)
- [The Away-Session Model](#the-away-session-model)
  - [Detection Sources and Their Reliability](#detection-sources-and-their-reliability)
  - [Session Merging and Thresholds](#session-merging-and-thresholds)
  - [AwaySessionTracker](#awaysessiontracker)
  - [FocusAssertionWatcher](#focusassertionwatcher)
  - [Presenting and Screen-Share Detection](#presenting-and-screen-share-detection)
- [Business Logic: DigestEngine](#business-logic-digestengine)
- [UI Components](#ui-components)
  - [DigestView](#digestview)
  - [The Local Notification Banner](#the-local-notification-banner)
  - [Settings](#settings)
- [Never Nagging Rules](#never-nagging-rules)
- [Edge Cases and Error Handling](#edge-cases-and-error-handling)
- [Testing Approach](#testing-approach)
- [Next Steps](#next-steps)
- [Related Documentation](#related-documentation)

## Feature Overview

macOS shows a notification once and forgets it. If you were locked, asleep, presenting, or a Focus swallowed the banner, you never knew it happened. Backglance's answer is the digest: at the end of every away session it builds one summary — *"You missed 12 notifications from 4 apps while locked (47 min)"* — and shows it exactly once, on your return.

Design intent, in order:

1. **Trustworthy.** The digest must not miss things. That is why selection uses two independent signals: the away-session time window *and* the system store's own `presented = 0` flag ("this record was delivered but no banner was shown").
2. **Quiet.** One digest per away session, dismiss is one click, no sound by default, and it never re-surfaces. A notification-history app that itself nags would be absurd.
3. **Honest about detection.** Lock and sleep detection are rock-solid public APIs. Focus and presenting detection are not — they are marked ⚠️ throughout, degrade gracefully, and their live status is visible in Settings ▸ Status.

| Piece | Type | Where |
|---|---|---|
| `AwaySessionTracker` | actor, event-driven session state machine | `BackglanceCore` |
| `FocusAssertionWatcher` | ⚠️ file watcher on the DND assertions database | `BackglanceCore` |
| `PresentationDetector` | ⚠️ heuristic frontmost-app + window scan | `BackglanceCore` |
| `DigestEngine` | pure selection/ranking, writes `digests` + `digest_items` | `BackglanceCore` |
| `AwaySessionRecorder` | record → link → build, in that order, for one finished session | `BackglanceCore` |
| `DigestPolicy` | whether a finished session earns a digest at all | `BackglanceCore` |
| `DigestPresenter` | whether the popover shows one, and which | `BackglanceUI` |
| `DigestView` | SwiftUI, shown in the popover; also the full timeline entry point | `BackglanceUI` |
| `DigestBannerPolicy` | whether a digest also earns a banner | `BackglanceCore` |
| `DigestBannerPoster` | optional `UNUserNotificationCenter` local notification | app target |

> ℹ️ **Info:** The digest reads only Backglance's archive. Notifications that were never captured (capture paused, app excluded, FDA revoked — see [CAPTURE.md](./CAPTURE.md) and [PERMISSIONS_PRIVACY.md](./PERMISSIONS_PRIVACY.md)) cannot appear in a digest.

## Architecture

```
   OS events                                     Backglance
┌───────────────────────────┐   ┌─────────────────────────────────────────────┐
│ DistributedNotification-  │   │            AwaySessionTracker (actor)       │
│ Center                    │   │                                             │
│  com.apple.screenIsLocked ├──►│  Event stream ──► state machine             │
│  com.apple.screenIsUnlocked│  │   .idle ⇄ .away(reasons: Set<AwayReason>,   │
│ NSWorkspace               │   │            since: Date)                     │
│  willSleepNotification    ├──►│                                             │
│  didWakeNotification      │   │  merge gap < 60 s │ min duration 5 min      │
│  screensDidSleep/Wake     │   └─────────┬─────────────────────┬─────────────┘
│                           │             │ sessionEnded        │ writes
│ ⚠️ ~/Library/DoNotDisturb/ │             ▼                     ▼
│   DB/Assertions.json      │   ┌──────────────────┐   ┌──────────────────┐
│   (FocusAssertionWatcher, ├──►│   DigestEngine   │──►│ archive:         │
│    DispatchSource)        │   │  select ∪ rank   │   │  away_sessions   │
│                           │   │  group  ∪ cap    │   │  digests         │
│ ⚠️ CGWindowList +          │   └────────┬─────────┘   │  digest_items    │
│   frontmost app           │            │             │  notifications.  │
│   (PresentationDetector)  ├────────────┘             │   away_session_id│
└───────────────────────────┘                          └────────┬─────────┘
                                                                │
                              ┌─────────────────────────────────┴───────────┐
                              │  Presentation                               │
                              │   DigestView (popover, first open on return)│
                              │   optional UNUserNotificationCenter banner  │
                              │   "Open timeline at this point"             │
                              └─────────────────────────────────────────────┘
```

The store's `presented` flag flows in separately: `CaptureEngine` copies it into `notifications.presented` at insert time ([CAPTURE.md](./CAPTURE.md)), and `DigestEngine` uses it as the second selection signal.

## Archive Tables Involved

Canonical DDL in [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md). The digest touches four tables:

```sql
CREATE TABLE away_sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at REAL NOT NULL, ended_at REAL,
  reason TEXT NOT NULL                 -- 'locked' | 'asleep' | 'focus' | 'presenting' | 'manual'
);
CREATE TABLE digests (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  away_session_id INTEGER NOT NULL REFERENCES away_sessions(id) ON DELETE CASCADE,
  created_at REAL NOT NULL, shown_at REAL, dismissed_at REAL,
  item_count INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE digest_items (
  digest_id INTEGER NOT NULL REFERENCES digests(id) ON DELETE CASCADE,
  notification_id INTEGER NOT NULL REFERENCES notifications(id) ON DELETE CASCADE,
  rank INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (digest_id, notification_id)
);
-- notifications.away_session_id INTEGER REFERENCES away_sessions(id) ON DELETE SET NULL
-- notifications.presented INTEGER  -- the store's own "banner was shown" flag
```

Conventions:

- A session with overlapping causes is **one row**; `reason` stores the primary reason (first cause chronologically), and the full set travels to the digest build on `AwaySessionTracker.EndedSession.reasons` rather than to a column. The column keeps the schema simple for v1.0; the set is not persisted, so anything that needs it must read it before the session is written.
- `digests.shown_at IS NULL` means "built but the user hasn't seen it yet"; `dismissed_at` set means it will never be shown again. One digest per session is enforced by `DigestEngine` checking for an existing row (`SELECT id FROM digests WHERE away_session_id = ?`) before building.
- `notifications.away_session_id` is set when the session is **recorded**, by
  `Archive.linkNotifications(to:)`, not when a digest is built. A session under the digest
  threshold never gets a digest, and the stated reason for keeping those rows is that they
  are still worth searching — linking only at build time would leave exactly those sessions
  unlinked and quietly make that false. It claims only rows with `away_session_id IS NULL`
  and `is_deleted = 0`, so a re-run never moves a notification between sessions. This is
  what makes `is:missed` in search work ([SEARCH.md](./SEARCH.md)); the digest build reads
  the column rather than filling it.
- `ON DELETE CASCADE` on `digest_items.notification_id` means retention pruning shrinks old digests naturally; `item_count` keeps the original headline number.

## The Away-Session Model

```swift
// Packages/BackglanceCore/Sources/BackglanceCore/Away/AwayReason.swift
public enum AwayReason: String, Codable, Hashable, Sendable, CaseIterable {
    case locked, asleep, focus, presenting, manual
}

// Packages/BackglanceCore/Sources/BackglanceCore/Models/AwaySession.swift
// The persisted row, and only what the column vocabulary can hold. `Reason` is a
// typealias for `AwayReason`, so `session.reason` reads naturally at the call site
// without the model owning a second copy of the vocabulary.
public struct AwaySession: Codable, FetchableRecord, MutablePersistableRecord, ... {
    public var id: Int64?
    public var startedAt: UnixDate
    public var endedAt: UnixDate?
    public var reason: Reason                 // the primary cause — see below
}

// Packages/BackglanceCore/Sources/BackglanceCore/Away/AwaySessionTracker.swift
// What the tracker hands back when a session commits. The set and the two flags have
// no columns behind them: they exist for as long as the digest build needs them.
public struct EndedSession: Sendable, Equatable {
    public let session: AwaySession           // `id` is nil; the caller inserts it
    public let reasons: Set<AwayReason>       // every cause seen during the session
    public let isPartial: Bool                // app launched mid-session; start = app launch
    public let isReconstructed: Bool          // rebuilt from store timestamps after the fact
    public let meetsDigestThreshold: Bool
    public var duration: TimeInterval
}
```

An away session begins when the first reason becomes active and ends when the **last** reason clears. Reasons overlap freely: locking the lid while a Focus is on produces one session with `reasons = {focus, locked, asleep}`.

### Detection Sources and Their Reliability

Stated plainly, source by source. Settings ▸ Status shows a live line per source.

| Source | Signal | Reliability |
|---|---|---|
| Screen lock/unlock | `DistributedNotificationCenter` `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` | **Reliable.** Technically undocumented notification names, but stable since macOS 10.x and fired synchronously with the lock state. |
| Sleep/wake | `NSWorkspace.willSleepNotification` / `didWakeNotification`, plus `screensDidSleepNotification` / `screensDidWakeNotification` for display-only sleep | **Reliable.** Public API. Wake also triggers an immediate capture poll ([CAPTURE.md](./CAPTURE.md)). |
| Focus / DND | ⚠️ **No public API on macOS.** We watch `~/Library/DoNotDisturb/DB/Assertions.json` (readable because Backglance has FDA) with a `DispatchSource` and parse it tolerantly for active assertions. Secondarily, the store's `presented = 0` flag on captured records is a strong signal that a Focus suppressed the banner. | **Fragile.** The file's location and format are Apple's private business and have already changed once (Monterey introduced it). When parsing fails, Focus detection degrades to off — sessions still form from lock/sleep — and Settings ▸ Status shows "Focus detection: unavailable". |
| Presenting / screen sharing | ⚠️ Heuristic: frontmost app is Keynote or PowerPoint in slideshow mode (app active + a full-screen borderless window it owns), or a known "you are sharing" indicator window exists (Zoom's floating share bar, Google Meet / Microsoft Teams share pips) found via `CGWindowListCopyWindowInfo` by owner + window name prefix. Combined with `presented = 0` on records captured meanwhile. | **Heuristic.** Vendors rename windows; a Zoom update can silently break it. False negatives are accepted; false positives are bounded by the 5-minute minimum. Off by default? No — on by default but listed with a ⚠️ in Settings, individually disableable. |
| Manual | "I'm away" toggle in the menu bar menu | **Exact** — by definition. Ends on toggle-off or on any user input event after 10 s (so people who forget the toggle still get a sane session end). |

> ⚠️ **Warning:** The Focus and presenting detectors read private surfaces (a private JSON database, window titles). This is the same posture as capture itself ([CAPTURE.md](./CAPTURE.md)): observed behaviour, not API. Both are wrapped so total failure costs only granularity — the digest still exists via lock/sleep + `presented = 0`.

> ℹ️ **Info:** `CGWindowListCopyWindowInfo` needs Screen Recording permission to see *other apps'* window **names** on modern macOS. Backglance does **not** request Screen Recording; it matches on the owner bundle plus window geometry where names are unavailable, and simply detects less without the permission. FDA is the only permission Backglance asks for ([PERMISSIONS_PRIVACY.md](./PERMISSIONS_PRIVACY.md)).

### Session Merging and Thresholds

- **Merge gap: 60 s.** Unlocking to glance at the screen and re-locking within a minute does not split the session; the tracker holds a candidate end and cancels it if a new reason activates within 60 s.
- **Minimum duration: 5 min (default, configurable).** Shorter sessions are recorded in `away_sessions` (they are still useful to `is:missed`) but produce no digest. Options: 5 / 15 min / always / never (see [Settings](#settings)), modelled by `DigestThreshold` in `BackglanceCore/Digest/`. Its `minimumDuration` for `never` is `.infinity` rather than a large number, so rule 7 below holds by construction — there is no duration a session can reach to outlast it. `AwaySessionTracker` takes it as `DigestThreshold.minDuration()`, a closure read once per finished session, so changing the setting applies to the next session rather than the next launch.
- **Zero notifications → no digest**, whatever the duration.

### AwaySessionTracker

The tracker is an actor consuming a single event enum. All OS callbacks are adapted into events, which is what makes it fully testable with an injected clock and a scripted stream.

```swift
// Packages/BackglanceCore/Sources/BackglanceCore/Away/AwaySessionTracker.swift
public actor AwaySessionTracker {
    public enum Event: Sendable, Equatable {
        case screenLocked, screenUnlocked
        case willSleep, didWake
        case focusChanged(active: Bool)
        case presentingChanged(active: Bool)
        case manualAway(active: Bool)
    }

    /// One session in progress. `primary` is the first cause chronologically — what the
    /// single `away_sessions.reason` column keeps. `active` is what is holding the
    /// session open right now; `seen` is everything it has ever had.
    private struct Span: Equatable {
        var primary: AwayReason
        var active: Set<AwayReason>
        var seen: Set<AwayReason>
        var since: Date
        var isPartial: Bool
    }

    private enum State: Equatable {
        case idle
        case away(Span)
        case ending(Span, candidateEnd: Date)   // waiting out the merge gap
    }

    public static let defaultMinDuration: TimeInterval = 300
    public static let mergeGap: TimeInterval = 60

    public init(clock: any AwayClock = SystemAwayClock(),
                minDuration: @escaping @Sendable () -> TimeInterval = { Self.defaultMinDuration },
                onEnd: @escaping @Sendable (EndedSession) async -> Void)

    public func handle(_ event: Event)

    /// Opens a flagged session for a Mac that was already away at launch. The real start
    /// is unknowable, so it starts now rather than at a guessed time. No-op unless idle.
    public func beginPartial(reason: AwayReason, at now: Date? = nil)

    /// Commits an open session immediately, skipping the merge gap — for termination,
    /// where waiting 60 s for a timer about to be torn down is not an option.
    public func flush() async
}

public protocol AwayClock: Sendable {
    var now: Date { get }
    /// An absolute deadline, not a duration — see the note under `finalize` below.
    func sleep(until deadline: Date) async throws
}
```

The three transitions are the whole of it:

- **activate** cancels any pending merge timer, then: from `.idle` opens a `Span` whose
  `primary` is this cause; from `.away` adds the cause to `active` and `seen`; from
  `.ending` discards the candidate end and returns to `.away` — that is the merge.
- **deactivate** removes the cause from `active`. While anything is left, the session
  stays open. When `active` empties, the state becomes `.ending` and a timer starts.
  Deactivation while `.idle` is a stray event (an unlock with no preceding lock, which is
  what login looks like) and is ignored rather than turned into a zero-length session.
- **finalize** runs when the merge gap elapses. It builds the `AwaySession` row from
  `primary`, `since` and the candidate end, compares the duration against `minDuration()`
  — read per session, so changing the setting needs no rebuild — and hands the result to
  `onEnd`. A cancelled timer never reaches it, and a re-activation that beats the timer to
  the actor leaves the state no longer `.ending`, so it returns without committing.

> ⚠️ **Warning:** the merge deadline is computed **synchronously in `deactivate`**, as
> `clearedAt + mergeGap`, and handed to the waiting task as an absolute `Date`. Computing
> it inside that task instead — `sleep(for: mergeGap)` — starts the gap whenever the
> executor happens to run the task, which is an unbounded delay: the gap silently
> lengthens under load, and against an injected clock the deadline can land past every
> advance a test intends to make, so the timer never fires at all. The duration form of
> this API does not exist for that reason.

The tracker writes nothing itself. `onEnd` is where the row is persisted, through
`Archive.insertAwaySession(_:)` — including sessions under the threshold, which earn no
digest but still make `is:missed` answer honestly.

The `AwayEventBridge` in the app target subscribes the OS sources and forwards events. It
lives there rather than in `BackglanceCore` because the tracker is deliberately AppKit-free
— that split is what lets the state machine be driven from a scripted stream in tests:

```swift
// Backglance/App/AwayEventBridge.swift (excerpt)
let dnc = DistributedNotificationCenter.default()
observe(dnc, .init("com.apple.screenIsLocked"), .screenLocked)
observe(dnc, .init("com.apple.screenIsUnlocked"), .screenUnlocked)

let wnc = NSWorkspace.shared.notificationCenter
observe(wnc, NSWorkspace.willSleepNotification, .willSleep)
observe(wnc, NSWorkspace.didWakeNotification, .didWake)
// Display-only sleep counts as asleep: notifications still arrive, nobody is looking.
observe(wnc, NSWorkspace.screensDidSleepNotification, .willSleep)
observe(wnc, NSWorkspace.screensDidWakeNotification, .didWake)

// A Mac already locked at launch is away, and its lock notification fired before there
// was anything to hear it. `CGSessionCopyCurrentDictionary` is the read-only way to ask;
// an absent key means unlocked, so an unreadable dictionary means "assume not locked"
// rather than opening a session the user never had.
if Self.screenIsLocked() {
    Task { await tracker.beginPartial(reason: .locked) }
}
```

`start()` is idempotent — it unregisters before it registers, so one lock never produces
two events — and the tokens are torn down from a `nonisolated` helper that `deinit` can
call without `MainActor.assumeIsolated`, which would trap if the last release landed off
the main thread.

Two ends need the same care as the start. `AppDelegate` calls `flush()` on termination, so
quitting while locked commits the open session instead of losing it; and at launch it calls
`Archive.closeOpenAwaySessions(endedAt:)`, because a session a crash left open would sit in
the table looking like the user never came back — which is exactly the row the unread
anchor reads.


### FocusAssertionWatcher

⚠️ Everything in this section rides a private file. The parser is deliberately paranoid: any structural surprise turns the watcher off for the session rather than guessing.

```swift
// Packages/BackglanceCore/Sources/BackglanceCore/Away/FocusAssertionWatcher.swift
/// Watches ~/Library/DoNotDisturb/DB/Assertions.json for active Focus assertions.
/// ⚠️ Private file, no API. Requires FDA (which Backglance has for capture anyway).
public final class FocusAssertionWatcher: @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        case active, inactive
        case unavailable(Unavailable)
    }

    /// A fixed vocabulary, not a free string: these render into the file log and into a
    /// Settings row, and an `Error`'s description would put the user's home directory in
    /// both. `logDescription` and `userMessage` follow the `DegradedReason` pattern.
    public enum Unavailable: Sendable, Equatable {
        case notReadable(code: Int32)   // errno; ENOENT is the ordinary "no Focus ever set up"
        case readFailed                 // opened, but the bytes are not JSON
        case tooLarge(bytes: Int)       // past `sizeLimit`, so not the format we know
        case unexpectedRoot             // JSON, but the root is not an object
        case missingDataArray           // no top-level "data" array of objects

        /// Whether this is a shape nobody has seen, rather than a file that is absent or
        /// was caught mid-write. Only structural reasons stop the watcher.
        public var isStructural: Bool
    }

    public static let defaultURL: URL
    public static let sizeLimit = 4 * 1_024 * 1_024

    public init(url: URL = Self.defaultURL, onChange: @escaping @Sendable (Status) -> Void)
    public func start()   // idempotent; reports the initial state before any change
    public func stop()

    /// Tolerant parse: a top-level `data` array whose entries carry a non-empty
    /// `storeAssertionRecords` array — the shape observed on macOS 13–26. No
    /// `NSKeyedUnarchiver`, no assumptions about key order, no crash on any input.
    func readStatus() -> Status
}
```

Three behaviours matter more than the parse itself:

- **Only a format change latches it off.** `unexpectedRoot`, `missingDataArray` and
  `tooLarge` cancel the source for the session — continuing to parse a shape nobody has
  seen *is* guessing. But bytes that are not JSON at all are a torn read of an atomic
  replace far more often than a format change, so `readFailed` leaves the watcher armed
  and the next event re-reads. A missing file is not a failure at all: a Mac on which no
  Focus was ever configured has none.
- **Settings writes this file by replacing it.** That leaves a `DispatchSource` watching a
  descriptor for an unlinked inode, so `.delete`/`.rename` re-arms on the new file rather
  than reporting on the old one.
- **`.unavailable` must clear the focus cause, not just stop feeding.** Detection can fail
  *after* reporting `.active` — the file is replaced with an unknown shape while a Focus
  is on — and a cause that never clears is a session that never ends. `AppDelegate` sends
  `.focusChanged(active: false)` on every `.unavailable`.

Wiring: `.active`/`.inactive` become `tracker.handle(.focusChanged(active:))`; `.unavailable` additionally flips the Settings ▸ Status line to `Unavailable.userMessage` and stops feeding focus events. The store's `presented = 0` flag remains as the passive fallback: even with the watcher dead, suppressed notifications are still selected into the next lock/sleep digest by the `presented = 0` clause below.

### Presenting and Screen-Share Detection

⚠️ Heuristic by construction, and split in two so the heuristic itself is testable without a window server: `PresentationPolicy` in `BackglanceCore` decides over an `Observation`, and `PresentationDetector` in the app target gathers one from `NSWorkspace` and `CGWindowList` every 15 s.

```swift
// Packages/BackglanceCore/Sources/BackglanceCore/Away/PresentationPolicy.swift
public struct PresentationPolicy: Sendable, Equatable {
    public struct WindowRef: Sendable, Equatable {
        public let ownerName: String
        public let name: String?      // nil without Screen Recording — the ordinary case
        public let coversScreen: Bool
        public let layer: Int         // kCGWindowLayer; a slideshow is layer 0
    }

    public struct Observation: Sendable, Equatable {
        public let frontmostBundleID: String?
        public let windows: [WindowRef]   // empty when the window list could not be read
    }

    public enum ShareIndicator: Sendable, Equatable {
        case ownerAndWindowName(owner: String, namePrefix: String)
        /// ⚠️ Only ever for a process that exists *solely* while sharing. No shipped
        /// indicator uses it — see below.
        case ownerOnly(owner: String)
    }

    /// The user's allowlist, defaulting to Keynote and PowerPoint and persisted in
    /// UserDefaults under `presentationDetection.presenterBundleIDs`.
    public var presenterBundleIDs: Set<String>
    public init(defaults: UserDefaults)
    public static func save(presenterBundleIDs: Set<String>, to defaults: UserDefaults)
    public static func resetPresenterBundleIDs(in defaults: UserDefaults)

    public func isPresenting(_ observation: Observation) -> Bool
}
```

**Both halves of the slideshow test are required.** A presenter app being frontmost is not
enough: Keynote is frontmost for the hours someone spends *building* a deck, and treating
that as presenting would bury a working day in away sessions. It counts only with a
layer-0 window covering a screen.

**Share indicators match on the window title, never on the owner alone.** Every shipped
owner — `zoom.us`, `Google Chrome`, `Microsoft Teams` — runs all day, so the title is the
entire signal. Since `kCGWindowName` for another app's window needs Screen Recording,
which Backglance does not request, those titles are usually `nil`, nothing matches, and
presenting is simply not detected from indicators. Less detection, not a guess. The
`ownerOnly` case exists for a genuinely share-only process and is asserted unused by a
test, because applying it to an ordinary app would open an away session for as long as
that app is running — the worst failure this detector has.

**Everything that can fail, fails towards "not presenting."** No window list, no titles,
no frontmost app: all report `false`, and the detector reports `false` rather than
carrying the previous answer forward, because a stuck `true` never clears.

Honesty ledger: a renamed vendor toolbar is a silent false negative; Meet in Safari is not
detected at all; a full-screen Keynote *rehearsal* is a false positive the 5-minute
minimum bounds but does not eliminate. The `presented = 0` flag covers much of the gap —
while macOS itself suppresses banners during screen sharing, the store records it, and
those notifications enter the digest regardless of whether we noticed the session.

## Business Logic: DigestEngine

`DigestEngine.build(for:)` runs when the tracker reports an eligible session end (and at app launch for reconstruction). Selection, ranking, capping, persistence:

1. **Select** notifications with `delivered_at` inside `[started_at, ended_at]`, **OR** `presented = 0 AND delivered_at` within the session ± 2 min (clock skew between `usernoted`'s timestamps and ours).
2. **Exclude** what should never surface: `is_deleted = 1`, apps with `is_excluded = 1` (never stored anyway, belt and braces), and notifications already claimed by another digest.
3. **Triage** through `RulesEngine`: VIP/highlight hits sort first; apps with `is_muted = 1` collapse into a single line at the bottom ("3 more from muted apps").
4. **Group by app**, apps ordered by their best-ranked item; items within an app newest-first.
5. **Cap at 50 shown**; the remainder becomes "and *n* more", which opens the timeline filtered to the session.
6. **Persist**: insert `digests` + `digest_items` (rank = display order) and set `notifications.away_session_id`, all in one transaction.

```swift
// Packages/BackglanceCore/Sources/BackglanceCore/Digest/DigestEngine.swift
public struct DigestEngine: Sendable {
    public enum DigestError: Error, Equatable {
        case sessionNotPersisted          // never inserted, or still open
        case alreadyBuilt(digestID: Int64)
        public var logDescription: String // identifiers only, safe for the file log
    }

    public static let shownCap = 50
    public static let skewWindow: TimeInterval = 120   // ± 2 min around the session

    /// `triage` is the `TriageEvaluating` seam, defaulting to `NoTriage()`. `RulesEngine`
    /// is a later milestone and becomes one more conformance rather than an edit here —
    /// the same seam `TimelineStore` already depends on.
    public init(archive: Archive,
                triage: any TriageEvaluating = NoTriage(),
                now: @escaping @Sendable () -> Date = { Date() })

    /// Returns nil when the session yields zero notifications; no digest row is written.
    @discardableResult
    public func build(for session: AwaySession) throws -> Digest?
}
```

The parts that are easy to get subtly wrong:

- **Triage is evaluated once per item, not once per comparison.** A comparator that calls
  the rules engine runs it O(n log n) times for a value that cannot change during the
  sort, so the sort key is computed up front.
- **`item_count` counts everything selected, not the shown 50.** It is the headline number
  — "you missed 63" — and it has to stay true after retention prunes the items it counted.
- **Zero notifications writes nothing.** An empty digest is not a quiet digest; it is an
  interruption that says nothing happened.
- **`alreadyBuilt` is enforced inside the transaction**, not by callers remembering to
  check. Wake and unlock race often enough that a second build attempt is an ordinary
  event.
- **The session link claims only rows with `away_session_id IS NULL`.** Most of the
  selection was already linked when the session was recorded
  ([above](#archive-tables-involved)); what this picks up is the `presented = 0`
  stragglers that fall outside the exact window. Restricting it to unclaimed rows is what
  stops an overlapping session from stealing another's notifications. Items past the
  shown cap are linked too, so `is:missed` and "open the timeline here" cover the tail.

Error paths at the call site: `alreadyBuilt` is swallowed with a debug log (double session-end events are possible when wake and unlock race); any `DatabaseError` is logged and retried once after 5 s; a second failure surfaces as a Settings ▸ Status line ("Last digest failed to build — see log") rather than an alert, because the notifications themselves are safely in the archive and reachable through the timeline either way.

**Reconstruction at launch.** If Backglance was not running during the away period (cold boot, app quit), `AppDelegate` asks `DigestEngine.reconstructIfNeeded()` at startup: it looks at the gap between `capture_state['last_import_at']`-adjacent activity and now, and if the capture backfill just imported records with `delivered_at` in that gap or `presented = 0`, it synthesizes an `AwaySession` with `isReconstructed = true` (reason `asleep` as the best guess, or `locked` when launch happened at the login screen). The resulting digest carries a "Reconstructed — Backglance wasn't running for part of this time" label in the UI, because honesty beats implied precision.

## UI Components

| Component | Module | Notes |
|---|---|---|
| `DigestView` | `BackglanceUI` | the digest card; hosted in the popover on first open after return |
| `DigestViewModel` | `BackglanceUI` | `@MainActor @Observable`; loads the digest's rows, groups them, owns the three writes |
| `DigestSection`, `DigestDayCount` | `BackglanceUI` | the value types the card renders, built by `DigestViewModel` |
| `DigestAppSection` | `BackglanceUI` | app icon + name + that app's rows (reuses `NotificationRow`) |
| `DigestHeader` | `BackglanceUI` | headline, reason glyphs (🔒 / 😴 / 🌙 / 📽 / ✋), duration, partial/reconstructed badges |
| `DigestSettingsView` | `BackglanceUI` | thresholds, reasons, banner toggle |
| `DigestSettingsModel` | `BackglanceUI` | the pane's values; the injected authorization request lives here |
| Banner | app target | `UNUserNotificationCenter` local notification, optional |

### DigestView

Shown at the top of the popover the first time it opens after a digest is built; also reachable later via `backglance://digest` and the menu item "Last digest".

`DigestView` is a thin wrapper: it reads the view model and hands plain values to `DigestCard`, which is what actually draws. The split is not ceremony — it is what makes every state the card can be in (overflowing, muted-only, a failed read) reachable from a `#Preview` and a test without seeding an archive first.

```swift
// Packages/BackglanceUI/Sources/BackglanceUI/Digest/DigestView.swift
public struct DigestView: View {
    public let model: DigestViewModel

    public var body: some View {
        DigestCard(
            reasonSymbol: model.primaryReasonSymbol,   // "lock.fill"
            headline: model.headline,                  // "You missed 12 notifications from 4 apps"
            subheadline: model.subheadline,            // "while locked · 47 min · ended 09:12"
            isPartial: model.isPartial,
            isReconstructed: model.isReconstructed,
            dayCounts: model.dayCounts,                // "Fri 34 · Sat 12 · Sun 41", multi-day only
            appSections: model.appSections,
            mutedItems: model.mutedItems,
            overflowCount: model.overflowCount,
            loadError: model.loadError,
            canOpenTimeline: model.session != nil,
            onDismiss: { model.dismiss() },
            onOpenTimeline: { model.openTimelineAtSession() },
            onMarkAllRead: { model.markAllRead() }
        )
        // Loading and the once-only `shown_at` stamp happen together: the moment the
        // card is on screen is the moment it has been shown.
        .task {
            model.load()
            model.markShown()
        }
    }
}
```

`DigestCard` is a `VStack` of `DigestHeader`, a `ScrollView` capped at 380 pt over the `DigestAppSection`s, the collapsed muted `DisclosureGroup`, the "and *n* more…" button, and the footer. Rows are ordinary `NotificationRow`s in compact mode — a summary that rendered notifications differently from the timeline would make the user learn two layouts for one thing.

The two honesty badges are the part that carries the feature's first design goal. `isPartial` (Backglance launched into an already-away Mac) and `isReconstructed` (the session was rebuilt after the fact) are **not columns** — they live on `AwaySessionTracker.EndedSession` and are gone once the session row is written. The build path knows them and passes them to the view model; reopening an old digest from "Last digest" does not, and the card renders without the badges rather than inventing them.

The archive side is four reads and three writes, all in `Archive+Digest.swift`:

| Call | Does |
|---|---|
| `pendingDigest()` | newest digest with `dismissed_at IS NULL` — `shown_at` is deliberately *not* in the predicate, so closing the popover mid-read is not an answer |
| `lastDigest()` | newest digest whatever its state; what "Last digest" reopens read-only |
| `digestNotifications(digestID:)` | the shown rows in `digest_items.rank` order, soft-deleted rows excluded |
| `deliveryDates(inAwaySession:)` | timestamps only, for the multi-day header summary — the count has to cover the whole session, not the 50 rows shown |
| `markDigestShown(_:at:)` | stamps `shown_at` where it `IS NULL`; returns whether this call was the first |
| `dismissDigest(_:at:)` | same once-only stamp on `dismissed_at` |
| `markRead(ids:)` | the digest's own "Mark all read" — *these* notifications, not the whole timeline |

`DigestViewModel.dismiss()` writes `dismissed_at` and removes the card; the digest remains queryable (timeline filter "Missed", `is:missed` in [SEARCH.md](./SEARCH.md)) but is never presented again. "Open timeline at this point" fires `onOpenTimeline`, which the app shell wires to `TimelineWindow` scrolled to `started_at` with the session's rows tinted ([TIMELINE.md](./TIMELINE.md)); the button is absent when the digest has no session to open. "Mark all read" sets `is_read = 1` for the digest's notification ids — it will move to the shared `NotificationActionHandler` when that ships ([ACTIONS.md](./ACTIONS.md)).

### The Local Notification Banner

Optional, and **off** until the user turns it on in Settings ▸ Digest.

Off is the default because of the permission rule, not timidity: Backglance requests Notifications authorization only from an explicit user action ([PERMISSIONS_PRIVACY.md](./PERMISSIONS_PRIVACY.md#notifications-backglances-own-local-notifications)), and a banner that defaulted on would have to ask on its own behalf the first time somebody came back to their Mac. The digest's default presentation is the popover, which needs no permission at all.

The decision and the posting are two types, so the never-nagging rules are testable without `UserNotifications` anywhere near them:

`DigestBannerPolicy` (`BackglanceCore`) is a pure function of the three settings, the session's reason, when the user came back, when they last opened the popover, and one authorization flag. Every gate can say no and none says yes on its own:

| Gate | Refuses when |
|---|---|
| `digest.banner.enabled` | the user has not switched banners on (rule: nothing unasked-for) |
| authorization | `UNUserNotificationCenter` would not deliver — denied *and* never-asked collapse here, since both mean nothing appears |
| `digest.banner.focus` | the session was a Focus and Focus banners are off — a Focus usually means "do not ping me" |
| the grace window | the popover was opened between the session's end and 30 s after it (rule 2) |

The window is anchored to the session's end rather than to "now minus 30 s", so a digest that takes a moment to build cannot slip past a popover the user opened the instant they sat down. An open from *before* they left does not count — that was not about this digest.

`DigestBannerPoster` (app target) holds the only `UserNotifications` import and does no deciding. It reads authorization and never requests it; `LocalNotificationAuthorizer.requestIfNeeded()` is the only thing that asks, and only the Settings toggle calls it. A previous denial is respected rather than re-asked — macOS shows nothing on a second call, so a button that silently did nothing would be worse than the link Settings offers instead.

```swift
// Backglance/Scenes/Digest/DigestBannerPoster.swift
let content = UNMutableNotificationContent()
content.title = String(localized: "What did I miss")
content.body = Self.body(itemCount: digest.itemCount, appCount: appCount, reason: reason)
content.sound = policy.playsSound ? .default : nil          // rule 4: silent unless asked
content.userInfo = [Self.digestIDKey: digestID]

// Deterministic identifier: a second post for one digest replaces the first banner
// rather than adding one, so rule 1 holds even if a caller races.
let request = UNNotificationRequest(identifier: "digest-\(digestID)", content: content, trigger: nil)
try await center.add(request)
```

> 🔒 **Privacy:** nothing from a captured notification reaches that content. The title is fixed and the body is built from two counts and one `AwayReason` — never a title, a sender or a body. A digest banner that quoted what you missed would put another app's notification text on screen, and into the system's own store on the way there.

Tapping the banner opens the popover, which is already showing that digest — `DigestPresenter` surfaces whatever is pending, and the banner exists only because something is. One path to the digest rather than two that could disagree.

Yes, a notification-history app posting a notification is mildly ironic; that is exactly why it is off until asked for, one per session, silent, and one toggle from gone.

### Settings

Settings ▸ Digest, stored in `UserDefaults` (suite `app.backglance.Backglance`) and read back by `DigestThreshold`, `DigestPolicy` and `DigestBannerPolicy` at the moment each is needed — there is no apply step and no cached copy to go stale:

| Setting | Key | Default |
|---|---|---|
| Show digest | `digest.threshold` = `after5min` / `after15min` / `always` / `never` | `after5min` |
| Count time away when | `digest.disabledReasons` (array of `AwayReason` raw values, stored as the *complement* of the checkboxes) | empty |
| Also show a notification banner | `digest.banner.enabled` | **off** — turning it on is what requests Notifications authorization |
| Banner for Focus sessions | `digest.banner.focus` | off |
| Play a sound | `digest.banner.sound` | off |

`DigestSettingsView` (`BackglanceUI`) draws the pane; `DigestSettingsModel` owns the values. Three things about it are deliberate:

- **The reason checkboxes read as positives** ("Count time away when: Locked, Asleep…") while the stored key is the negative set. A list of exclusions is a list people read backwards.
- **Choosing "Never" hides everything below it** and says what it does *not* do: away sessions keep being recorded, so `is:missed` keeps working. That is exactly what someone picking "Never" would otherwise assume they had switched off.
- **The banner toggle flips synchronously and undoes itself** if authorization is refused. A toggle whose `set` only starts async work desyncs from its `get` on the very next redraw — it renders off while the model says on. Flipping first and reverting on refusal is both correct and the more honest animation: the switch visibly declines to stay on, and the pane then says where to change it.

The authorization calls are injected into the model as closures rather than made by it. `BackglanceUI` does not import `UserNotifications`, and more to the point the request must fire on exactly one trigger — this toggle going on — which passing it in makes visible at the call site.

Settings ▸ Status additionally shows the live detection lines: "Lock/unlock: active · Sleep/wake: active · Focus detection: active/unavailable · Presenting detection: active/limited".

## Never Nagging Rules

The explicit contract, testable line by line:

1. **At most one banner per away session.** Enforced by the deterministic request identifier `digest-<id>` plus the one-digest-per-session constraint.
2. **No banner if the user opened the popover within 30 s of return.** They're already looking; `StatusItemController.lastOpenedAt` reports it and `DigestBannerPolicy` checks it.
3. **No repeats.** A dismissed digest (`dismissed_at` set) is never shown again — not on relaunch, not on next popover open. An unshown digest appears in the popover only until it is shown once and dismissed.
4. **No sound by default.** `content.sound = nil` unless `digest.banner.sound` is on; the sound option is requested up front only so the toggle has something to turn on.
5. **No badge.** The digest never contributes to the menu bar unread badge beyond the notifications it contains (which count via `is_read` as usual, [TIMELINE.md](./TIMELINE.md)).
6. **Below-threshold and zero-item sessions are silent.** Recorded, never presented.
7. **"never" means never.** With `digest.threshold = never`, nothing is built or posted; away sessions are still tracked for `is:missed`.

> ✅ **Do:** treat these as invariants in code review. A change that can produce a second banner for one session is a bug, whatever the justification.

### Where each rule actually lives

The rules are enforced in two types, so a change that could break one is visible in a diff rather than spread across the UI:

`DigestPolicy` (`BackglanceCore`) gates the **build**. It reads `digest.threshold` and `digest.disabledReasons` at the moment a session ends — not at launch, so changing a setting takes effect on the next session — and the app shell calls it before `DigestEngine.build(for:)` ever runs. That is what makes rules 6 and 7 true: below-threshold and `never` sessions produce no row at all, rather than a row that presentation later declines to show. A session is suppressed by reason only when **every** one of its causes is disabled; locking the lid during a Focus is still a lock, and switching off Focus digests is not a request to stop hearing about a shut Mac.

`DigestPresenter` (`BackglanceUI`) gates the **presentation**. It is asked for a digest when the popover is about to open — the only moment the answer can have changed for someone who is looking — and it can only ever surface `Archive.pendingDigest()`, which is `dismissed_at IS NULL`. So rule 3 holds across relaunches without any in-memory "already shown" flag, and being shown does not retire a digest: closing the popover mid-read is not an answer. Refreshing while the same digest is already up returns the same model rather than rebuilding it, so the card does not reset under someone who is reading it.

The card takes the whole popover while it is up rather than sitting above the timeline. A 380 × 520 surface cannot show a summary and the thing it summarises without shortchanging both, and the card's two exits — "Open timeline at this point" and dismiss — are what someone finishing it wants next. Reduce Motion drops the slide-in: the card arrives unprompted, on an open the user began for some other reason, which is exactly when unrequested movement is least welcome.

## Edge Cases and Error Handling

| Case | Behaviour |
|---|---|
| Overlapping reasons (Focus active, then lid closed) | one session; `reasons = {focus, asleep, locked}`; primary reason = first activated; ends when the last clears |
| Unlock for 20 s, re-lock | merge gap (60 s) keeps it one session; the candidate end is discarded |
| System clock jumps (NTP correction, timezone change mid-session) | timestamps are Unix epoch, so timezone changes are harmless; a backwards NTP jump can make `ended_at < started_at` — the tracker clamps duration to ≥ 0 and logs it; such a session never meets the threshold |
| App launched mid-session (login while locked, relaunch during Focus) | `beginPartial` starts the session at app launch, `isPartial = true`; the header shows "since Backglance started"; capture backfill still pulls earlier records via `presented = 0` |
| App not running during the away period at all | on launch, `reconstructIfNeeded()` builds a reconstructed session from store timestamps + `presented` flags after the capture backfill; digest is labeled "Reconstructed" |
| A 3-day trip | one session; the digest caps at 50 shown and the header groups the summary per day ("Fri 34 · Sat 12 · Sun 41"); "and n more" opens the timeline at the session start |
| Zero notifications | session recorded, no digest row, nothing shown |
| Double session-end events (wake and unlock race) | absorbed by `AwaySessionTracker`, one layer earlier than the digest: overlapping causes are one span and `onEnd` fires once per finished session, so only one `EndedSession` is ever recorded. `DigestEngine`'s `alreadyBuilt` guard is the second line — it refuses a second build for an already-summarised **session id**, which is what a retry or the future reconstruction path could produce. Swallowed with a debug log |
| Assertions.json format changes | `FocusAssertionWatcher` returns `.unavailable`; Focus events stop; sessions still form from lock/sleep; Settings ▸ Status shows "Focus detection: unavailable"; `presented = 0` still routes suppressed notifications into digests |
| Zoom/Meet/Teams rename their indicator windows | presenting detection silently misses; `presented = 0` fallback still catches what macOS suppressed during sharing |
| Notification arrives seconds before lock, banner suppressed | the ± 2 min skew window plus `presented = 0` pulls it in |
| User dismisses the digest, then wants it back | menu item "Last digest" reopens it read-only (dismissed state unchanged); the timeline filter "Missed" always works |
| Banner authorization denied | logged once; popover path unaffected; Settings ▸ Digest shows "Banners are off in System Settings ▸ Notifications" |
| Digest build fails (disk full, `SQLITE_FULL`) | one retry after 5 s; then a Settings ▸ Status line; notifications remain in the archive and timeline |
| Retention prunes notifications out of an old digest | `digest_items` rows cascade away; `item_count` preserves the historical headline; the digest view shows "some items have been removed by retention" |
| Panic wipe | `away_sessions`, `digests`, `digest_items` all live in the archive and are wiped together ([PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md)) |

## Testing Approach

Targets: `Tests/BackglanceCoreTests` (tracker, engine), `Tests/BackglanceUITests` (dismissal flow). Everything runs on `Archive(inMemory: true)` and synthetic fixtures; no test reads the real store or the real DND database.

**Session tracker with injected clock and scripted events:**

```swift
import Testing
@testable import BackglanceCore

/// Manual clock: `now` only moves when the test advances it; sleeps complete instantly
/// once the target time is reached.
final class TestClock: AwayClock, @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_755_400_000)
    func sleep(for seconds: TimeInterval) async throws { now += seconds }
    func advance(_ seconds: TimeInterval) { now += seconds }
}

@Suite struct AwaySessionTrackerTests {
    @Test func lockUnlockProducesEligibleSession() async throws {
        let clock = TestClock()
        var ended: [AwaySessionTracker.EndedSession] = []
        let tracker = AwaySessionTracker(clock: clock) { ended.append($0) }

        await tracker.handle(.screenLocked)
        clock.advance(600)                               // 10 minutes locked
        await tracker.handle(.screenUnlocked)            // schedules finalize after merge gap
        try await Task.sleep(for: .milliseconds(50))     // let the finalize task run

        #expect(ended.count == 1)
        #expect(ended[0].meetsDigestThreshold)
        #expect(ended[0].session.reasons == [.locked])
    }

    @Test func briefUnlockMergesIntoOneSession() async throws {
        let clock = TestClock()
        var ended: [AwaySessionTracker.EndedSession] = []
        let tracker = AwaySessionTracker(clock: clock) { ended.append($0) }

        await tracker.handle(.screenLocked)
        clock.advance(400)
        await tracker.handle(.screenUnlocked)
        clock.advance(20)                                // re-lock within the 60 s gap
        await tracker.handle(.screenLocked)
        clock.advance(400)
        await tracker.handle(.screenUnlocked)
        try await Task.sleep(for: .milliseconds(50))

        #expect(ended.count == 1)                        // merged, not two sessions
    }

    @Test func overlappingReasonsEndWhenLastClears() async throws {
        let clock = TestClock()
        var ended: [AwaySessionTracker.EndedSession] = []
        let tracker = AwaySessionTracker(clock: clock) { ended.append($0) }

        await tracker.handle(.focusChanged(active: true))
        clock.advance(120)
        await tracker.handle(.screenLocked)
        clock.advance(600)
        await tracker.handle(.screenUnlocked)            // focus still on → session continues
        #expect(ended.isEmpty)
        clock.advance(300)
        await tracker.handle(.focusChanged(active: false))
        try await Task.sleep(for: .milliseconds(50))

        #expect(ended.count == 1)
        #expect(ended[0].session.reasons.contains(.focus))
    }
}
```

**Digest builder table tests** on the seeded archive. The seed includes the important fixture: rows with `presented = 0` whose `delivered_at` is 90 s before the session start (inside the skew window) and others 10 min before (outside it).

```swift
import XCTest
@testable import BackglanceCore

final class DigestEngineTests: XCTestCase {
    func testSelectionUnionOfWindowAndPresentedFlag() async throws {
        let archive = try SeededArchive.makeDigestFixture(seed: 11)
        // Fixture: session 10:00–10:47; 12 in-window rows; 2 rows presented=0 at 09:58:30;
        // 1 row presented=0 at 09:50 (outside skew); 1 excluded-app row in window.
        var session = SeededArchive.fixtureSession                // 10:00–10:47, reason .locked
        session.id = try await archive.insert(session)

        let digest = try await DigestEngine(archive: archive).build(for: session)

        XCTAssertEqual(digest?.itemCount, 14)      // 12 + 2 skew-window presented=0; not 09:50, not excluded
    }

    func testVIPFirstMutedLastCapAt50() async throws {
        let archive = try SeededArchive.makeDigestFixture(seed: 12, count: 80, vipEvery: 10, mutedApp: true)
        var session = SeededArchive.fixtureSession
        session.id = try await archive.insert(session)
        let digest = try await DigestEngine(archive: archive).build(for: session)!

        let items = try await archive.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT di.rank, n.id, a.is_muted FROM digest_items di
                JOIN notifications n ON n.id = di.notification_id
                JOIN apps a ON a.id = n.app_id
                WHERE di.digest_id = ? ORDER BY di.rank
                """, arguments: [digest.id])
        }
        XCTAssertEqual(items.count, 50)                          // cap
        XCTAssertEqual(digest.itemCount, 80)                     // headline keeps the truth
        XCTAssertEqual(items.first?["is_muted"] as Bool?, false) // muted never first
    }

    func testSecondBuildThrowsAlreadyBuilt() async throws {
        let archive = try SeededArchive.makeDigestFixture(seed: 13)
        var session = SeededArchive.fixtureSession
        session.id = try await archive.insert(session)
        _ = try await DigestEngine(archive: archive).build(for: session)
        do {
            _ = try await DigestEngine(archive: archive).build(for: session)
            XCTFail("expected alreadyBuilt")
        } catch DigestEngine.DigestError.alreadyBuilt { /* expected */ }
    }

    func testZeroNotificationsBuildsNothing() async throws {
        let archive = try Archive(inMemory: true)                // empty
        var session = SeededArchive.fixtureSession
        session.id = try await archive.insert(session)
        let digest = try await DigestEngine(archive: archive).build(for: session)
        XCTAssertNil(digest)
        let count = try await archive.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM digests") ?? 0
        }
        XCTAssertEqual(count, 0)
    }
}
```

**Focus watcher parse tests** feed `readStatus()` three fixture files: an active-assertion capture, an empty one, and a deliberately reshaped JSON — asserting `.active`, `.inactive`, `.unavailable` respectively. No test touches the real `~/Library/DoNotDisturb`.

**UI test for dismissal** (XCUITest, `Tests/BackglanceUITests`): launch with `-BGSeedDigest 1` (seeds an unshown digest), open the popover, assert the digest card exists, click "Dismiss digest", relaunch, open the popover, assert the card is gone — the "no repeats" invariant end to end.

**Never-nagging tests**: the banner poster is wrapped behind a protocol in tests; a scripted "popover opened 10 s after return" sequence asserts `post` is never called; a double session-end asserts exactly one `UNNotificationRequest` identifier.

CI runs the Core tests on all three runners; the UI test runs on `macos-26` only ([CI_CD.md](../deployment/CI_CD.md)).

## Next Steps

- Read [TIMELINE.md](./TIMELINE.md) for "Open timeline at this point" and the Missed filter.
- Read [SEARCH.md](./SEARCH.md) for `is:missed`, which rides `away_session_id` and `presented`.
- v1.x follow-ups: `GetMissedDigestIntent` for Shortcuts ([EXPORT_AUTOMATION.md](./EXPORT_AUTOMATION.md)), a digest widget ([WIDGETS.md](./WIDGETS.md)), digest counts in analytics ([ANALYTICS.md](./ANALYTICS.md)).

## Related Documentation

- [CAPTURE.md](./CAPTURE.md) — where `presented` comes from and why late capture still fills digests
- [PERMISSIONS_PRIVACY.md](./PERMISSIONS_PRIVACY.md) — FDA, and why Focus detection can use it
- [TIMELINE.md](./TIMELINE.md) — session-anchored scrolling, Missed filter, read state
- [SEARCH.md](./SEARCH.md) — `is:missed` and the away-session join
- [RULES.md](./RULES.md) — VIP/highlight/mute triage used in digest ranking
- [ACTIONS.md](./ACTIONS.md) — mark-all-read and per-row actions inside the digest
- [PRIVACY_CONTROLS.md](./PRIVACY_CONTROLS.md) — retention pruning of digest items, panic wipe
- [DATABASE_SCHEMA.md](../architecture/DATABASE_SCHEMA.md) — `away_sessions`, `digests`, `digest_items` DDL
- [OS_COMPATIBILITY_PLAYBOOK.md](../architecture/OS_COMPATIBILITY_PLAYBOOK.md) — what breaks per macOS release, including the Assertions.json watch
- [API_DOCUMENTATION.md](../api/API_DOCUMENTATION.md) — `AwaySessionTracker`, `DigestEngine`, `Digest` signatures
- [TROUBLESHOOTING.md](../operations/TROUBLESHOOTING.md) — "Focus detection: unavailable" and other Status lines
- [MONITORING_LOGGING.md](../operations/MONITORING_LOGGING.md) — the `away`/`digest`/`focus` log categories
- [TESTING.md](../testing/TESTING.md) — seeded archive helpers, UI test launch arguments
- [ANALYTICS.md](./ANALYTICS.md) — v1.x reports that count missed notifications per app
- [WIDGETS.md](./WIDGETS.md) — v1.x digest widget
