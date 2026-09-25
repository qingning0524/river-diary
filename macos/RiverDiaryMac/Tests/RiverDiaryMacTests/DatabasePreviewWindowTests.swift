import XCTest
@testable import RiverDiaryMac

final class DatabasePreviewWindowTests: XCTestCase {
    func testPagesCoverAllRowsWithoutGapsOrDuplicates() {
        var window = DatabasePreviewWindow()
        window.setTotalCount(1_620)

        var visited: [Int] = []
        while true {
            visited.append(contentsOf: window.range)
            guard window.canShowOlder else { break }
            window.showOlder()
        }

        XCTAssertEqual(visited.count, 1_620)
        XCTAssertEqual(Set(visited), Set(0..<1_620))
        XCTAssertEqual(window.range, 0..<20)
        XCTAssertFalse(window.canShowOlder)
        XCTAssertTrue(window.canShowNewer)
    }

    func testNewerReturnsToNewestPageAndResetStartsThere() {
        var window = DatabasePreviewWindow()
        window.setTotalCount(81)
        window.showOlder()

        XCTAssertEqual(window.range, 1..<41)
        window.showNewer()
        XCTAssertEqual(window.range, 41..<81)

        window.showOlder()
        window.reset()
        XCTAssertEqual(window.range, 41..<81)
        XCTAssertFalse(window.canShowNewer)
    }

    func testEmptyAndShortCollectionsNeedNoPagination() {
        var window = DatabasePreviewWindow()
        window.setTotalCount(0)
        XCTAssertEqual(window.range, 0..<0)
        XCTAssertFalse(window.canShowNewer)
        XCTAssertFalse(window.canShowOlder)

        window.setTotalCount(17)
        XCTAssertEqual(window.range, 0..<17)
        XCTAssertFalse(window.canShowNewer)
        XCTAssertFalse(window.canShowOlder)
    }

    func testShrinkingCollectionClampsTheCurrentPage() {
        var window = DatabasePreviewWindow()
        window.setTotalCount(100)
        window.showOlder()
        XCTAssertEqual(window.range, 20..<60)

        window.setTotalCount(25)

        XCTAssertEqual(window.range, 0..<25)
        XCTAssertFalse(window.canShowOlder)
        XCTAssertFalse(window.canShowNewer)
    }
}
