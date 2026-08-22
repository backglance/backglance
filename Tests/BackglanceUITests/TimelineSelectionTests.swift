@testable import BackglanceUI
import XCTest

/// The pure ``TimelineSelection`` type — no store, no archive, no host.
/// docs/features/ACTIONS.md#selection-model is the spec: a `Set<Int64>` plus
/// a ⇧-click anchor, with ranges computed over an ordering the caller hands
/// in rather than one this type looks up itself.
final class TimelineSelectionTests: XCTestCase {
    // MARK: - Plain click

    func testSelectReplacesWhateverWasThereAndMovesTheAnchor() {
        var selection = TimelineSelection(ids: [1, 2, 3], anchor: 1)

        selection.select(5)

        XCTAssertEqual(selection.ids, [5])
        XCTAssertEqual(selection.anchor, 5)
    }

    // MARK: - ⌘-toggle

    func testToggleAddsThenRemovesAndMovesTheAnchorEitherWay() {
        var selection = TimelineSelection()

        selection.toggle(1)
        XCTAssertEqual(selection.ids, [1])
        XCTAssertEqual(selection.anchor, 1)

        selection.toggle(2)
        XCTAssertEqual(selection.ids, [1, 2])
        XCTAssertEqual(selection.anchor, 2, "the anchor follows the row just touched, added or not")

        selection.toggle(1)
        XCTAssertEqual(selection.ids, [2])
        XCTAssertEqual(selection.anchor, 1, "removing still moves the anchor to the row that was clicked")
    }

    // MARK: - ⇧-extend

    func testExtendCoversTheClosedRangeWhenTheAnchorIsAboveTheClickedRow() {
        var selection = TimelineSelection()
        let order: [Int64] = [10, 20, 30, 40, 50]
        selection.select(20)

        selection.extend(to: 40, over: order)

        XCTAssertEqual(selection.ids, [20, 30, 40])
        XCTAssertEqual(selection.anchor, 20, "the anchor stays put through an extend")
    }

    func testExtendCoversTheClosedRangeWhenTheAnchorIsBelowTheClickedRow() {
        var selection = TimelineSelection()
        let order: [Int64] = [10, 20, 30, 40, 50]
        selection.select(40)

        selection.extend(to: 20, over: order)

        XCTAssertEqual(selection.ids, [20, 30, 40])
        XCTAssertEqual(selection.anchor, 40)
    }

    /// docs/features/ACTIONS.md's ⇧-click semantics: a range replaces, it does
    /// not union with, the current selection.
    func testExtendReplacesRatherThanUnioningWithTheExistingSelection() {
        var selection = TimelineSelection(ids: [1, 50], anchor: 10)
        let order: [Int64] = [10, 20, 30, 40, 50]

        selection.extend(to: 30, over: order)

        XCTAssertEqual(selection.ids, [10, 20, 30], "the stray members from before the extend are gone")
    }

    /// Successive ⇧-clicks re-range from the same origin — the anchor must
    /// not ratchet forward to the last extend's endpoint.
    func testSuccessiveExtendsRerangeFromTheSameAnchorRatherThanGrowing() {
        var selection = TimelineSelection()
        let order: [Int64] = [10, 20, 30, 40, 50]
        selection.select(20)

        selection.extend(to: 40, over: order)
        XCTAssertEqual(selection.ids, [20, 30, 40])

        selection.extend(to: 10, over: order)

        XCTAssertEqual(
            selection.ids,
            [10, 20],
            "the second extend re-ranges from the original anchor, not from where the first one left off"
        )
        XCTAssertEqual(selection.anchor, 20)
    }

    func testExtendWithNoAnchorDegradesToAPlainSelect() {
        var selection = TimelineSelection()

        selection.extend(to: 30, over: [10, 20, 30])

        XCTAssertEqual(selection.ids, [30])
        XCTAssertEqual(selection.anchor, 30)
    }

    /// The anchor row scrolled out of memory (`TimelineStore.maxRows`) or was
    /// deleted: extending from it must never produce a partial or reversed range.
    func testExtendWithAnAnchorNoLongerInTheOrderDegradesToAPlainSelect() {
        var selection = TimelineSelection(ids: [1, 2], anchor: 999)

        selection.extend(to: 20, over: [10, 20, 30])

        XCTAssertEqual(selection.ids, [20])
        XCTAssertEqual(selection.anchor, 20)
    }

    func testExtendToAnIdNotInTheOrderDegradesToAPlainSelect() {
        var selection = TimelineSelection()
        selection.select(10)

        selection.extend(to: 999, over: [10, 20, 30])

        XCTAssertEqual(selection.ids, [999], "the clicked id itself, even though it is not in the visible order")
        XCTAssertEqual(selection.anchor, 999)
    }

    // MARK: - ⌘A

    func testSelectAllTakesEveryIDWithTheAnchorAtTheFirst() {
        var selection = TimelineSelection()

        selection.selectAll([5, 4, 3])

        XCTAssertEqual(selection.ids, [5, 4, 3])
        XCTAssertEqual(selection.anchor, 5)
    }

    // MARK: - Clear

    func testClearEmptiesBothIDsAndAnchor() {
        var selection = TimelineSelection(ids: [1, 2], anchor: 1)

        selection.clear()

        XCTAssertTrue(selection.ids.isEmpty)
        XCTAssertNil(selection.anchor)
    }

    // MARK: - ordered(over:)

    func testOrderedReturnsVisibleOrderRegardlessOfInsertionOrder() {
        var selection = TimelineSelection()
        selection.selectAll([3, 1, 2]) // ids inserted out of the eventual "visible" order

        XCTAssertEqual(selection.ordered(over: [10, 3, 20, 1, 30, 2]), [3, 1, 2])
    }

    func testOrderedSkipsIDsNoLongerInTheOrder() {
        var selection = TimelineSelection(ids: [1, 2, 3], anchor: 1)

        XCTAssertEqual(selection.ordered(over: [3, 1]), [3, 1], "2 scrolled out of memory; it is skipped, not an error")
        XCTAssertEqual(selection.ids, [1, 2, 3], "ordered(over:) never mutates or prunes the selection itself")
    }

    // MARK: - Conveniences

    func testCountAndContains() {
        var selection = TimelineSelection()
        selection.selectAll([1, 2, 3])

        XCTAssertEqual(selection.count, 3)
        XCTAssertTrue(selection.contains(2))
        XCTAssertFalse(selection.contains(99))
    }
}
