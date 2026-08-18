import CryptoKit
import Foundation
import GRDB

// MARK: - StoreFingerprint

/// An identifier for the *shape* of Apple's notification store, not its contents.
///
/// ⚠️ The store's schema is undocumented and Apple can change it in any macOS
/// release. Backglance never guesses: it fingerprints the schema it actually found,
/// looks that fingerprint up in the adapter registry, and drops into degraded mode
/// when it does not recognise it. This type is what makes "we do not recognise this
/// store" a detectable state rather than a subtly wrong parse.
///
/// Three parts, in decreasing order of how much they tell us:
///
/// - ``schemaHash`` — SHA-256 over the normalized DDL of every user object in
///   `sqlite_master`. This is the part that actually changes when Apple reshapes the
///   store, and the part the registry matches on first.
/// - ``dbinfoVersion`` — whatever version-like value the store's own `dbinfo` table
///   carries. Apple bumps this on some point releases without touching the schema, so
///   it distinguishes builds that a schema hash alone cannot.
/// - ``osVersion`` — what we were running when we looked. Used for the OS-major
///   fallback when the hash is unknown, and to tell "new macOS" apart from "something
///   unexpected on a macOS we support".
///
/// Persisted in `capture_state.fingerprint` and compared against the bundled
/// `KnownFingerprints.json`. See
/// docs/architecture/OS_COMPATIBILITY_PLAYBOOK.md#how-storefingerprint-is-computed.
public struct StoreFingerprint: Hashable, Codable, Sendable {
    // MARK: Lifecycle

    public init(schemaHash: String, dbinfoVersion: String?, osVersion: OperatingSystemVersion) {
        self.schemaHash = schemaHash
        self.dbinfoVersion = dbinfoVersion
        self.osVersion = osVersion
    }

    // MARK: Public

    /// 64 hex characters: SHA-256 of the normalized `sqlite_master` SQL.
    public let schemaHash: String

    /// The first `dbinfo` value whose key looks version-like, if the store has such a
    /// table at all. `nil` is a normal outcome, not a failure.
    public let dbinfoVersion: String?

    /// The OS version this fingerprint was taken on.
    public let osVersion: OperatingSystemVersion

    /// Short form for logs.
    ///
    /// Content-free by construction: a hash prefix, a version string from Apple's own
    /// bookkeeping table, and the OS version. No notification data can reach it, which
    /// is what lets capture log a fingerprint change at `privacy: .public`.
    public var shortDescription: String {
        "\(schemaHash.prefix(8)) dbinfo=\(dbinfoVersion ?? "-") os=\(osVersion.majorVersion).\(osVersion.minorVersion)"
    }

    /// Computes the fingerprint of the store open on `db`.
    ///
    /// Delegates to ``StoreFingerprinter`` so that the normalization — which
    /// `Scripts/make_fixture.sh` has to reproduce byte-for-byte in bash — lives in
    /// exactly one place.
    public static func compute(in db: Database) throws -> StoreFingerprint {
        try StoreFingerprinter.fingerprint(db)
    }
}

// MARK: - StoreFingerprinter

/// The one place the schema normalization is defined.
public enum StoreFingerprinter {
    /// Fingerprints the store open on `db`.
    ///
    /// The normalization exists so that cosmetic differences in how SQLite hands back
    /// DDL — case, indentation, line breaks introduced by whoever wrote the schema —
    /// do not read as a schema change. Every statement is lowercased and has its
    /// whitespace collapsed to single spaces, statements are ordered by `(type, name)`
    /// so the digest does not depend on `sqlite_master`'s physical row order, and
    /// `sqlite_%` internal objects are skipped because SQLite creates and names those
    /// itself.
    ///
    /// > Important: `Scripts/make_fixture.sh` reproduces this normalization in bash to
    /// > regenerate `KnownFingerprints.json`. The two must agree exactly — a
    /// > difference of one space produces a different hash and silently sends every
    /// > user into degraded mode. Change them together, and re-run the fixture
    /// > verification.
    public static func fingerprint(_ db: Database) throws -> StoreFingerprint {
        try StoreFingerprint(
            schemaHash: schemaHash(db),
            dbinfoVersion: dbinfoVersion(db),
            osVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
    }

    /// SHA-256 over the normalized DDL of every user object in `sqlite_master`.
    public static func schemaHash(_ db: Database) throws -> String {
        let statements = try String.fetchAll(db, sql: """
        SELECT sql FROM sqlite_master
        WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%'
        ORDER BY type, name
        """)
        let normalized = statements
            .map { normalize($0) }
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Lowercased, whitespace collapsed to single spaces.
    public static func normalize(_ statement: String) -> String {
        statement
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// The first `dbinfo` value whose key contains "version".
    ///
    /// `dbinfo` is Apple's own key/value table and the exact key name is not
    /// documented, so anything version-like counts. A store without the table, or
    /// without such a key, yields `nil` — both are ordinary, and neither is worth
    /// failing a bootstrap over, since the schema hash is what the registry matches
    /// on first.
    public static func dbinfoVersion(_ db: Database) throws -> String? {
        guard try db.tableExists("dbinfo") else {
            return nil
        }
        let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM dbinfo")
        let versionRow = rows.first { row in
            ((row["key"] as String?) ?? "").lowercased().contains("version")
        }
        guard let versionRow, let value = versionRow["value"] as DatabaseValue? else {
            return nil
        }
        return value.isNull ? nil : "\(value.storage.value ?? "")"
    }
}

// MARK: - OperatingSystemVersion + @retroactive Codable, @retroactive Hashable, @retroactive Equatable

/// `OperatingSystemVersion` is a plain Foundation struct with no `Codable` or
/// `Hashable` conformance, and ``StoreFingerprint`` has to round-trip through
/// `capture_state` as JSON.
extension OperatingSystemVersion: @retroactive Codable, @retroactive Hashable, @retroactive Equatable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            majorVersion: container.decode(Int.self, forKey: .majorVersion),
            minorVersion: container.decode(Int.self, forKey: .minorVersion),
            patchVersion: container.decode(Int.self, forKey: .patchVersion)
        )
    }

    public static func == (lhs: OperatingSystemVersion, rhs: OperatingSystemVersion) -> Bool {
        lhs.majorVersion == rhs.majorVersion
            && lhs.minorVersion == rhs.minorVersion
            && lhs.patchVersion == rhs.patchVersion
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(majorVersion, forKey: .majorVersion)
        try container.encode(minorVersion, forKey: .minorVersion)
        try container.encode(patchVersion, forKey: .patchVersion)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(majorVersion)
        hasher.combine(minorVersion)
        hasher.combine(patchVersion)
    }

    private enum CodingKeys: String, CodingKey {
        case majorVersion
        case minorVersion
        case patchVersion
    }
}
