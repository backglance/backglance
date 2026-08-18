import Foundation
import GRDB

// MARK: - UnixDate

/// A `Date` persisted as REAL Unix epoch seconds.
///
/// GRDB's default `Date` encoding is ISO-8601 text; every `*_at` column instead stores
/// a `REAL` so range scans on columns like `delivered_at` stay index-friendly and an
/// ad-hoc `sqlite3` query is still readable without a text parse. See
/// docs/architecture/DATABASE_SCHEMA.md#dates-the-unixdate-wrapper for the schema-level
/// rationale.
///
/// > Warning: The system store's records use the Cocoa reference date (seconds since
/// > 2001-01-01), not the Unix epoch. That conversion happens exactly once, in
/// > `RecordParser`, via `Date(timeIntervalSinceReferenceDate:)`. Nothing downstream of
/// > `ParsedNotification` — and in particular no `UnixDate` — should ever hold a
/// > Cocoa-epoch number.
public struct UnixDate: Hashable, Codable, Sendable {
    // MARK: Lifecycle

    public init(_ date: Date) {
        self.date = date
    }

    // Codable: encode/decode as a plain Double so JSON exports and GRDB agree on the
    // wire format — a `UnixDate` field in an export reads as a bare number, not an
    // object with a nested key.
    public init(from decoder: Decoder) throws {
        let seconds = try decoder.singleValueContainer().decode(Double.self)
        date = Date(timeIntervalSince1970: seconds)
    }

    // MARK: Public

    public static var now: UnixDate {
        UnixDate(Date())
    }

    public var date: Date

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(date.timeIntervalSince1970)
    }
}

// MARK: DatabaseValueConvertible

extension UnixDate: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
        date.timeIntervalSince1970.databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> UnixDate? {
        // Accept INTEGER too: hand-written fixtures and old sqlite3 sessions sometimes
        // insert ints.
        if let seconds = Double.fromDatabaseValue(dbValue) {
            return UnixDate(Date(timeIntervalSince1970: seconds))
        }
        return nil
    }
}

// MARK: Comparable

extension UnixDate: Comparable {
    public static func < (lhs: UnixDate, rhs: UnixDate) -> Bool {
        lhs.date < rhs.date
    }
}
