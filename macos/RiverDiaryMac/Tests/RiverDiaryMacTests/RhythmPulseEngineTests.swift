import XCTest
@testable import RiverDiaryMac

@MainActor
final class RhythmPulseEngineTests: XCTestCase {
    func testEmptyDayHasRestingPulse() {
        let date = Self.date("2026-09-07")
        let entry = Self.entry(dateKey: "2026-09-07")
        let stats = ActivityFusionEngine.dayStats(dateKey: "2026-09-07", entry: entry, liveSessions: [])
        let pulse = RhythmPulseEngine.pulse(date: date, entry: entry, stats: stats)

        XCTAssertEqual(pulse.score, 38)
        XCTAssertEqual(pulse.tone, .resting)
        XCTAssertEqual(pulse.topCategory, "安静")
        XCTAssertTrue(pulse.narrative.contains("还没有足够的活动信号"))
    }

    func testFocusedJournalDayProducesBrightPulse() {
        let date = Self.date("2026-09-07")
        let entry = Self.entry(
            dateKey: "2026-09-07",
            daily: "上午连续写作，下午散步。",
            metrics: DayMetrics(mood: 82, energy: 76, focus: 88, output: 80, overall: 82)
        )
        let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date)!
        let session = ActivitySession(
            appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: nil,
            category: "工作", start: start, end: start.addingTimeInterval(2 * 3600)
        )
        let stats = ActivityFusionEngine.dayStats(dateKey: "2026-09-07", entry: entry, liveSessions: [session])
        let pulse = RhythmPulseEngine.pulse(date: date, entry: entry, stats: stats, quickCaptureCount: 2)

        XCTAssertGreaterThanOrEqual(pulse.score, 68)
        XCTAssertLessThanOrEqual(pulse.score, 84)
        XCTAssertEqual(pulse.tone, .bright)
        XCTAssertEqual(pulse.focusMinutes, 120)
        XCTAssertTrue(pulse.narrative.contains("120 分钟专注"))
    }

    func testTrendComparesFirstAndLastPulse() {
        let first = RhythmPulse(
            dateKey: "2026-09-01", score: 64, mood: 70, energy: 60, focus: 70, output: 60,
            focusMinutes: 30, activeMinutes: 90, fragmentation: 40, confidence: 70,
            topCategory: "工作", headline: "一", narrative: "二", tone: .steady
        )
        let last = RhythmPulse(
            dateKey: "2026-09-02", score: 75, mood: 74, energy: 70, focus: 76, output: 72,
            focusMinutes: 60, activeMinutes: 120, fragmentation: 35, confidence: 78,
            topCategory: "创作", headline: "一", narrative: "二", tone: .bright
        )
        XCTAssertEqual(RhythmPulseEngine.trend([first, last]), 11)
        XCTAssertNil(RhythmPulseEngine.trend([first]))
    }

    private static func date(_ value: String) -> Date {
        DiaryEntry.dateFormatter.date(from: value)!
    }

    private static func entry(
        dateKey: String,
        daily: String? = nil,
        metrics: DayMetrics? = nil
    ) -> DiaryEntry {
        DiaryEntry(
            pageID: dateKey,
            date: dateKey,
            score: metrics?.overall ?? 60,
            daily: daily,
            overview: nil,
            thoughts: nil,
            memos: nil,
            tags: nil,
            category: nil,
            metrics: metrics,
            stage: nil
        )
    }
}
