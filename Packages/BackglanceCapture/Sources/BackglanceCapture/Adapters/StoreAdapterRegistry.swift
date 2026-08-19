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
}
