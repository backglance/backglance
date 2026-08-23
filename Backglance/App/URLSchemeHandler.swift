import AppKit
import BackglanceCore
import Foundation

// MARK: - URLRoutePerforming

/// The surfaces a parsed ``BackglanceCore/URLRoute`` drives.
///
/// A protocol rather than a direct `AppDelegate` reference for the same reason
/// `ActionDispatching` exists: ``URLSchemeHandler`` is drivable with a fake conformer that
/// has no `NSApplication`, no popover and no capture engine behind it.
/// `AnyObject`-bound so ``URLSchemeHandler`` can hold its conformer `weak`: the app
/// delegate owns the handler, and a strong pair going the other way would be a retain
/// cycle neither side needs, since the delegate already outlives everything for the life
/// of the process.
@MainActor
protocol URLRoutePerforming: AnyObject {
    /// `backglance://search?q=` — open the popover (idempotently — a search that arrives
    /// while it is already open should not close it) with `query` prefilled and running.
    func performSearch(query: String)
    /// `backglance://open?id=` — reveal `uuid` in the timeline, or say it is not archived.
    func performOpen(uuid: UUID)
    /// `backglance://digest` — show whatever `DigestPresenter` currently has.
    func performDigest()
    /// `backglance://pause?minutes=` — `date` is already resolved from `minutes`; `nil`
    /// pauses indefinitely.
    func performPause(until date: Date?)
    /// `backglance://resume`.
    func performResume()
}

// MARK: - URLSchemeHandler

/// Receives `backglance://` Apple Events and dispatches them.
///
/// `Info.plist` registers the `backglance` scheme under `CFBundleURLTypes`; this is the
/// type `AppDelegate+URLScheme.swift` installs to receive `kAEGetURL` Apple Events for it.
/// See docs/api/API_DOCUMENTATION.md#url-scheme-backglance for the full contract.
///
/// The parsing itself is *not* here — ``BackglanceCore/URLRoute/parse(_:)`` owns it, and
/// that type's own doc comment explains why it sits in a package rather than beside this
/// file. What is left here is exactly the part that cannot move: `NSAppleEventManager`
/// registration, which needs an Objective-C target/selector pair, and dispatch to
/// ``URLRoutePerforming``, which is AppKit all the way down.
///
/// A class, not the `struct` docs/features/EXPORT_AUTOMATION.md#url-scheme's sketch shows,
/// for that same selector reason: only a reference type can be an Apple Event target.
///
/// `@MainActor` because everything it dispatches to is: ``URLRoutePerforming`` is
/// `@MainActor`-bound, and `NSAppleEventManager` delivers `kAEGetURL` on the main thread
/// in the first place.
@MainActor
final class URLSchemeHandler: NSObject {
    // MARK: Lifecycle

    /// - Parameters:
    ///   - performer: the surfaces routes drive. Held `weak` — see ``URLRoutePerforming``.
    ///   - now: where "now" comes from for turning `pause`'s `minutes` into a deadline.
    ///     Injectable so a test can assert an exact resume date without racing the clock.
    init(performer: any URLRoutePerforming, now: @escaping () -> Date = { Date() }) {
        self.performer = performer
        self.now = now
    }

    // MARK: Internal

    weak var performer: (any URLRoutePerforming)?

    /// Registers this instance as the handler for `kAEGetURL` Apple Events, which is how
    /// macOS delivers `backglance://…` whether Backglance was already running or had to be
    /// launched for it. Call once, from `AppDelegate`, after every surface a route can
    /// reach already exists — `AppDelegate+URLScheme.swift` explains exactly where.
    func install(on manager: NSAppleEventManager = .shared()) {
        manager.setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    /// Parses `url` and dispatches it, or logs a content-free failure line.
    ///
    /// This — not ``BackglanceCore/URLRoute/parse(_:)`` alone — is what a caller with a
    /// live app reaches for: a bad URL never throws past this point and never crashes the
    /// process (docs/api/API_DOCUMENTATION.md#error-behavior, "the process never exits
    /// because of a bad URL").
    func handle(_ url: URL) {
        do {
            try perform(URLRoute.parse(url))
        } catch let error as URLRouteError {
            Log.automation.error("bad url route: \(error.logDescription)")
        } catch {
            // `parse(_:)` only ever throws `URLRouteError`; this branch exists so the
            // `catch` is exhaustive without a force cast, not because another error type
            // is expected in practice.
            Log.automation.error("bad url route: \(String(describing: type(of: error)))")
        }
    }

    /// Dispatches an already-parsed route to ``performer``. Separated from ``handle(_:)``
    /// so a test can drive a route without going through Apple Event plumbing or a real
    /// URL string.
    func perform(_ route: URLRoute) {
        guard let performer else {
            return
        }
        switch route {
        case let .search(query):
            performer.performSearch(query: query)

        case let .open(uuid):
            performer.performOpen(uuid: uuid)

        case .digest:
            performer.performDigest()

        case let .pause(minutes):
            let deadline = minutes.map { now().addingTimeInterval(TimeInterval($0) * 60) }
            performer.performPause(until: deadline)

        case .resume:
            performer.performResume()
        }
    }

    // MARK: Private

    private let now: () -> Date

    /// The Apple Event entry point `install(on:)` registers. `@objc` because
    /// `NSAppleEventManager` calls it by selector, not directly — the one place in this
    /// file that has to be Objective-C-visible.
    @objc
    private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent _: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string)
        else {
            Log.automation.error("bad url route: could not read a URL from the Apple Event")
            return
        }
        handle(url)
    }
}
