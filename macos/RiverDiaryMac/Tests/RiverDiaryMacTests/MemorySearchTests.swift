import XCTest
@testable import RiverDiaryMac

final class MemorySearchTests: XCTestCase {
    private func entry(
        date: Date,
        overview: String,
        score: Int
    ) -> DiaryEntry {
        DiaryEntry(
            pageID: UUID().uuidString,
            date: DiaryEntry.dateFormatter.string(from: date),
            score: Double(score),
            daily: nil,
            overview: overview,
            thoughts: [],
            memos: [],
            tags: [],
            category: "随想",
            metrics: nil,
            stage: nil,
            screenHours: nil,
            views: nil,
            screenApps: [],
            browseSites: [],
            screenNote: nil,
            browseNote: nil,
            didItems: [],
            health: nil
        )
    }

    func testNaturalLanguageKeywordFiltersDiaries() {
        let work = entry(date: Date(), overview: "全天专注工作，会议比较多。", score: 72)
        let rest = entry(date: Date(), overview: "散步和休息，读了几页书。", score: 70)
        let answer = MemorySearchEngine.search("工作", entries: [work, rest])

        XCTAssertEqual(answer.usedFilters, ["主题：工作"])
        XCTAssertEqual(answer.entries.first?.id, work.id)
        XCTAssertEqual(answer.notes.count, 1)
    }

    func testMonthAndThresholdFiltersAreReportedAndApplied() {
        let calendar = Calendar.current
        let monthStart = calendar.dateInterval(of: .month, for: Date())!.start
        let monthEnd = calendar.date(byAdding: DateComponents(day: -1, second: -1), to: calendar.dateInterval(of: .month, for: monthStart)!.end)!
        let lowWork = entry(date: monthStart, overview: "工作很吃力。", score: 35)
        let highWork = entry(date: monthEnd, overview: "工作推进顺利。", score: 72)

        let answer = MemorySearchEngine.search("本月低于40 工作", entries: [lowWork, highWork])

        XCTAssertEqual(answer.usedFilters, ["本月", "综合低于 40", "主题：工作"])
        XCTAssertEqual(answer.entries.count, 1)
        XCTAssertEqual(answer.entries.first?.id, lowWork.id)
    }

    func testLastWeekFilterUsesThePreviousWeekRange() {
        let calendar = Calendar.current
        let previousWeekInterval = calendar.dateInterval(of: .weekOfYear, for: Date().addingTimeInterval(-7 * 86400))!
        let lastWeek = entry(date: previousWeekInterval.start, overview: "工作很专注。", score: 70)
        let now = entry(date: Date(), overview: "工作很专注。", score: 70)

        let answer = MemorySearchEngine.search("上周 工作", entries: [lastWeek, now])

        XCTAssertEqual(answer.usedFilters, ["上周", "主题：工作"])
        XCTAssertEqual(answer.entries.count, 1)
        XCTAssertEqual(answer.entries.first?.id, lastWeek.id)
    }
}

final class MemorySearchWeekBoundaryTests: XCTestCase {
    func testLastWeekDoesNotIncludeCurrentWeekStartAtMidnight() {
        let calendar = Calendar.current
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: Date())!.start
        let previousWeek = calendar.date(byAdding: .day, value: -7, to: currentWeekStart)!
        let previousEntry = DiaryEntry(
            pageID: "previous",
            date: DiaryEntry.dateFormatter.string(from: previousWeek),
            score: 70,
            daily: nil,
            overview: "工作很专注。",
            thoughts: nil,
            memos: nil,
            tags: [],
            category: "随想",
            metrics: nil,
            stage: nil
        )
        let currentEntry = DiaryEntry(
            pageID: "current",
            date: DiaryEntry.dateFormatter.string(from: currentWeekStart),
            score: 70,
            daily: nil,
            overview: "工作很专注。",
            thoughts: nil,
            memos: nil,
            tags: [],
            category: "随想",
            metrics: nil,
            stage: nil
        )

        let answer = MemorySearchEngine.search("上周 工作", entries: [previousEntry, currentEntry])
        XCTAssertEqual(answer.entries.map(\.id), [previousEntry.id])
    }
}
