import XCTest
@testable import RiverDiaryMac

final class MoodInsightTests: XCTestCase {
    func testDraftSubstanceScoreGrowsThroughAllThreeTiers() {
        XCTAssertEqual(AIDraftEngine.draftSubstanceScore(29), 0)
        XCTAssertEqual(AIDraftEngine.draftSubstanceScore(30), 10)
        XCTAssertEqual(AIDraftEngine.draftSubstanceScore(120), 18)
        XCTAssertEqual(AIDraftEngine.draftSubstanceScore(300), 22)
        XCTAssertEqual(AIDraftEngine.draftSubstanceScore(301), 22)
    }

    func testDraftSubstanceScoreKeepsBoundaryValues() {
        XCTAssertEqual(AIDraftEngine.draftSubstanceScore(119), 10)
        XCTAssertEqual(AIDraftEngine.draftSubstanceScore(299), 18)
    }
}
