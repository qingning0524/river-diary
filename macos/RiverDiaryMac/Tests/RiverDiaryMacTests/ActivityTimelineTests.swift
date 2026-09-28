import XCTest
@testable import RiverDiaryMac

final class ActivityTimelineTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 15))! }
    private func at(_ minutes: Double) -> Date { day.addingTimeInterval(minutes * 60) }
    private func session(_ start: Double, _ end: Double, app: String = "Xcode", category: String = "工作", title: String? = nil) -> ActivitySession {
        ActivitySession(appName: app, bundleID: "test.\(app)", windowTitle: title, category: category, start: at(start), end: at(end))
    }
    private func build(_ sessions: [ActivitySession], captures: [QuickCapture] = [], grouped: Bool = true) -> ActivityTimeline {
        ActivityTimelineEngine.build(for: day, sessions: sessions, captures: captures, grouped: grouped, calendar: calendar)
    }

    func testActivityTimelineItemCanBePersistedAsAnExactAnalysisRecoveryInput() throws {
        let source = session(600, 630, title: "RiverDiaryMac.swift")
        let item = ActivityTimelineItem(
            id: "candidate-1", kind: .activity, start: source.start, end: source.end,
            sessions: [source], annotationKey: "episode:test",
            annotation: TimelineAnnotation(title: "开发", note: "用户标注")
        )

        let bytes = try JSONEncoder().encode(item)
        let restored = try JSONDecoder().decode(ActivityTimelineItem.self, from: bytes)
        XCTAssertEqual(restored, item)
    }

    func testClipsBothMidnightBoundariesAndDropsInvalidSessions() {
        let model = build([session(-20, 20), session(1430, 1500), session(30, 20), session(60, 60), session(-60, -30)])
        XCTAssertEqual(model.totalDuration, 30 * 60)
        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertEqual(model.sessions.first?.start, day)
        XCTAssertEqual(model.sessions.last?.end, at(1440))
    }

    func testDuplicateAndOverlappingImportsNeverDoubleCount() {
        let first = session(600, 630)
        let model = build([first, session(620, 650, app: "Safari"), first])
        XCTAssertEqual(model.totalDuration, 50 * 60)
        XCTAssertEqual(model.sessions.count, 2)
        XCTAssertEqual(model.sessions[1].start, at(630))
    }

    func testDayIntervalUsesCalendarLengthAcrossDSTTransitions() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let springDay = newYork.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let fallDay = newYork.date(from: DateComponents(year: 2026, month: 11, day: 1))!

        let spring = ActivityTimelineEngine.build(for: springDay, sessions: [], calendar: newYork)
        let fall = ActivityTimelineEngine.build(for: fallDay, sessions: [], calendar: newYork)

        XCTAssertEqual(spring.dayInterval.duration, 23 * 3600)
        XCTAssertEqual(fall.dayInterval.duration, 25 * 3600)
    }

    func testGroupsNearbySameCategoryButPreservesRawEvidence() {
        let source = [session(600, 610), session(611, 630, app: "Terminal")]
        let model = build(source)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items.first?.sessions.count, 2)
        XCTAssertEqual(model.items.first?.duration, 29 * 60)
        XCTAssertEqual(model.items.first?.end, at(630))
        XCTAssertEqual(build(source, grouped: false).items.count, 2)
        XCTAssertEqual(build(source.reversed()).items, model.items)
    }

    func testLongestFocusUsesRecordedDurationRatherThanGroupedSpan() {
        let model = build([session(600, 610), session(612, 622)])

        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items[0].span, 22 * 60)
        XCTAssertEqual(model.items[0].duration, 20 * 60)
        XCTAssertEqual(model.longestFocusSpan, 20 * 60)
    }

    func testCategoryChangesLongGapsAndLongBlocksStaySeparate() {
        let model = build([
            session(600, 620), session(620, 640, app: "Slack", category: "沟通"),
            session(640, 680), session(681, 690), session(720, 730)
        ])
        XCTAssertEqual(model.items.filter { $0.kind == .activity }.count, 5)
        XCTAssertEqual(model.items.filter { $0.kind == .gap }.count, 1)
        let gap = model.items.first { $0.kind == .gap }
        XCTAssertEqual(gap?.start, at(690))
        XCTAssertEqual(gap?.end, at(720))
        XCTAssertEqual(model.totalDuration, 99 * 60)
    }

    func testQuickNotesAreChronologicalAndDoNotAddScreenTime() {
        let note = QuickCapture(text: "休息一会儿", createdAt: at(650))
        let model = build([session(600, 630), session(680, 700)], captures: [note])
        XCTAssertEqual(model.items.map(\.kind), [.activity, .gap, .capture, .activity])
        XCTAssertEqual(model.totalDuration, 50 * 60)
        XCTAssertEqual(model.items.first { $0.kind == .capture }?.capture, note)
    }

    func testRemoteLocationMarkersJoinThePersonTimelineWithoutAddingScreenTime() {
        let marker = ActivityTimelinePlaceMarker(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            time: at(590),
            title: "到达 学校",
            detail: "大学 · 来自 iphone_test",
            originDeviceID: "iphone_test"
        )
        let timeline = ActivityTimelineEngine.build(
            for: day,
            sessions: [session(600, 630, app: "ChatGPT")],
            placeMarkers: [marker],
            calendar: calendar
        )

        XCTAssertEqual(timeline.items.map(\.kind), [.place, .activity])
        XCTAssertEqual(timeline.items.first?.title, "到达 学校")
        XCTAssertEqual(timeline.items.first?.evidenceRef, "raw:\(marker.id.uuidString)")
        XCTAssertEqual(timeline.totalDuration, 30 * 60)
    }

    func testBackdatedDiaryNoteIsKeptOutsideTheClockTimeline() {
        let note = QuickCapture(text: "补记昨天的散步", createdAt: at(1500))
        let model = build([], captures: [note])
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.retrospectiveCaptures, [note])
        XCTAssertTrue(ActivityTimelineExport.markdown(model).contains("补记昨天的散步"))

        let stats = ActivityFusionEngine.dayStats(dateKey: "2026-09-15", entry: nil, liveSessions: [])
        let analysis = TimelineAnalysisSnapshot.make(timeline: model, stats: stats, calendar: calendar)
        XCTAssertTrue(analysis.insights.isEmpty, "补记没有发生时刻，不能被当作当日时间线事件")
    }

    func testSearchMatchesEveryWindowTitleAndCombinesWithCategory() {
        let model = build([session(600, 610), session(610, 630, app: "Terminal", title: "Fix TIMELINE layout")])
        let item = model.items[0]
        XCTAssertTrue(item.matches(query: " timeline ", category: "工作"))
        XCTAssertFalse(item.matches(query: "timeline", category: "娱乐"))
        XCTAssertTrue(item.matches(query: "terminal", category: nil))
    }

    func testExportContainsOriginalEvidenceAndExplicitGaps() {
        let model = build([session(600, 630, title: "河流界面"), session(660, 690)], captures: [QuickCapture(text: "今天很平静", createdAt: at(640))])
        let text = ActivityTimelineExport.markdown(model)
        XCTAssertTrue(text.contains("河流界面"))
        XCTAssertTrue(text.contains("今天很平静"))
        XCTAssertTrue(text.contains("没有记录的时间"))
        XCTAssertTrue(text.contains("Xcode"))
    }

    func testStableSelectionIdentityAsActiveSessionGrows() {
        var live = session(600, 610)
        let original = build([live]).items[0].id
        live.end = at(620)
        XCTAssertEqual(build([live]).items[0].id, original)
    }

    func testLockScreenDoesNotBecomeThirteenHoursOfDiaryActivity() {
        let locked = session(0, 790, app: "loginwindow", category: "其他")
        let model = build([locked, session(790, 820)])
        XCTAssertEqual(model.totalDuration, 30 * 60)
        XCTAssertFalse(model.items.contains { $0.title.contains("loginwindow") })
        let summary = ActivityFusionEngine.dayStats(dateKey: "2026-09-15", entry: nil, liveSessions: [locked, session(790, 820)])
        XCTAssertEqual(summary.liveTotal, 30 * 60)
    }

    func testDayClippingUsesCalendarAcrossDaylightSaving() {
        var la = calendar
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = la.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let interval = la.dateInterval(of: .day, for: date)!
        XCTAssertEqual(interval.duration, 23 * 3600)
        let source = ActivitySession(appName: "Xcode", bundleID: "", category: "工作", start: date.addingTimeInterval(-3600), end: interval.end.addingTimeInterval(3600))
        let model = ActivityTimelineEngine.build(for: date, sessions: [source], calendar: la)
        XCTAssertEqual(model.totalDuration, 23 * 3600)
        XCTAssertEqual(model.sessions.first?.end, interval.end)
    }
}
