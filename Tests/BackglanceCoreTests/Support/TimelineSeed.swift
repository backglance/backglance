@testable import BackglanceCore
import BackglanceTestSupport
import Foundation
import GRDB

/// Seeds an in-memory archive with synthetic notifications for the timeline suites.
///
/// Rows go in through one transaction rather than ``Archive/insert(_:redaction:)``
/// per row: these tests are about *reading* pages, and ten thousand single-row
/// transactions would spend the whole test budget on writes the assertions never
/// look at. Text comes from a seeded ``SplitMix64`` — never anything resembling a
/// real notification.
enum TimelineSeed {
    // MARK: Internal

    /// Inserts `count` notifications, newest first, one second apart.
    ///
    /// - Parameters:
    ///   - burst: how many of the newest rows share a single `delivered_at`. A
    ///     burst is the case keyset pagination exists for — an app delivering a
    ///     batch in one second gives many rows the same sort key, so only the `id`
    ///     tiebreaker keeps a page boundary inside the burst honest.
    ///   - deleted: indexes to insert with `is_deleted = 1`. They are seeded but
    ///     never expected back.
    /// - Returns: the ids of every visible row in the order the timeline must
    ///   return them — `delivered_at DESC, id DESC`.
    @discardableResult
    static func fill(
        _ archive: Archive,
        count: Int,
        burst: Int = 0,
        deleted: Set<Int> = [],
        seed: UInt64 = 0x5EED_1234
    ) throws -> [Int64] {
        var random = SplitMix64(seed: seed)
        let newest = Stubs.epoch

        return try archive.pool.write { db in
            var app = AppRecord(
                bundleId: Stubs.BundleID.slack,
                displayName: "Slack",
                firstSeenAt: UnixDate(newest),
                lastSeenAt: UnixDate(newest)
            )
            try app.insert(db)
            guard let appID = app.id else {
                throw SeedError.missingRowID
            }

            var burstIDs: [Int64] = []
            var steppedIDs: [Int64] = []

            for index in 0 ..< count {
                let isBurst = index < burst
                // Burst rows all land on `newest`; every later row steps one more
                // second back, so ordering by (delivered_at, id) is unambiguous
                // everywhere except inside the burst, which is the point.
                let secondsBack = isBurst ? 0 : index - burst + 1
                var row = ArchivedNotification(
                    uuid: UUID().uuidString,
                    appId: appID,
                    title: "Fixture message \(String(format: "%06d", random.next() % 1_000_000))",
                    deliveredAt: UnixDate(newest.addingTimeInterval(-Double(secondsBack))),
                    capturedAt: UnixDate(newest),
                    isDeleted: deleted.contains(index)
                )
                try row.insert(db)

                guard let id = row.id else {
                    throw SeedError.missingRowID
                }
                guard !deleted.contains(index) else {
                    continue
                }
                if isBurst {
                    burstIDs.append(id)
                } else {
                    steppedIDs.append(id)
                }
            }

            // Inside the burst every row shares one timestamp, so `id DESC` decides:
            // last inserted comes first. After it, each row is strictly older than
            // the one before, so insertion order already is timeline order.
            return burstIDs.reversed() + steppedIDs
        }
    }

    // MARK: Private

    private enum SeedError: Error {
        case missingRowID
    }
}
