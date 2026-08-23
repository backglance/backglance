@testable import BackglanceCore
import Foundation
import XCTest

/// `backglance://`'s parser. Every case here is one row of
/// docs/api/API_DOCUMENTATION.md#routes or #error-behavior, plus the bounds
/// #security-properties promises — the reason `URLRoute` lives in this package at all is
/// that those promises are only promises until something asserts them.
final class URLRouteTests: XCTestCase {
    // MARK: Internal

    // MARK: - The five routes

    func testSearchCarriesItsQuery() throws {
        XCTAssertEqual(try URLRoute.parse(url("backglance://search?q=invoice")), .search(query: "invoice"))
    }

    func testSearchDecodesAPercentEncodedGrammarQuery() throws {
        let parsed = try URLRoute.parse(url("backglance://search?q=from%3Aslack%20before%3A2026-08-01%20invoice"))
        XCTAssertEqual(parsed, .search(query: "from:slack before:2026-08-01 invoice"))
    }

    func testOpenCarriesItsUUID() throws {
        let uuid = try XCTUnwrap(UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        XCTAssertEqual(try URLRoute.parse(url("backglance://open?id=\(uuid.uuidString)")), .open(uuid: uuid))
    }

    func testDigestAndResumeTakeNoParameters() throws {
        XCTAssertEqual(try URLRoute.parse(url("backglance://digest")), .digest)
        XCTAssertEqual(try URLRoute.parse(url("backglance://resume")), .resume)
    }

    func testPauseWithoutMinutesIsIndefinite() throws {
        XCTAssertEqual(try URLRoute.parse(url("backglance://pause")), .pause(minutes: nil))
    }

    func testPauseCarriesItsMinutes() throws {
        XCTAssertEqual(try URLRoute.parse(url("backglance://pause?minutes=45")), .pause(minutes: 45))
    }

    // MARK: - An unknown host is an error, an unknown parameter is not

    func testAnUnknownHostIsAnError() {
        assertThrows(.unknownHost("frobnicate"), parsing: "backglance://frobnicate")
    }

    func testAnUnknownParameterIsIgnoredRatherThanRejected() throws {
        // The whole point of the asymmetry in docs/api/API_DOCUMENTATION.md#routes: a
        // parameter a future version adds has to degrade gracefully on this one.
        let parsed = try URLRoute.parse(url("backglance://search?q=invoice&highlight=yes&v=9"))
        XCTAssertEqual(parsed, .search(query: "invoice"))
    }

    // MARK: - Missing and malformed parameters

    func testSearchWithoutAQueryIsAMissingParameter() {
        assertThrows(.missingParameter("q"), parsing: "backglance://search")
    }

    func testSearchWithAnEmptyQueryIsAMissingParameter() {
        assertThrows(.missingParameter("q"), parsing: "backglance://search?q=")
    }

    func testOpenWithoutAnIDIsAMissingParameter() {
        assertThrows(.missingParameter("id"), parsing: "backglance://open")
    }

    func testOpenWithANonUUIDIDIsAnInvalidParameter() {
        assertThrows(.invalidParameter("id"), parsing: "backglance://open?id=not-a-uuid")
    }

    func testPauseMinutesOutsideTheAllowedRangeIsAnInvalidParameter() {
        assertThrows(.invalidParameter("minutes"), parsing: "backglance://pause?minutes=0")
        assertThrows(.invalidParameter("minutes"), parsing: "backglance://pause?minutes=-30")
        assertThrows(.invalidParameter("minutes"), parsing: "backglance://pause?minutes=10081")
    }

    func testPauseMinutesThatIsNotANumberIsAnInvalidParameter() {
        assertThrows(.invalidParameter("minutes"), parsing: "backglance://pause?minutes=soon")
    }

    func testPauseAcceptsBothEndsOfTheAllowedRange() throws {
        XCTAssertEqual(try URLRoute.parse(url("backglance://pause?minutes=1")), .pause(minutes: 1))
        let max = URLRoute.maxPauseMinutes
        XCTAssertEqual(try URLRoute.parse(url("backglance://pause?minutes=\(max)")), .pause(minutes: max))
    }

    // MARK: - Bounds and refusals (docs/api/API_DOCUMENTATION.md#security-properties)

    func testAnOverLongQueryIsTruncatedRatherThanRejected() throws {
        let long = String(repeating: "a", count: URLRoute.maxQueryLength + 500)
        guard case let .search(query) = try URLRoute.parse(url("backglance://search?q=\(long)")) else {
            return XCTFail("expected a search route")
        }
        XCTAssertEqual(query.count, URLRoute.maxQueryLength)
    }

    func testAFileURLIsRefused() {
        // Not "a file URL happens not to name a route" — the scheme check rejects it
        // before any host is looked at, which is what makes "never accepts file paths"
        // true rather than incidental.
        assertThrows(.unknownHost("file:///etc/passwd"), parsing: "file:///etc/passwd")
    }

    func testAURLCarryingAPathIsRefusedEvenWhenItsHostNamesARoute() {
        // `open` is a real route and `id` is a real parameter, so the only thing standing
        // between this URL and a successful parse is the path refusal.
        let uuid = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        assertThrows(
            .unknownHost("backglance://open/etc/passwd?id=\(uuid)"),
            parsing: "backglance://open/etc/passwd?id=\(uuid)"
        )
    }

    func testAnotherAppsSchemeIsRefusedEvenWhenItsHostNamesARoute() {
        assertThrows(.unknownHost("evil://search?q=invoice"), parsing: "evil://search?q=invoice")
    }

    func testAURLWithNoHostIsRefused() {
        assertThrows(.unknownHost("backglance://"), parsing: "backglance://")
    }

    // MARK: - Log lines stay content-free

    func testLogDescriptionsMatchTheDocumentedShapes() {
        XCTAssertEqual(URLRouteError.unknownHost("frobnicate").logDescription, "unknownHost(\"frobnicate\")")
        XCTAssertEqual(URLRouteError.missingParameter("q").logDescription, "missingParameter(\"q\")")
        XCTAssertEqual(URLRouteError.invalidParameter("minutes").logDescription, "invalidParameter(\"minutes\")")
    }

    func testAFailedSearchNeverPutsTheQueryInItsLogLine() {
        // Privacy Invariant #1: `q` is caller-supplied text that can echo a notification.
        // The one error a `search` URL can produce names the parameter, never its value.
        guard let error = errorParsing("backglance://search?q=") else {
            return XCTFail("expected a parse failure")
        }
        XCTAssertEqual(error.logDescription, "missingParameter(\"q\")")
    }

    // MARK: Private

    private func url(_ string: String) -> URL {
        // `URL(string:)` returning nil here would mean the test's own literal is wrong,
        // which is a test bug rather than a parser result worth asserting on.
        guard let url = URL(string: string) else {
            preconditionFailure("malformed test URL: \(string)")
        }
        return url
    }

    private func errorParsing(_ string: String) -> URLRouteError? {
        do {
            _ = try URLRoute.parse(url(string))
            return nil
        } catch let error as URLRouteError {
            return error
        } catch {
            return nil
        }
    }

    private func assertThrows(
        _ expected: URLRouteError,
        parsing string: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(errorParsing(string), expected, file: file, line: line)
    }
}
