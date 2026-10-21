import XCTest
@testable import RiverDiaryMac
import RiverDiaryCore

final class SelfReportFactsBridgeTests: XCTestCase {
    private func entry(_ json: String) throws -> DiaryEntry {
        try JSONDecoder().decode(DiaryEntry.self, from: Data(json.utf8))
    }

    func testPrefersPipelineScreenTimeAndMapsHealthAndCompletedItems() throws {
        let value = try entry("""
        {
          "page_id": "p1", "date": "2026-10-22", "screen_h": 9.0,
          "did": [{"sub": "工作", "items": ["回信", "整理表格", " "]}, {"items": ["散步"]}],
          "ios_health": {"sleep_hours": 4.2, "steps": 820}
        }
        """)
        let facts = SelfReportFactsBridge.facts(
            entry: value, pipelineAvailable: true, pipelineTotal: 450 * 60
        )
        XCTAssertEqual(facts.screenMinutes, 450)
        XCTAssertEqual(facts.sleepHours, 4.2)
        XCTAssertEqual(facts.steps, 820)
        XCTAssertEqual(facts.completedItems, 3)
        let message = SelfReportConsistency.observation(
            selfReport: "昨晚睡得很好，今天走了很多，但什么都没做。", facts: facts
        )
        XCTAssertEqual(message?.filter { $0 == "。" }.count, 1)
        XCTAssertTrue(message?.contains("完成事项") == true)
    }

    func testFallsBackToRecordedScreenHoursWithoutPipeline() throws {
        let value = try entry("""
        {"page_id": "p2", "date": "2026-10-22", "screen_h": 7.5}
        """)
        let facts = SelfReportFactsBridge.facts(
            entry: value, pipelineAvailable: false, pipelineTotal: 0
        )
        XCTAssertEqual(facts.screenMinutes, 450)
        XCTAssertNil(facts.sleepHours)
        XCTAssertNil(facts.steps)
        XCTAssertEqual(facts.completedItems, 0)
    }

    func testMissingFactsStayNilInsteadOfZero() throws {
        let value = try entry("""
        {"page_id": "p3", "date": "2026-10-22"}
        """)
        let facts = SelfReportFactsBridge.facts(
            entry: value, pipelineAvailable: true, pipelineTotal: 0
        )
        XCTAssertNil(facts.screenMinutes)
        XCTAssertNil(facts.sleepHours)
        XCTAssertNil(facts.steps)
        XCTAssertEqual(facts.completedItems, 0)
        XCTAssertNil(SelfReportConsistency.observation(selfReport: "今天走了很多。", facts: facts))
    }

    func testEmptyCompletedItemTextIsNotCounted() throws {
        let value = try entry("""
        {"page_id": "p4", "date": "2026-10-22", "did": [{"items": ["", "  "]}]}
        """)
        let facts = SelfReportFactsBridge.facts(
            entry: value, pipelineAvailable: false, pipelineTotal: 0
        )
        XCTAssertEqual(facts.completedItems, 0)
    }
}
