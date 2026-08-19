import Foundation
import GRDB

// MARK: - StoreAdapterRegistry

/// Chooses the adapter for the store in front of us.
///
/// This is where Backglance's answer to "Apple changed the store" lives. The registry
/// never widens an adapter to fit an unfamiliar schema; it picks the best candidate by
/// fingerprint, and everything less certain than an exact match has to survive a probe
/// before it is used. The alternative — reading an unrecognised store with the closest
/// adapter and hoping — produces an archive that is quietly wrong, which is worse for the
/// user than an archive that stops growing and says why.
///
/// The API is deliberately in two steps. ``resolve(fingerprint:)`` is a pure lookup with
/// no database in sight, so the ordering rules can be tested exhaustively as a value
/// problem; ``resolve(fingerprint:probing:)`` adds the sanity check that needs a snapshot.
///
/// See docs/architecture/ARCHITECTURE.md#fingerprint-first-registry-resolution.
public enum StoreAdapterRegistry {
    // MARK: Public

    /// Every adapter Backglance ships, newest first.
    ///
    /// The order is load-bearing twice over: on an OS-major tie the first match wins, and
    /// a macOS newer than anything here falls back to `adapters.first`. Register a new
    /// adapter at the top.
    public static let adapters: [any StoreAdapter] = [
        StoreAdapterV26(),
        StoreAdapterV15(),
        StoreAdapterV14(),
    ]

    /// Step one: the best candidate for `fingerprint`, or `nil` if nothing is plausible.
    ///
    /// A pure lookup — no I/O, no probe, no opinion about whether the candidate will
    /// actually work. Three rules, in order:
    ///
    /// 1. **Exact fingerprint.** A hash that was observed and fixture-tested. This is the
    ///    only outcome that gets used without further checking.
    /// 2. **Same OS major.** The schema hash is unfamiliar but the macOS is one we ship an
    ///    adapter for — a point release that changed an index, or a `dbinfo` bump. Likely
    ///    right, not yet trusted.
    /// 3. **Newer macOS than any adapter.** A 27 beta, say. The newest adapter is the best
    ///    guess available, on the observation that Apple's store has changed shape far
    ///    less often than macOS has shipped.
    ///
    /// `nil` means none of those applied — an older macOS than Backglance supports, or an
    /// OS-major we have no adapter for — and the caller turns that into degraded mode.
    /// Returning a candidate anyway would be the guess this design exists to avoid.
    public static func resolve(fingerprint: StoreFingerprint) -> (any StoreAdapter)? {
        resolve(fingerprint: fingerprint, in: adapters)
    }

    /// Step two: resolution, confirmed against the store itself.
    ///
    /// The rule the whole capture layer rests on is here: **an exact fingerprint match is
    /// trusted, everything else has to pass a probe first**. A fallback adapter is a
    /// hypothesis — "this macOS is new but the store still looks like the old one" — and
    /// ``StoreAdapter/probe(_:)`` is what turns it into an observation before a single
    /// record is read.
    ///
    /// Note what this method does *not* do: it never throws, and it never returns an
    /// adapter it is unsure about. Every way of failing comes back as
    /// ``Resolution/degraded(reason:)``, because none of them is an error the user should
    /// see as an alert — they are states the engine sits in and retries out of, with the
    /// archive untouched.
    ///
    /// - Parameter db: a read-only snapshot of the store, never the live file.
    public static func resolve(fingerprint: StoreFingerprint, probing db: Database) -> Resolution {
        resolve(fingerprint: fingerprint, probing: db, in: adapters)
    }

    // MARK: Internal

    /// The lookup, over an explicit adapter list.
    ///
    /// The shipping list's known hashes are only filled in once a fixture has verified
    /// them, so rule 1 above is unreachable from ``adapters`` until then. Rather than
    /// leave the most important rule untested, the rules take the list as a parameter and
    /// the tests supply adapters with hashes of their own.
    static func resolve(fingerprint: StoreFingerprint, in adapters: [any StoreAdapter]) -> (any StoreAdapter)? {
        if let exact = adapters.first(where: { $0.isExactMatch(for: fingerprint) }) {
            return exact
        }

        let major = fingerprint.osVersion.majorVersion
        if let sameOS = adapters.first(where: { $0.supportedOSRange.contains(major) }) {
            return sameOS
        }

        // A macOS newer than every adapter. Only the probe in step two decides whether
        // this candidate is usable; the lookup just says it is the one worth trying.
        if let newest = adapters.first, major > newest.supportedOSRange.upperBound {
            return newest
        }

        return nil
    }

    /// Resolution over an explicit adapter list. See ``resolve(fingerprint:in:)`` for why
    /// the list is injectable.
    static func resolve(
        fingerprint: StoreFingerprint,
        probing db: Database,
        in adapters: [any StoreAdapter]
    ) -> Resolution {
        guard let candidate = resolve(fingerprint: fingerprint, in: adapters) else {
            return .degraded(reason: .unknownSchema(fingerprint))
        }

        let isExact = candidate.isExactMatch(for: fingerprint)
        do {
            switch try candidate.probe(db) {
            case .ok:
                guard !isExact else {
                    return .matched(candidate)
                }
                return .fallback(
                    candidate,
                    note: "fingerprint \(fingerprint.schemaHash.prefix(12)) unknown; \(candidate.adapterID) probe ok"
                )

            case .permissionDenied:
                return .degraded(reason: .noFullDiskAccess)

            case .missingTables,
                 .unknownSchema:
                // The store is not the shape any adapter reads. This is the expected
                // outcome of Apple reshaping it, and it is the whole reason capture stops
                // rather than guessing.
                return .degraded(reason: .unknownSchema(fingerprint))
            }
        } catch {
            return .degraded(reason: .readError(Self.failureDescription(error)))
        }
    }

    // MARK: Private

    /// A content-free rendering of a probe failure.
    ///
    /// > 🔒 Deliberately *not* `String(describing:)`: a `DatabaseError`'s description
    /// > carries the failing statement and its arguments, and this string ends up in the
    /// > file log and the diagnostics export. The result code says what went wrong;
    /// > nothing from the store needs to come with it. `StoreSnapshot` narrows its SQLite
    /// > errors the same way.
    private static func failureDescription(_ error: Error) -> String {
        guard let databaseError = error as? DatabaseError else {
            return "\(type(of: error))"
        }
        return "sqlite \(databaseError.resultCode.rawValue)"
    }
}

// MARK: StoreAdapterRegistry.Resolution

public extension StoreAdapterRegistry {
    /// The outcome of resolving an adapter against a store.
    ///
    /// Three outcomes rather than an optional, because the middle one carries real
    /// information: ``fallback(_:note:)`` is capture running normally on an adapter that
    /// was chosen by OS rather than by fingerprint, which Settings shows as a best-effort
    /// note and which is the maintainer's cue to refresh a fixture. Collapsing it into
    /// ``matched(_:)`` would hide a macOS change; collapsing it into
    /// ``degraded(reason:)`` would stop capture on a store that reads perfectly well.
    enum Resolution: Sendable {
        /// The fingerprint was recognised and the probe passed. Ordinary running.
        case matched(any StoreAdapter)

        /// The fingerprint was not recognised, but the adapter chosen by OS probed clean.
        /// `note` is content-free — a hash prefix and an adapter id — and safe to log.
        case fallback(any StoreAdapter, note: String)

        /// Capture cannot run against this store. A state, not an error.
        case degraded(reason: DegradedReason)

        // MARK: Internal

        /// The adapter to read with, or `nil` when there is none.
        var adapter: (any StoreAdapter)? {
            switch self {
            case let .matched(adapter),
                 let .fallback(adapter, _):
                adapter

            case .degraded:
                nil
            }
        }

        /// Safe for the file log and `os_log` with `privacy: .public`.
        var logDescription: String {
            switch self {
            case let .matched(adapter):
                "matched \(adapter.adapterID)"

            case let .fallback(adapter, note):
                "fallback \(adapter.adapterID): \(note)"

            case let .degraded(reason):
                "degraded: \(reason.logDescription)"
            }
        }
    }
}
