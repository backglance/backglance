@testable import BackglanceCore
import Foundation
import GRDB
import XCTest

final class UnixDateTests: XCTestCase {
    // MARK: - DatabaseValueConvertible round-trip

    func testRoundTripsThroughDatabaseValue() {
        let original = UnixDate(Date(timeIntervalSince1970: 1_755_421_200))
        let dbValue = original.databaseValue
        let restored = UnixDate.fromDatabaseValue(dbValue)

        XCTAssertEqual(restored, original)
    }

    func testFromDatabaseValueAcceptsInteger() {
        let dbValue = Int64(1_755_421_200).databaseValue
        let restored = UnixDate.fromDatabaseValue(dbValue)

        XCTAssertEqual(restored?.date, Date(timeIntervalSince1970: 1_755_421_200))
    }

    func testFromDatabaseValueReturnsNilForText() {
        let dbValue = "not-a-date".databaseValue
        XCTAssertNil(UnixDate.fromDatabaseValue(dbValue))
    }

    func testFromDatabaseValueReturnsNilForNull() {
        XCTAssertNil(UnixDate.fromDatabaseValue(.null))
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let original = UnixDate(Date(timeIntervalSince1970: 1_755_421_200))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UnixDate.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testCodableEncodesAsBareNumberNotAnObject() throws {
        let value = UnixDate(Date(timeIntervalSince1970: 1_755_421_200))
        let data = try JSONEncoder().encode(value)
        let json = try XCTUnwrap(String(bytes: data, encoding: .utf8))

        XCTAssertEqual(json, "1755421200")
    }

    // MARK: - Comparable

    func testComparableOrdering() {
        let earlier = UnixDate(Date(timeIntervalSince1970: 100))
        let later = UnixDate(Date(timeIntervalSince1970: 200))

        XCTAssertLessThan(earlier, later)
        XCTAssertFalse(later < earlier)
    }

    // MARK: - Hashable

    func testHashableEqualityForEqualDates() {
        let date = Date(timeIntervalSince1970: 1_755_421_200)
        let first = UnixDate(date)
        let second = UnixDate(date)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.hashValue, second.hashValue)
    }
}
