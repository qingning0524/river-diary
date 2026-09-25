import XCTest
@testable import RiverDiaryMac

final class LocalDayReportTests: XCTestCase {
    func testDiaryFallbackIsNeverLabeledAsObservedFacts() {
        let kind = LocalDayReportKind.resolve(
            hasObservedActivities: false,
            fallbackKind: LocalDayReportKind.fallbackKind(hasDiaryContent: true, hasSourceSnapshot: false)
        )

        XCTAssertEqual(kind, .diaryArchive)
        XCTAssertEqual(kind.title, "日记档案")
        XCTAssertTrue(kind.sourceLine.contains("未由本页实时片段验证"))
    }

    func testObservedActivityOverridesArchiveFallbackClassification() {
        let fallback = LocalDayReportKind.fallbackKind(hasDiaryContent: true, hasSourceSnapshot: false)

        XCTAssertEqual(LocalDayReportKind.resolve(hasObservedActivities: true, fallbackKind: fallback), .observedFacts)
    }

    func testEmptyAndSourceSnapshotFallbacksStayDistinct() {
        XCTAssertEqual(LocalDayReportKind.fallbackKind(hasDiaryContent: false, hasSourceSnapshot: true), .sourceSnapshot)
        XCTAssertEqual(LocalDayReportKind.fallbackKind(hasDiaryContent: false, hasSourceSnapshot: false), .noEvidence)
    }

    func testObservedDaySummaryListsTimeBucketsChronologicallyAcrossMidnight() throws {
        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22))!
        let sessions = [
            makeSession(hour: 1, calendar: calendar, date: date, appName: "Xcode", bundleID: "com.apple.dt.Xcode"),
            makeSession(hour: 10, calendar: calendar, date: date, appName: "Xcode", bundleID: "com.apple.dt.Xcode"),
            makeSession(hour: 14, calendar: calendar, date: date, appName: "Google Chrome", bundleID: "com.google.Chrome")
        ]
        let timeline = ActivityTimelineEngine.build(for: date, sessions: sessions, calendar: calendar)
        let stats = FusedDayStats(
            dateKey: DiaryEntry.dateFormatter.string(from: date),
            pipelineAvailable: false,
            pipelineTotal: 0,
            liveTotal: timeline.totalDuration,
            focusTotal: 0,
            appUsage: [],
            categoryUsage: [],
            browseUsage: [],
            timeline: [],
            liveSessions: sessions,
            focusSessions: [],
            longestSession: nil,
            health: nil,
            conflicts: [],
            fragmentation: 0,
            confidence: 0,
            confidenceFactors: [],
            headline: "",
            narrative: ""
        )

        let report = LocalDayReportBuilder.make(
            timeline: timeline,
            stats: stats,
            fallback: "",
            fallbackKind: .noEvidence
        )
        let midnight = try XCTUnwrap(report.overview.range(of: "凌晨 "))
        let morning = try XCTUnwrap(report.overview.range(of: "上午 "))
        let afternoon = try XCTUnwrap(report.overview.range(of: "下午 "))

        XCTAssertLessThan(midnight.lowerBound, morning.lowerBound)
        XCTAssertLessThan(morning.lowerBound, afternoon.lowerBound)
    }

    private func makeSession(hour: Int, calendar: Calendar, date: Date, appName: String, bundleID: String) -> ActivitySession {
        let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)!
        return ActivitySession(
            appName: appName,
            bundleID: bundleID,
            category: "工作",
            start: start,
            end: start.addingTimeInterval(600)
        )
    }
}
