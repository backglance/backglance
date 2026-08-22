import BackglanceCore
@testable import BackglanceSearch
import BackglanceTestSupport
import Foundation
import GRDB
import XCTest

/// `from:` and `sender:` over names that are not ASCII.
///
/// Both filters fold what the user typed in Swift — full Unicode, locale-neutral — and
/// used to compare it against SQL `lower()`, which folds A–Z and nothing else unless
/// SQLite was built with ICU. The two sides disagreed for every non-ASCII name, so
/// `from:isbank` did not find "İŞBANK" and `sender:ayse` did not find "AYŞE": a search
/// that worked for English names and silently returned nothing for everyone else.
///
/// These are written from the outside — through `AppResolver` and `HybridSearch` rather
/// than against the SQL — because the bug was not in either half on its own. Each side
/// was folding correctly; they were just not folding the same way.
///
/// See docs/features/SEARCH.md#query-grammar and
/// docs/reference/INTERNATIONALIZATION.md#the-turkish-locale-rule.
final class NonASCIIFilterTests: XCTestCase {
    // MARK: Internal

    override func setUpWithError() throws {
        try super.setUpWithError()
        archive = try Archive(inMemory: true)
    }

    override func tearDownWithError() throws {
        archive = nil
        try super.tearDownWithError()
    }

    // MARK: - from:

    /// The bug, exactly as reported: an app named "İŞBANK", searched for by someone
    /// typing on a keyboard that has no dotted capital I.
    func testFromFindsAnAppWhoseNameDiffersOnlyByCaseAndDiacritics() throws {
        let archive = try XCTUnwrap(archive)
        let appID = try seedApp(bundleID: "com.example.bank", named: "İŞBANK")

        let resolved = try AppResolver(archive: archive).resolve(parse("from:isbank"))

        XCTAssertEqual(resolved, [appID])
    }

    func testFromFindsTheSameAppWhateverCaseItIsTypedIn() throws {
        let archive = try XCTUnwrap(archive)
        let appID = try seedApp(bundleID: "com.example.bank", named: "İŞBANK")
        let resolver = AppResolver(archive: archive)

        for needle in ["ISBANK", "İşbank", "işBANK", "isbank"] {
            XCTAssertEqual(try resolver.resolve(parse("from:\(needle)")), [appID], needle)
        }
    }

    /// The control. Folding both sides must not cost the ASCII case that always worked —
    /// including `from:mail` matching Mail *and* Airmail, which is the documented answer
    /// rather than an ambiguity to resolve.
    func testFromStillMatchesASCIINamesAsASubstring() throws {
        let archive = try XCTUnwrap(archive)
        let mail = try seedApp(bundleID: "com.apple.mail", named: "Mail")
        let airmail = try seedApp(bundleID: "com.airmail.app", named: "Airmail")

        let resolved = try AppResolver(archive: archive).resolve(parse("from:mail"))

        XCTAssertEqual(resolved, [mail, airmail].sorted())
    }

    /// An app whose name was never resolved has a `NULL` key, and must still be findable
    /// by the identifier it is displayed as.
    func testFromStillMatchesAnUnnamedAppByItsBundleID() throws {
        let archive = try XCTUnwrap(archive)
        let appID = try XCTUnwrap(archive.upsertApp(bundleID: "com.example.chat", now: Self.epoch).id)

        let resolved = try AppResolver(archive: archive).resolve(parse("from:chat"))

        XCTAssertEqual(resolved, [appID])
    }

    func testFromMatchingNothingStaysAnEmptyResult() throws {
        let archive = try XCTUnwrap(archive)
        _ = try seedApp(bundleID: "com.example.bank", named: "İŞBANK")

        XCTAssertTrue(try AppResolver(archive: archive).resolve(parse("from:garanti")).isEmpty)
    }

    // MARK: - sender:

    func testSenderFindsANameThatDiffersOnlyByCaseAndDiacritics() throws {
        let archive = try XCTUnwrap(archive)
        let appID = try seedApp(bundleID: "com.example.chat", named: "Chatter")
        let wanted = try seed(sender: "AYŞE", title: "Transfer received", appID: appID)
        _ = try seed(sender: "Gökhan", title: "Transfer received", appID: appID)

        let hits = try HybridSearch(archive: archive).ftsOnly(SearchQuery(text: "sender:ayse transfer"))

        XCTAssertEqual(hits.map(\.notificationID), [wanted])
    }

    /// The structured-only path — no free text at all, so the filter is the whole query.
    func testSenderAloneFiltersWithoutAnyFreeText() async throws {
        let archive = try XCTUnwrap(archive)
        let appID = try seedApp(bundleID: "com.example.chat", named: "Chatter")
        let wanted = try seed(sender: "Ayşe Demir", title: "Transfer received", appID: appID)
        _ = try seed(sender: "Gökhan", title: "Transfer received", appID: appID)

        let hits = try await HybridSearch(archive: archive).search(SearchQuery(text: "sender:ayse"))

        XCTAssertEqual(hits.map(\.notificationID), [wanted])
    }

    /// The limit of the rule, written down so it is a decision rather than a surprise:
    /// `String.matchKey` removes diacritics, and dotless "ı" carries none — it is its own
    /// letter. So "Yılmaz" folds to "yılmaz" and is not found by typing "yilmaz". The
    /// same is true of the OTP keyword lists, which use the same fold; changing it would
    /// be a change to that rule, not to this filter.
    func testDotlessIIsNotFoldedToI() {
        XCTAssertEqual("Yılmaz".matchKey, "yılmaz")
        XCTAssertEqual("İŞBANK".matchKey, "isbank")
    }

    func testSenderStillMatchesASCIINames() async throws {
        let archive = try XCTUnwrap(archive)
        let appID = try seedApp(bundleID: "com.example.chat", named: "Chatter")
        let wanted = try seed(sender: "Ada Lovelace", title: "Transfer received", appID: appID)

        let hits = try await HybridSearch(archive: archive).search(SearchQuery(text: "sender:ada"))

        XCTAssertEqual(hits.map(\.notificationID), [wanted])
    }

    // MARK: Private

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private var archive: Archive?

    private func parse(_ text: String) throws -> ParsedQuery {
        try QueryParser.parse(text, now: Self.epoch, calendar: Calendar(identifier: .gregorian))
    }

    private func seedApp(bundleID: String, named name: String) throws -> Int64 {
        let archive = try XCTUnwrap(archive)
        let app = try archive.upsertApp(bundleID: bundleID, now: Self.epoch)
        try archive.setDisplayName(name, bundleID: bundleID)
        return try XCTUnwrap(app.id)
    }

    @discardableResult
    private func seed(sender: String, title: String, appID: Int64) throws -> Int64 {
        let stored = try XCTUnwrap(archive).insert(ArchivedNotification(
            uuid: UUID().uuidString,
            appId: appID,
            title: title,
            sender: sender,
            deliveredAt: UnixDate(Self.epoch),
            capturedAt: UnixDate(Self.epoch)
        ))
        return try XCTUnwrap(stored.id)
    }
}
