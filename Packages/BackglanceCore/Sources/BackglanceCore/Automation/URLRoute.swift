import Foundation

// MARK: - URLRoute

/// Every `backglance://` route ``URLRoute/parse(_:)`` can produce.
///
/// One case per host — `search`, `open`, `digest`, `pause`, `resume` — because that is
/// exactly the set Phase 4.3 ships (docs/api/API_DOCUMENTATION.md#routes). `export` is in
/// that same table, but it is v1.x: TASKS.md's Phase 4.3 line lists only the five routes
/// below, and `ExportSheet` does not exist yet for it to open. Adding `export` here ahead
/// of that milestone would be a route nothing can perform, so it is left out rather than
/// stubbed — see docs/features/EXPORT_AUTOMATION.md#url-scheme for the shape it will take
/// when its own milestone builds `ExportSheet`.
///
/// This type and its parser live in `BackglanceCore`, not beside `URLSchemeHandler` in the
/// app target where docs/features/EXPORT_AUTOMATION.md#url-scheme's sketch draws them, for
/// one reason: no test bundle in this project has a `TEST_HOST` or a `BUNDLE_LOADER`, so
/// nothing can `@testable import Backglance` and app-target code cannot be unit-tested at
/// all (BACKGLANCE-238). Parsing is where this scheme's security properties actually live
/// — the 512-character bound on `q`, the `1...10_080` bound on `minutes`, and the refusal
/// of anything carrying a path — and a security property with no test is a claim, not a
/// guarantee. `SystemSettingsLink` sits in a package next to an app-target
/// `SystemSettingsLinks.swift` for the same reason. What stays in the app target is the
/// part that genuinely cannot move: `NSAppleEventManager` installation and dispatch to
/// AppKit surfaces.
public enum URLRoute: Equatable, Sendable {
    /// `backglance://search?q=` — `query` is already bounded to ``maxQueryLength``
    /// characters and non-empty; the popover opens with it prefilled and the search
    /// running.
    case search(query: String)
    /// `backglance://open?id=` — `uuid` is an already-validated RFC 4122 UUID, the same
    /// value `notifications.uuid` and every export's `uuid` column carry.
    case open(uuid: UUID)
    /// `backglance://digest` — no parameters; the presenter decides digest vs. "nothing
    /// missed" on its own.
    case digest
    /// `backglance://pause?minutes=` — `nil` means "until the user says otherwise",
    /// matching ``PauseChoice/indefinitely``. A present value is already checked against
    /// `1...`` maxPauseMinutes`` (one week).
    case pause(minutes: Int?)
    /// `backglance://resume` — no parameters.
    case resume

    // MARK: Public

    /// The scheme every route is spelled under. Compared exactly, never case-folded: URL
    /// schemes are case-insensitive per RFC 3986, but `Info.plist` registers exactly one
    /// spelling and macOS delivers what it matched, so accepting `BACKGLANCE://` here
    /// would only ever widen the surface without widening what actually arrives.
    public static let scheme = "backglance"

    /// Bounded at 512 characters — docs/api/API_DOCUMENTATION.md#security-properties.
    public static let maxQueryLength = 512

    /// One week, in minutes — the longest a `pause?minutes=` can ask for.
    public static let maxPauseMinutes = 10_080

    /// Parses one `backglance://` URL into a ``URLRoute``, or throws the
    /// ``URLRouteError`` the doc's error table names.
    ///
    /// Pure and `static`: nothing here touches the archive, the popover or the engine,
    /// which is what makes every case in `URLRouteTests` a plain value comparison with no
    /// app to stand up. Bounded input throughout —
    /// docs/api/API_DOCUMENTATION.md#security-properties — `q` is cut at
    /// ``maxQueryLength``, `minutes` at `1...`` maxPauseMinutes``, and every parameter is
    /// read through `URLComponents`, never string-spliced into anything.
    ///
    /// The scheme, the host and the *absence* of a path are all checked in one guard: a
    /// `file://` URL fails it on scheme, `backglance://` with no host fails it on host,
    /// and `backglance://open/etc/passwd?id=…` fails it on path — the scheme accepts a
    /// host and query parameters only, never a path, so nothing resembling a filesystem
    /// path can reach a route's parameters this way. ``URLRouteError/unknownHost(_:)``
    /// covers all three: none of them names a route this build could have run anyway.
    public static func parse(_ url: URL) throws -> URLRoute {
        guard url.scheme == scheme, let host = url.host, url.path.isEmpty else {
            throw URLRouteError.unknownHost(url.absoluteString)
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        /// Unknown query parameters are ignored on purpose — this only ever looks a
        /// caller-supplied name up, it never enumerates `items` — so a future parameter
        /// degrades gracefully on an older build instead of erroring
        /// (docs/api/API_DOCUMENTATION.md#routes).
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        switch host {
        case "search":
            guard let query = value("q"), !query.isEmpty else {
                throw URLRouteError.missingParameter("q")
            }
            return .search(query: String(query.prefix(maxQueryLength)))

        case "open":
            guard let raw = value("id") else {
                throw URLRouteError.missingParameter("id")
            }
            guard let uuid = UUID(uuidString: raw) else {
                throw URLRouteError.invalidParameter("id")
            }
            return .open(uuid: uuid)

        case "digest":
            return .digest

        case "pause":
            guard let raw = value("minutes") else {
                return .pause(minutes: nil)
            }
            guard let minutes = Int(raw), (1 ... maxPauseMinutes).contains(minutes) else {
                throw URLRouteError.invalidParameter("minutes")
            }
            return .pause(minutes: minutes)

        case "resume":
            return .resume

        default:
            throw URLRouteError.unknownHost(host)
        }
    }
}

// MARK: - URLRouteError

/// Everything ``URLRoute/parse(_:)`` can throw.
///
/// Three cases, matching the doc's "Error behavior" table exactly
/// (docs/api/API_DOCUMENTATION.md#error-behavior): a host this build does not recognise,
/// a required parameter that is missing, and a parameter that is present but malformed.
/// Nothing here is content — a host name and a parameter name are values the *caller*
/// chose when writing the URL, never text out of the archive.
public enum URLRouteError: Error, Equatable, Sendable {
    /// The scheme was not `backglance`, there was no host, the URL carried a path
    /// component, or the host is not one of the five routes. `String` is the whole URL
    /// for the first three (there is no host to name), or the bare host for the last.
    case unknownHost(String)
    /// A route's required parameter was absent — `q` for `search`, `id` for `open`.
    case missingParameter(String)
    /// A route's parameter was present but failed validation — `id` not a UUID, `minutes`
    /// outside `1...10_080`.
    case invalidParameter(String)
}

// MARK: LocalizedError

extension URLRouteError: LocalizedError {
    /// One sentence, the same for every case: docs/api/API_DOCUMENTATION.md's error table
    /// gives every failure kind the identical toast text, "Couldn't open link" — the
    /// *log* line is what tells a maintainer which case fired, not the toast a caller of
    /// the URL scheme sees.
    public var errorDescription: String? {
        String(localized: "Couldn't open link")
    }
}

// MARK: Logging

public extension URLRouteError {
    /// The content-free line the doc's error table specifies verbatim, e.g.
    /// `unknownHost("backglance://frobnicate")` or `missingParameter("q")` — never the
    /// query string or any other value the caller supplied beyond the parameter's own
    /// name, which is Backglance's vocabulary, not the caller's.
    ///
    /// `unknownHost` is the one case whose payload is caller text rather than a fixed
    /// name, and it is safe for the same reason the host itself is: a URL a script wrote
    /// is not archive content. It never carries `q`, which is the one parameter that
    /// could echo a notification — an unknown *host* is rejected before any parameter is
    /// read at all.
    var logDescription: String {
        switch self {
        case let .unknownHost(host):
            "unknownHost(\"\(host)\")"

        case let .missingParameter(name):
            "missingParameter(\"\(name)\")"

        case let .invalidParameter(name):
            "invalidParameter(\"\(name)\")"
        }
    }
}
