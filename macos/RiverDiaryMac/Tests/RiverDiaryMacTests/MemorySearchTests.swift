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

    func testLocationQuestionIntentRecognizesKnownPlaceNamesOnly() {
        XCTAssertTrue(AskQuestionIntent.asksAboutKnownPlace("哪天去了图书馆？"))
        XCTAssertTrue(AskQuestionIntent.asksAboutKnownPlace("在咖啡馆学习过吗？"))
        XCTAssertFalse(AskQuestionIntent.asksAboutKnownPlace("哪天比较专注？"))
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

    func testThisDayQuestionUsesSelectedDateInsteadOfSearchingAllHistory() {
        let calendar = Calendar(identifier: .gregorian)
        let selectedDate = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 12))!
        let matching = entry(date: selectedDate, overview: "今天推进了河流日记。", score: 75)
        let unrelated = entry(
            date: calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 12))!,
            overview: "今天去了图书馆。",
            score: 65
        )

        let answer = MemorySearchEngine.search(
            "这一天做了什么？",
            entries: [matching, unrelated],
            referenceDate: selectedDate
        )

        XCTAssertEqual(answer.entries.map(\.id), [matching.id])
        XCTAssertEqual(answer.usedFilters, ["所选日期"])
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

    func testManualTimelinePlaceAnnotationIsSearchable() {
        let date = Date()
        let session = ActivitySession(
            appName: "Google Chrome",
            bundleID: "com.google.Chrome",
            windowTitle: "资料整理",
            category: "浏览",
            start: date,
            end: date.addingTimeInterval(1800)
        )
        let annotation = TimelineAnnotation(placeName: "图书馆", activityLabel: "学习", isReviewed: true)
        let answer = MemorySearchEngine.search(
            "哪天去了图书馆？",
            entries: [],
            timelineAnnotations: [TimelineAnnotation.key(for: session): annotation],
            sessions: [session]
        )

        XCTAssertEqual(answer.manualNotes.count, 1)
        XCTAssertTrue(answer.manualNotes[0].text.contains("图书馆"))
        XCTAssertTrue(answer.summary.contains("人工补充证据"))
    }

    func testDailyGoalsAreSearchableAsUserAuthoredEvidence() {
        let day = "2026-09-22"
        let goal = DailyGoal(title: "完成河流日报的证据面板", isCompleted: true)

        let answer = MemorySearchEngine.search(
            "2026-09-22 的目标是什么？",
            entries: [],
            dailyGoals: [day: goal]
        )

        XCTAssertEqual(answer.manualNotes.count, 1)
        XCTAssertTrue(answer.manualNotes[0].text.contains(goal.title))
        XCTAssertTrue(answer.manualNotes[0].text.contains("已由用户确认完成"))
        XCTAssertEqual(answer.manualNotes[0].tags, ["每日目标"])
        XCTAssertTrue(answer.summary.contains("人工补充证据"))
    }

    func testAskAICandidateTextRetainsManualLocationAndGoalProvenance() {
        let notes = [
            MemoryNote(id: "place-1", date: "2026-09-21", text: "图书馆 · 学习", tags: ["时间线标注"], signal: nil, score: 0),
            MemoryNote(id: "goal-1", date: "2026-09-22", text: "每日目标：推进日报 · 进行中", tags: ["每日目标"], signal: "目标", score: 0)
        ]

        let context = AskCandidateContextFormatter.manualNotes(notes)

        XCTAssertTrue(context.contains("时间线标注"))
        XCTAssertTrue(context.contains("图书馆 · 学习"))
        XCTAssertTrue(context.contains("每日目标"))
        XCTAssertTrue(context.contains("2026-09-22"))

        let references = AskCandidateContextFormatter.manualNoteReferences(notes)
        XCTAssertEqual(references[0]["kind"], "timeline_annotation")
        XCTAssertEqual(references[1]["kind"], "goal")
        XCTAssertNil(references[0]["text"])
        XCTAssertNil(references[1]["text"])
    }

    func testSearchIncludesDurableMemoriesAndSavedReflections() {
        let memory = Memory(title: "持续的专注项目", body: "最近反复回到 River 的设计", kind: .projectTrajectory)
        let reflection = MonthlyLetter(
            month: "2026-09",
            title: "九月河流信",
            body: "我把更多时间留给了专注工作。",
            evidence: "3 天日记",
            createdAt: Date(),
            updatedAt: Date()
        )

        let answer = MemorySearchEngine.search(
            "专注",
            entries: [],
            quickCaptures: [],
            memories: [memory],
            reflections: [reflection]
        )

        XCTAssertEqual(answer.memories.map(\.id), [memory.id])
        XCTAssertEqual(answer.reflections.map(\.id), [reflection.id])
        XCTAssertTrue(answer.summary.contains("长期记忆"))
        XCTAssertTrue(answer.summary.contains("河流信"))
    }

    func testThisWeekScopeAppliesToArchiveMemoryAndReflection() {
        let calendar = Calendar.current
        let week = calendar.dateInterval(of: .weekOfYear, for: Date())!
        let currentDate = week.start.addingTimeInterval(3600)
        let previousDate = week.start.addingTimeInterval(-86400)
        let current = entry(date: currentDate, overview: "这周专注设计。", score: 80)
        let previous = entry(date: previousDate, overview: "上周专注设计。", score: 80)
        let episode = Episode(startTime: currentDate, endTime: currentDate.addingTimeInterval(1800), title: "本周设计", category: .work)
        let memory = Memory(title: "专注项目", body: "持续推进", kind: .projectTrajectory, sourceEpisodeIDs: [episode.id], createdAt: previousDate)
        let currentLetter = MonthlyLetter(month: DiaryEntry.dateFormatter.string(from: currentDate).prefix(7).description, title: "本月信", body: "专注", evidence: "", createdAt: currentDate, updatedAt: currentDate)
        let oldLetter = MonthlyLetter(month: "2020-01", title: "旧信", body: "专注", evidence: "", createdAt: previousDate, updatedAt: previousDate)

        let answer = MemorySearchEngine.search(
            "这周 专注",
            entries: [current, previous],
            memories: [memory],
            reflections: [currentLetter, oldLetter],
            sourceEpisodes: [memory.id.uuidString: [episode]]
        )

        XCTAssertEqual(answer.entries.map(\.id), [current.id])
        XCTAssertEqual(answer.memories.map(\.id), [memory.id])
        XCTAssertEqual(answer.reflections.map(\.id), [currentLetter.id])
        XCTAssertTrue(answer.usedFilters.contains("本周"))
    }

    func testRecentArbitraryDayCountIsNotRoundedToSeven() {
        let now = Date()
        let inside = entry(date: now.addingTimeInterval(-10 * 86_400), overview: "最近的工作", score: 70)
        let outside = entry(date: now.addingTimeInterval(-20 * 86_400), overview: "更早的工作", score: 70)
        let answer = MemorySearchEngine.search("最近14天 工作", entries: [inside, outside])
        XCTAssertEqual(answer.entries.map(\.id), [inside.id])
        XCTAssertTrue(answer.usedFilters.contains("最近 14 天"))
    }

    func testDateRangeIncludesEpisodeCrossingTheBoundary() {
        let formatter = DiaryEntry.dateFormatter
        let start = formatter.date(from: "2026-09-10")!
        let crossing = Episode(startTime: start.addingTimeInterval(-3600), endTime: start.addingTimeInterval(3600), title: "跨界片段")
        let memory = Memory(title: "跨界记忆", body: "工作", sourceEpisodeIDs: [crossing.id])
        let answer = MemorySearchEngine.search(
            "2026-09-10 到 2026-09-10 工作",
            entries: [],
            memories: [memory],
            sourceEpisodes: [memory.id.uuidString: [crossing]]
        )
        XCTAssertEqual(answer.memories.map(\.id), [memory.id])
        XCTAssertTrue(answer.usedFilters.contains("2026-09-10 – 2026-09-10"))
    }

    func testAskCandidateSetUsesCanonicalCapsWithoutDroppingCaptures() {
        let entries = (0..<30).map { index in
            entry(date: Date(timeIntervalSince1970: TimeInterval(index)), overview: "日记 \(index)", score: 70)
        }
        let captures = (0..<20).map { index in
            QuickCapture(text: "快记 \(index)", createdAt: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        let memories = (0..<16).map { index in
            Memory(title: "记忆 \(index)", body: "内容", createdAt: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        let reflections = (0..<16).map { index in
            MonthlyLetter(month: String(format: "2025-%02d", index % 12 + 1), title: "河流信 \(index)", body: "内容", evidence: "来源", createdAt: Date(timeIntervalSince1970: TimeInterval(index)), updatedAt: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        let manualNotes = (0..<40).map { index in
            MemoryNote(id: "manual-\(index)", date: String(format: "2026-09-%02d", index % 30 + 1), text: "地点标注 \(index)", tags: ["时间线标注"], signal: nil, score: 0)
        }
        let answer = MemoryAnswer(
            summary: "",
            entries: entries,
            notes: (0..<12).map { MemoryNote(id: "diary-note-\($0)", date: "2026-09-20", text: "片段", tags: [], signal: nil, score: 70) },
            usedFilters: [],
            memories: memories,
            reflections: reflections,
            matchedCaptures: captures,
            manualNotes: manualNotes
        )

        let candidates = AskCandidateSet.make(from: answer)
        let expectedEntries = Array(entries.sorted { lhs, rhs in
            lhs.date == rhs.date ? lhs.id < rhs.id : lhs.date < rhs.date
        }.prefix(24))
        XCTAssertEqual(candidates.entries.count, 24)
        XCTAssertEqual(candidates.captures.count, 12)
        XCTAssertEqual(candidates.memories.count, 12)
        XCTAssertEqual(candidates.reflections.count, 12)
        XCTAssertEqual(candidates.manualNotes.count, 24)
        XCTAssertEqual(candidates.captures.first?.text, "快记 0")
        XCTAssertEqual(candidates.entries, expectedEntries)
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
