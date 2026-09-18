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

    func testNaturalLanguageQuestionFindsFatigueSignal() {
        let tired = entry(date: Date(), overview: "今天很累，晚上只想早点睡。", score: 35)
        let calm = entry(date: Date(), overview: "今天很平静，慢慢收尾。", score: 70)

        let answer = MemorySearchEngine.search("哪几天很累？", entries: [tired, calm])

        XCTAssertEqual(answer.entries.map(\.id), [tired.id])
        XCTAssertTrue(answer.usedFilters.contains("主题：疲惫"))
    }

    func testThresholdQuestionDoesNotTreatQuestionScaffoldingAsTopic() {
        let low = entry(date: Date(), overview: "今天有点沉重。", score: 35)
        let high = entry(date: Date(), overview: "今天状态不错。", score: 75)

        let answer = MemorySearchEngine.search("低于40有哪几天？", entries: [low, high])

        XCTAssertEqual(answer.entries.map(\.id), [low.id])
        XCTAssertEqual(answer.usedFilters, ["综合低于 40"])
    }

    func testQuestionScaffoldingLeavesTheActualTopicWord() {
        let work = entry(date: Date(), overview: "今天提到工作安排。", score: 70)
        let rest = entry(date: Date(), overview: "今天去散步，心情平静。", score: 70)

        let answer = MemorySearchEngine.search("本月提到工作了吗？", entries: [work, rest])

        XCTAssertEqual(answer.entries.map(\.id), [work.id])
        XCTAssertTrue(answer.usedFilters.contains("本月"))
        XCTAssertTrue(answer.usedFilters.contains("主题：工作"))
    }

    func testAISearchDateReferencesBecomeClickableDailyTargets() {
        let work = entry(date: Date(), overview: "今天集中处理工作。", score: 72)
        let capture = QuickCapture(text: "补记一个想法", createdAt: Date())
        let answer = """
        **结论**
        我注意到相关内容集中在最近几天。
        **相关日期**
        - \(work.date)：工作记录
        - \(DiaryEntry.dateFormatter.string(from: capture.createdAt))：补记
        **证据**
        - \(work.date) · 来源：日记
        **边界**
        相关性不代表因果关系。如果你想，可以继续查看。
        """

        let references = AISearchDateReferenceParser.references(
            from: answer,
            entries: [work],
            quickCaptures: [capture]
        )

        XCTAssertEqual(references.map(\.date), [work.date])
        XCTAssertEqual(references.first?.source, "日记")
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
