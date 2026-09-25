import XCTest
@testable import RiverDiaryMac

final class CommandPaletteSelectionTests: XCTestCase {
    func testArrowNavigationMovesThroughFilteredResultsAndClampsAtEnds() {
        var selection = CommandPaletteSelection()

        selection.moveDown(itemCount: 2)
        XCTAssertEqual(selection.index, 1)
        selection.moveDown(itemCount: 2)
        XCTAssertEqual(selection.index, 1)

        selection.moveUp(itemCount: 2)
        XCTAssertEqual(selection.index, 0)
        selection.moveUp(itemCount: 2)
        XCTAssertEqual(selection.index, 0)
    }

    func testEmptyResultsCannotBeSelected() {
        var selection = CommandPaletteSelection()
        selection.moveDown(itemCount: 0)

        XCTAssertEqual(selection.index, 0)
        XCTAssertNil(selection.selectedIndex(itemCount: 0))
    }

    func testChangingQueryResetsSelectionToFirstResult() {
        var selection = CommandPaletteSelection()
        selection.moveDown(itemCount: 3)
        selection.moveDown(itemCount: 3)

        selection.reset()

        XCTAssertEqual(selection.index, 0)
        XCTAssertEqual(selection.selectedIndex(itemCount: 2), 0)
    }
}
