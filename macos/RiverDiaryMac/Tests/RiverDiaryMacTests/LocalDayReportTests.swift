import XCTest
@testable import RiverDiaryMac

final class LocalDayReportTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

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

    func testMainAppHighlightUsesRecordedDurationRatherThanSessionCount() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22))!
        let first = makeSession(hour: 9, calendar: calendar, date: date, appName: "Xcode", bundleID: "com.example.xcode")
        var sessions = [ActivitySession(appName: first.appName, bundleID: first.bundleID, category: first.category, start: first.start, end: first.start.addingTimeInterval(2 * 3600))]
        for hour in 12...16 {
            let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)!
            sessions.append(ActivitySession(
                appName: "Safari", bundleID: "com.example.safari", category: "浏览",
                start: start, end: start.addingTimeInterval(15 * 60)
            ))
        }
        let timeline = ActivityTimelineEngine.build(for: date, sessions: sessions, calendar: calendar)
        let stats = ActivityFusionEngine.dayStats(dateKey: "2026-09-22", entry: nil, liveSessions: sessions)

        let report = LocalDayReportBuilder.make(timeline: timeline, stats: stats, fallback: "", fallbackKind: .noEvidence, calendar: calendar)

        XCTAssertTrue(report.highlights.first?.hasPrefix("主要使用：Xcode") == true)
    }

    func testOneSessionCrossingATimeBucketIsSplitAtTheBoundary() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22))!
        let start = calendar.date(bySettingHour: 4, minute: 30, second: 0, of: date)!
        let session = ActivitySession(
            appName: "Xcode", bundleID: "com.example.xcode", category: "工作",
            start: start, end: start.addingTimeInterval(60 * 60)
        )
        let timeline = ActivityTimelineEngine.build(for: date, sessions: [session], calendar: calendar)
        let stats = ActivityFusionEngine.dayStats(dateKey: "2026-09-22", entry: nil, liveSessions: [session])
        let snapshot = TimelineAnalysisSnapshot.make(timeline: timeline, stats: stats, calendar: calendar)

        XCTAssertEqual(snapshot.timeBuckets.map(\.title), ["凌晨", "上午"])
        XCTAssertEqual(snapshot.timeBuckets[0].duration, 30 * 60, accuracy: 1)
        XCTAssertEqual(snapshot.timeBuckets[1].duration, 30 * 60, accuracy: 1)
    }

    func testManualAnnotationIsTheFirstLinkableInsight() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22))!
        let noteSession = makeSession(hour: 9, calendar: calendar, date: date, appName: "Xcode", bundleID: "com.example.xcode")
        let longerSession = ActivitySession(
            appName: "Safari", bundleID: "com.example.safari", category: "浏览",
            start: calendar.date(bySettingHour: 13, minute: 0, second: 0, of: date)!,
            end: calendar.date(bySettingHour: 15, minute: 0, second: 0, of: date)!
        )
        let annotations = [TimelineAnnotation.key(for: noteSession): TimelineAnnotation(title: "完成河流时间线草图")]
        let timeline = ActivityTimelineEngine.build(
            for: date,
            sessions: [noteSession, longerSession],
            calendar: calendar,
            annotations: annotations
        )
        let stats = ActivityFusionEngine.dayStats(dateKey: "2026-09-22", entry: nil, liveSessions: [noteSession, longerSession])
        let snapshot = TimelineAnalysisSnapshot.make(timeline: timeline, stats: stats, calendar: calendar)

        XCTAssertEqual(snapshot.insights.first?.kind, .userNote)
        XCTAssertEqual(snapshot.insights.first?.title, "完成河流时间线草图")
        XCTAssertTrue(snapshot.insights.first?.evidenceReferences.contains("raw:\(noteSession.id.uuidString)") == true)
    }

    func testLongestSessionAlreadyShownInHeroIsNotRepeatedAsAnObservation() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22))!
        let longest = ActivitySession(
            appName: "ZCode", bundleID: "com.example.zcode", category: "其他",
            start: calendar.date(bySettingHour: 8, minute: 0, second: 0, of: date)!,
            end: calendar.date(bySettingHour: 11, minute: 0, second: 0, of: date)!
        )
        let second = makeSession(hour: 14, calendar: calendar, date: date, appName: "Safari", bundleID: "com.example.safari")
        let annotations = [TimelineAnnotation.key(for: longest): TimelineAnnotation(isReviewed: true)]
        let timeline = ActivityTimelineEngine.build(
            for: date,
            sessions: [longest, second],
            calendar: calendar,
            annotations: annotations
        )
        let stats = ActivityFusionEngine.dayStats(dateKey: "2026-09-22", entry: nil, liveSessions: [longest, second])
        let snapshot = TimelineAnalysisSnapshot.make(timeline: timeline, stats: stats, calendar: calendar)
        let longestItemID = timeline.items.first { $0.sessions.contains(where: { $0.id == longest.id }) }?.id

        XCTAssertFalse(snapshot.insights.contains { $0.itemID == longestItemID && $0.kind == .observation })
    }

    func testCaptureOnlyDayIsReportedAsUserEvidenceNotEmptyData() {
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22))!
        let capture = QuickCapture(text: "在图书馆复习了历史", createdAt: calendar.date(bySettingHour: 20, minute: 10, second: 0, of: date)!)
        let timeline = ActivityTimelineEngine.build(for: date, sessions: [], captures: [capture], calendar: calendar)
        let stats = ActivityFusionEngine.dayStats(dateKey: "2026-09-22", entry: nil, liveSessions: [])
        let report = LocalDayReportBuilder.make(timeline: timeline, stats: stats, fallback: "", fallbackKind: .noEvidence, calendar: calendar)

        XCTAssertEqual(report.kind, .observedFacts)
        XCTAssertEqual(report.insights.first?.kind, .userNote)
        XCTAssertEqual(report.insights.first?.title, capture.text)
        XCTAssertTrue(report.insights.first?.evidenceReferences.contains("capture:\(capture.id.uuidString)") == true)
    }
}
