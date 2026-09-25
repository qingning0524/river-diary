import XCTest
@testable import RiverDiaryMac

final class ProgressComparisonTests: XCTestCase {
    func testTodayProgressAnchorUsesLastCompletedDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 15))!

        let endDate = ProgressAnchor.completedEndDate(selectedDate: today, now: today, calendar: calendar)

        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: endDate),
            DateComponents(year: 2026, month: 9, day: 21)
        )
    }

    func testHistoricalProgressAnchorKeepsSelectedDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let selected = calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 12))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 15))!

        let endDate = ProgressAnchor.completedEndDate(selectedDate: selected, now: now, calendar: calendar)

        XCTAssertEqual(calendar.startOfDay(for: endDate), calendar.startOfDay(for: selected))
    }

    func testProgressWindowsAreAdjacentAndContainRequestedNumberOfDays() {
        let calendar = Calendar(identifier: .gregorian)
        let end = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 12))!
        let current = ProgressWindow(dayCount: 30, endingOn: end, calendar: calendar)
        let previous = current.preceding

        XCTAssertEqual(current.dayCount, 30)
        XCTAssertEqual(previous.dayCount, 30)
        XCTAssertEqual(calendar.date(byAdding: .day, value: 1, to: previous.end), current.start)
        XCTAssertEqual(calendar.dateComponents([.day], from: current.start, to: current.end).day, 29)

        let yearWindow = ProgressWindow(dayCount: 365, endingOn: end, calendar: calendar)
        XCTAssertTrue(yearWindow.spansCalendarYears)
        XCTAssertFalse(current.spansCalendarYears)
    }

    func testMissingMeasurementsRemainUnknownInsteadOfBecomingZero() {
        let date = Date(timeIntervalSince1970: 1_758_153_600)
        let stats = FusedRangeStats(
            days: 1,
            dateKeys: [DiaryEntry.dateFormatter.string(from: date)],
            pipelineTotal: 0,
            liveTotal: 0,
            focusTotal: 0,
            appUsage: [],
            categoryUsage: [],
            browseUsage: [],
            timeline: [],
            liveSessions: [],
            focusSessions: [],
            healthSteps: 0,
            healthDistance: 0,
            healthEnergy: 0,
            conflicts: [],
            fragmentation: 0,
            confidence: 0,
            confidenceFactors: [],
            headline: "",
            narrative: "",
            dayStats: []
        )

        let summary = ProgressPeriodSummary(stats: stats, entries: [], captures: [:])

        XCTAssertNil(summary.focusDuration)
        XCTAssertNil(summary.entertainmentDuration)
        XCTAssertNil(summary.moodAverage)
        XCTAssertNil(summary.averageSteps)
        XCTAssertEqual(summary.recordedDays, 0)
        XCTAssertEqual(summary.moodDays, 0)
        XCTAssertEqual(summary.stepDays, 0)
        XCTAssertEqual(summary.goalDays, 0)
        XCTAssertEqual(summary.completedGoalDays, 0)
    }

    func testPeriodSummaryUsesOnlyScoredAndMeasuredDays() {
        let day = DiaryEntry.dateFormatter.string(from: Date(timeIntervalSince1970: 1_758_153_600))
        let session = ActivitySession(
            appName: "Xcode",
            bundleID: "com.apple.dt.Xcode",
            category: "工作",
            start: Date(timeIntervalSince1970: 1_758_153_600),
            end: Date(timeIntervalSince1970: 1_758_157_200)
        )
        let otherSession = ActivitySession(
            appName: "River Diary",
            bundleID: "studio.riverdiary.mac",
            category: "其他",
            start: Date(timeIntervalSince1970: 1_758_157_200),
            end: Date(timeIntervalSince1970: 1_758_159_000)
        )
        let dayStats = FusedDayStats(
            dateKey: day,
            pipelineAvailable: false,
            pipelineTotal: 0,
            liveTotal: 5400,
            focusTotal: 3600,
            appUsage: [],
            categoryUsage: [
                UsageItem(name: "工作", duration: 3600, count: 1, category: "工作", source: .live),
                UsageItem(name: "其他", duration: 1800, count: 1, category: "其他", source: .live)
            ],
            browseUsage: [],
            timeline: [],
            liveSessions: [session, otherSession],
            focusSessions: [session],
            longestSession: session,
            health: IOSHealthSummary(steps: 8000, distanceKM: nil, activeEnergyKcal: nil, sleepHours: nil, updatedAt: nil),
            conflicts: [],
            fragmentation: 0,
            confidence: 80,
            confidenceFactors: [],
            headline: "",
            narrative: ""
        )
        let stats = FusedRangeStats(
            days: 1,
            dateKeys: [day],
            pipelineTotal: 0,
            liveTotal: 5400,
            focusTotal: 3600,
            appUsage: [],
            categoryUsage: [
                UsageItem(name: "工作", duration: 3600, count: 1, category: "工作", source: .live),
                UsageItem(name: "其他", duration: 1800, count: 1, category: "其他", source: .live)
            ],
            browseUsage: [],
            timeline: [],
            liveSessions: [session, otherSession],
            focusSessions: [session],
            healthSteps: 8000,
            healthDistance: 0,
            healthEnergy: 0,
            conflicts: [],
            fragmentation: 0,
            confidence: 80,
            confidenceFactors: [],
            headline: "",
            narrative: "",
            dayStats: [dayStats]
        )
        let entry = DiaryEntry(
            pageID: "progress-test",
            date: day,
            score: 70,
            daily: nil,
            overview: "留下了一段记录",
            thoughts: [], memos: [], tags: [], category: "随想", metrics: nil, stage: nil,
            screenHours: nil, views: nil, screenApps: [], browseSites: [], screenNote: nil,
            browseNote: nil, didItems: [], health: nil
        )

        let summary = ProgressPeriodSummary(
            stats: stats,
            entries: [entry],
            captures: [:],
            dailyGoals: [day: DailyGoal(title: "推进项目", isCompleted: true)]
        )

        XCTAssertEqual(summary.recordedDays, 1)
        XCTAssertEqual(summary.focusDuration, 3600)
        XCTAssertEqual(summary.unclassifiedDuration, 1800)
        XCTAssertEqual(summary.entertainmentDuration, 0)
        XCTAssertEqual(summary.moodAverage, 70)
        XCTAssertEqual(summary.moodDays, 1)
        XCTAssertEqual(summary.averageSteps, 8000)
        XCTAssertEqual(summary.stepDays, 1)
        XCTAssertEqual(summary.writingDays, 1)
        XCTAssertEqual(summary.goalDays, 1)
        XCTAssertEqual(summary.completedGoalDays, 1)
    }
}
