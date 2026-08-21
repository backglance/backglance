@testable import BackglanceCore
import Foundation
import XCTest

/// Covers the ⚠️ presenting heuristic from
/// docs/features/MISSED_DIGEST.md#presenting-and-screen-share-detection.
///
/// The heuristic is pure here precisely so it can be tested without a window server: every
/// case builds the `Observation` the detector would have gathered.
///
/// Most of these are about the failure direction. A missed presentation costs one digest's
/// worth of grouping; a false positive opens an away session while the user is sitting in
/// front of the screen, so the cases that prove "does *not* count as presenting" are the
/// ones that matter.
final class PresentationPolicyTests: XCTestCase {
    // MARK: Internal

    // MARK: - The slideshow half

    func testAPresenterAppFrontmostWithAFullScreenWindowIsPresenting() {
        let observation = PresentationPolicy.Observation(
            frontmostBundleID: "com.apple.iWork.Keynote",
            windows: [.init(ownerName: "Keynote", coversScreen: true, layer: 0)]
        )
        XCTAssertTrue(PresentationPolicy().isPresenting(observation))
    }

    func testAPresenterAppFrontmostWhileMerelyEditingIsNotPresenting() {
        // The false positive the doc names: Keynote is frontmost for the hours someone
        // spends building the deck. Without a screen-covering window, that is not a show.
        let observation = PresentationPolicy.Observation(
            frontmostBundleID: "com.apple.iWork.Keynote",
            windows: [.init(ownerName: "Keynote", coversScreen: false, layer: 0)]
        )
        XCTAssertFalse(PresentationPolicy().isPresenting(observation))
    }

    func testAFullScreenPanelDoesNotCountAsASlideshow() {
        // Layer 0 is an ordinary window. A floating panel that happens to be big is not
        // a slideshow.
        let observation = PresentationPolicy.Observation(
            frontmostBundleID: "com.apple.iWork.Keynote",
            windows: [.init(ownerName: "Keynote", coversScreen: true, layer: 3)]
        )
        XCTAssertFalse(PresentationPolicy().isPresenting(observation))
    }

    func testAnAppOutsideTheAllowlistIsNeverASlideshow() {
        let observation = PresentationPolicy.Observation(
            frontmostBundleID: "com.apple.Safari",
            windows: [.init(ownerName: "Safari", coversScreen: true, layer: 0)]
        )
        XCTAssertFalse(PresentationPolicy().isPresenting(observation))
    }

    func testNoFrontmostAppIsNotPresenting() {
        let observation = PresentationPolicy.Observation(
            frontmostBundleID: nil,
            windows: [.init(ownerName: "Keynote", coversScreen: true, layer: 0)]
        )
        XCTAssertFalse(PresentationPolicy().isPresenting(observation))
    }

    // MARK: - The share-indicator half

    func testAShareToolbarWithAReadableTitleIsPresenting() {
        let observation = PresentationPolicy.Observation(
            frontmostBundleID: "com.apple.Safari",
            windows: [.init(ownerName: "zoom.us", name: "zoom share toolbar")]
        )
        XCTAssertTrue(PresentationPolicy().isPresenting(observation))
    }

    func testTitleMatchingIgnoresCaseWithoutTheTurkishTrap() {
        // `lowercased(with:)` on a POSIX locale, not `lowercased()`: in a Turkish locale
        // "I" folds to "ı" and the prefix would stop matching
        // (docs/reference/INTERNATIONALIZATION.md#the-turkish-locale-rule).
        let observation = PresentationPolicy.Observation(
            windows: [.init(ownerName: "Microsoft Teams", name: "SHARING CONTROLS")]
        )
        XCTAssertTrue(PresentationPolicy().isPresenting(observation))
    }

    func testAKnownOwnerWithNoReadableTitleIsNotPresenting() {
        // 🔒 The important one. Without Screen Recording — which Backglance never requests
        // — `kCGWindowName` is nil, and every shipped indicator's owner (Chrome, Teams,
        // zoom.us) runs all day. Matching on the owner alone would report presenting for
        // as long as Chrome is open.
        let observation = PresentationPolicy.Observation(
            windows: [
                .init(ownerName: "Google Chrome", name: nil),
                .init(ownerName: "Microsoft Teams", name: nil),
                .init(ownerName: "zoom.us", name: nil),
            ]
        )
        XCTAssertFalse(
            PresentationPolicy().isPresenting(observation),
            "an ordinary app's window must never mean presenting just because it exists"
        )
    }

    func testAKnownOwnerWithAnUnrelatedTitleIsNotPresenting() {
        // Zoom is open and in a meeting, but not sharing.
        let observation = PresentationPolicy.Observation(
            windows: [.init(ownerName: "zoom.us", name: "Zoom Meeting")]
        )
        XCTAssertFalse(PresentationPolicy().isPresenting(observation))
    }

    func testTheRightTitleOnTheWrongOwnerIsNotPresenting() {
        let observation = PresentationPolicy.Observation(
            windows: [.init(ownerName: "Some Other App", name: "zoom share toolbar")]
        )
        XCTAssertFalse(PresentationPolicy().isPresenting(observation))
    }

    func testAnEmptyWindowListIsNotPresenting() {
        // What the detector reports when CGWindowList fails outright.
        XCTAssertFalse(PresentationPolicy().isPresenting(.init(frontmostBundleID: "zoom.us")))
    }

    func testEveryShippedIndicatorRequiresAWindowTitle() {
        // Guards the trap directly rather than through behaviour: an `.ownerOnly` entry
        // is only ever correct for a process that exists solely while sharing, and none
        // of the owners below qualify. If someone adds one, this fails and they have to
        // justify it.
        for indicator in PresentationPolicy.shareIndicators {
            guard case .ownerAndWindowName = indicator else {
                return XCTFail("shipped indicator \(indicator) matches on owner alone")
            }
        }
    }

    // MARK: - The user's allowlist

    func testTheAllowlistIsEditable() {
        let policy = PresentationPolicy(presenterBundleIDs: ["com.example.Deck"])
        let observation = PresentationPolicy.Observation(
            frontmostBundleID: "com.example.Deck",
            windows: [.init(ownerName: "Deck", coversScreen: true, layer: 0)]
        )
        XCTAssertTrue(policy.isPresenting(observation))
    }

    func testAnUntouchedAllowlistIsTheShippedDefault() throws {
        let defaults = try throwawayDefaults()
        XCTAssertEqual(
            PresentationPolicy(defaults: defaults).presenterBundleIDs,
            PresentationPolicy.defaultPresenterBundleIDs
        )
    }

    func testAnEditedAllowlistRoundTrips() throws {
        let defaults = try throwawayDefaults()
        PresentationPolicy.save(presenterBundleIDs: ["com.example.Deck", "com.example.Slides"], to: defaults)
        XCTAssertEqual(
            PresentationPolicy(defaults: defaults).presenterBundleIDs,
            ["com.example.Deck", "com.example.Slides"]
        )
    }

    func testAnEmptyAllowlistIsRespectedRatherThanTreatedAsUnset() throws {
        // "Never detect a slideshow" is a real choice, and falling back to the defaults
        // here would silently overrule it.
        let defaults = try throwawayDefaults()
        PresentationPolicy.save(presenterBundleIDs: [], to: defaults)

        let policy = PresentationPolicy(defaults: defaults)
        XCTAssertTrue(policy.presenterBundleIDs.isEmpty)
        XCTAssertFalse(policy.isPresenting(.init(
            frontmostBundleID: "com.apple.iWork.Keynote",
            windows: [.init(ownerName: "Keynote", coversScreen: true, layer: 0)]
        )))
    }

    func testResettingRestoresTheShippedDefaults() throws {
        let defaults = try throwawayDefaults()
        PresentationPolicy.save(presenterBundleIDs: ["com.example.Deck"], to: defaults)
        PresentationPolicy.resetPresenterBundleIDs(in: defaults)
        XCTAssertEqual(
            PresentationPolicy(defaults: defaults).presenterBundleIDs,
            PresentationPolicy.defaultPresenterBundleIDs
        )
    }

    // MARK: Private

    /// A suite of its own per test, removed on teardown, so nothing leaks into the real
    /// preferences or between cases.
    private func throwawayDefaults() throws -> UserDefaults {
        let name = "app.backglance.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }
}
