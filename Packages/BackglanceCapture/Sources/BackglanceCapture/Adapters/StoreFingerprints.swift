import Foundation

// MARK: - StoreFingerprints

/// The schema hashes Backglance has actually seen, per adapter.
///
/// ⚠️ This is the list that decides whether a store is *recognised*. A hash gets in here
/// by way of a fixture: `Scripts/verify_fixture.sh` regenerates the bundled
/// `KnownFingerprints.json` from `Tests/Fixtures/SystemStore/*/manifest.json`, so every
/// entry corresponds to a store shape whose records the test suite parses and checks
/// against a known-good `expected.json`. Hand-editing an entry in is how a mis-parse
/// ships silently; there is no code path that adds one at runtime.
///
/// One adapter can list several hashes. A point release that changes only an index
/// definition or the `dbinfo` value produces a new hash and needs no code change — that is
/// the *fingerprint-only* row of the playbook's decision matrix.
///
/// Keying by adapter id rather than by fixed properties means a new adapter for a new
/// macOS needs one JSON key and no change here.
///
/// See docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md#fixture-refresh-checklist.
public enum StoreFingerprints {
    // MARK: Public

    public static var v14: Set<String> {
        hashes(forAdapter: StoreAdapterV14.id)
    }

    public static var v15: Set<String> {
        hashes(forAdapter: StoreAdapterV15.id)
    }

    public static var v26: Set<String> {
        hashes(forAdapter: StoreAdapterV26.id)
    }

    /// Hashes verified for the adapter with this id, or an empty set if it has none yet.
    ///
    /// An empty set is a normal state, not a failure: it means no fixture has confirmed a
    /// hash for that adapter, so the registry can only reach it through the OS-major
    /// fallback, behind a probe.
    public static func hashes(forAdapter id: String) -> Set<String> {
        byAdapter[id] ?? []
    }

    // MARK: Internal

    /// The bundled file's shape. `version` exists so that a future change to the layout
    /// can be recognised rather than silently mis-decoded.
    struct File: Decodable {
        var version: Int
        var adapters: [String: [String]]
    }

    /// The bundled resource, or `nil` if it did not ship. `Bundle.module` here is the
    /// library's own bundle — a test target's `Bundle.module` is its own, which is why
    /// this is exposed rather than recomputed by the tests.
    static var resourceURL: URL? {
        Bundle.module.url(forResource: "KnownFingerprints", withExtension: "json")
    }

    /// Decodes a file's contents. Separate from loading so tests can exercise the
    /// tolerance rules without a bundle.
    static func decode(_ data: Data) throws -> [String: Set<String>] {
        let file = try JSONDecoder().decode(File.self, from: data)
        return file.adapters.mapValues { Set($0) }
    }

    // MARK: Private

    /// Loaded once. A missing or unreadable resource yields no known hashes at all, which
    /// costs every store a probe and nothing else — capture still runs. That is the right
    /// failure for a packaging mistake: `assertionFailure` catches it in development, and
    /// a release build degrades to "nothing is an exact match" rather than crashing on
    /// launch or, worse, trusting an adapter it should not.
    private static let byAdapter: [String: Set<String>] = {
        guard let url = resourceURL else {
            assertionFailure("KnownFingerprints.json is missing from the BackglanceCapture bundle")
            return [:]
        }
        do {
            return try decode(Data(contentsOf: url))
        } catch {
            assertionFailure("KnownFingerprints.json could not be decoded: \(error)")
            return [:]
        }
    }()
}
