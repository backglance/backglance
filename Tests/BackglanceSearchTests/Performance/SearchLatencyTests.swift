import BackglanceCore
@testable import BackglanceSearch
import BackglanceTestSupport
import Foundation
import XCTest

/// The latency budgets from docs/deployment/PERFORMANCE_GUIDE.md#search-latency,
/// measured against a hundred thousand synthetic notifications.
///
/// p95 rather than an average, because an average hides exactly the case that
/// matters: the query that hits forty thousand rows. Every test here runs the
/// query a fixed number of times and asserts the 95th percentile, so one
/// unlucky scheduling hiccup on a busy machine cannot fail the suite while a
/// genuine regression still does.
///
/// `Full` configuration only — building the archive takes real time, and a
/// `Fast` run is meant to be fast.
final class SearchLatencyTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            PerfGate.isEnabled,
            "set BACKGLANCE_PERF=1 to measure; runner variance exceeds these budgets"
        )
        archive = try LargeArchive.shared()
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - Full text

    func testARareTermIsWellInsideTheBudget() throws {
        let index = try FTSIndex(archive: XCTUnwrap(archive))

        let p95 = percentile95 {
            _ = try? index.search(match: "\"\(LargeArchive.rareTerm)\"", limit: 200)
        }

        XCTAssertLessThan(p95, Self.ftsBudget, "rare-term FTS p95 \(Self.ms(p95))")
    }

    /// The case the budget is set by: a term in every row, where bm25 has to
    /// rank forty thousand candidates rather than forty.
    func testFTSCommonTermUnder50msP95() throws {
        let index = try FTSIndex(archive: XCTUnwrap(archive))

        let p95 = percentile95 {
            _ = try? index.search(match: "\"\(LargeArchive.commonTerm)\"", limit: 200)
        }

        XCTAssertLessThan(p95, Self.ftsBudget, "common-term FTS p95 \(Self.ms(p95))")
    }

    func testAsYouTypePrefixMatchingIsAlsoInsideTheBudget() throws {
        let index = try FTSIndex(archive: XCTUnwrap(archive))

        let p95 = percentile95 {
            _ = try? index.search(match: "\"invoi\"*", limit: 200)
        }

        XCTAssertLessThan(p95, Self.ftsBudget, "prefix FTS p95 \(Self.ms(p95))")
    }

    // MARK: - Hybrid

    func testHybridUnder250msP95() async throws {
        let search = try HybridSearch(archive: XCTUnwrap(archive))
        var samples: [TimeInterval] = []

        for _ in 0 ..< Self.iterations {
            let started = Date()
            _ = try await search.search(SearchQuery(text: LargeArchive.commonTerm, limit: 200))
            samples.append(Date().timeIntervalSince(started))
        }

        let p95 = Self.percentile95(of: samples)
        XCTAssertLessThan(p95, Self.hybridBudget, "hybrid p95 \(Self.ms(p95))")
    }

    /// A query with filters and a term exercises both halves — the MATCH and
    /// the structured WHERE that narrows its candidates.
    func testATermWithFiltersStaysInsideTheHybridBudget() async throws {
        let search = try HybridSearch(archive: XCTUnwrap(archive))
        var samples: [TimeInterval] = []

        for _ in 0 ..< Self.iterations {
            let started = Date()
            _ = try await search.search(SearchQuery(text: "from:slack is:unread \(LargeArchive.commonTerm)"))
            samples.append(Date().timeIntervalSince(started))
        }

        let p95 = Self.percentile95(of: samples)
        XCTAssertLessThan(p95, Self.hybridBudget, "filtered hybrid p95 \(Self.ms(p95))")
    }

    // MARK: Private

    private static let iterations = 20
    /// The targets the code is written to, and the thresholds a run fails at —
    /// the gap is the machine's variance
    /// (docs/deployment/PERFORMANCE_GUIDE.md#regression-budgets-and-ci-policy).
    private static let ftsBudget = PerfGate.threshold(0.050)
    private static let hybridBudget = PerfGate.threshold(0.250)

    private var archive: Archive?

    private static func percentile95(of samples: [TimeInterval]) -> TimeInterval {
        guard !samples.isEmpty else {
            return 0
        }
        let sorted = samples.sorted()
        let index = Int((Double(sorted.count - 1) * 0.95).rounded())
        return sorted[index]
    }

    private static func ms(_ interval: TimeInterval) -> String {
        String(format: "%.1f ms", interval * 1_000)
    }

    private func percentile95(_ body: () -> Void) -> TimeInterval {
        // One warm-up: the first query pays for opening the index's pages, and
        // the budget is documented as "warm cache".
        body()
        var samples: [TimeInterval] = []
        for _ in 0 ..< Self.iterations {
            let started = Date()
            body()
            samples.append(Date().timeIntervalSince(started))
        }
        return Self.percentile95(of: samples)
    }
}
