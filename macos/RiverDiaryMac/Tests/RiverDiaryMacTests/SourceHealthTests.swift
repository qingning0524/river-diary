import XCTest
@testable import RiverDiaryMac

final class SourceHealthTests: XCTestCase {
    func testSourceHealthStatesUseExplicitUserFacingLabels() {
        XCTAssertEqual(SourceHealthState.healthy.label, "正常")
        XCTAssertEqual(SourceHealthState.collecting.label, "采集中")
        XCTAssertEqual(SourceHealthState.missing.label, "未知")
        XCTAssertEqual(SourceHealthState.paused.label, "已暂停")
        XCTAssertEqual(SourceHealthState.error.label, "有问题")
    }

    @MainActor
    func testRecentPlaceStatusUsesResolvedName() {
        XCTAssertEqual(LocationSourceStore.recentPlaceDetail("图书馆"), "最近位置：图书馆")
    }
}
