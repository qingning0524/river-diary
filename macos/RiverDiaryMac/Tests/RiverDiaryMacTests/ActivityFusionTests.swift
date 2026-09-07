import XCTest
@testable import RiverDiaryMac

final class ActivityFusionTests: XCTestCase {
    private func session(
        app: String,
        bundle: String = "com.example.\(UUID().uuidString)",
        minutes: TimeInterval,
        start: Date = Date()
    ) -> ActivitySession {
        ActivitySession(
            appName: app,
            bundleID: bundle,
            windowTitle: nil,
            category: ActivityClassifier.category(appName: app, title: nil),
            start: start,
            end: start.addingTimeInterval(minutes * 60)
        )
    }

    private func entry(
        date: String = "2026-09-04",
        screenHours: Double? = nil,
        apps: [ScreenAppUsage] = [],
        health: IOSHealthSummary? = nil
    ) -> DiaryEntry {
        DiaryEntry(
            pageID: UUID().uuidString,
            date: date,
            score: 70,
            daily: nil,
            overview: "平稳推进",
            thoughts: [],
            memos: [],
            tags: [],
            category: "工作",
            metrics: DayMetrics(mood: 72, energy: 68, focus: 75, output: 70, overall: 71),
            stage: nil,
            screenHours: screenHours,
            views: nil,
            screenApps: apps,
            browseSites: nil,
            screenNote: nil,
            browseNote: nil,
            didItems: nil,
            health: health
        )
    }

    func testSingleMinuteLiveSessionDoesNotInflateConfidence() {
        let entry = entry(
            screenHours: 6,
            apps: [
                ScreenAppUsage(app: "Xcode", time: nil, minutes: 200),
                ScreenAppUsage(app: "Safari", time: nil, minutes: 160)
            ]
        )
        let result = ActivityConfidenceEngine.day(entry: entry, liveSessions: [session(app: "Xcode", minutes: 1)])

        XCTAssertLessThan(result.score, 80, "一分钟实时片段不应撑起高置信度")
        XCTAssertEqual(result.factors.count, 5)
        XCTAssertTrue(result.factors.allSatisfy { $0.value <= $0.maximum })
    }

    func testEmptySignalsHaveZeroConfidence() {
        let result = ActivityConfidenceEngine.day(entry: nil, liveSessions: [])
        XCTAssertEqual(result.score, 0)
        XCTAssertEqual(result.factors.reduce(0) { $0 + $1.value }, 0)
    }

    func testDualSourcesGetHigherConfidenceThanSingleMinuteEvidence() {
        let entry = entry(
            screenHours: 4,
            apps: [
                ScreenAppUsage(app: "Xcode", time: nil, minutes: 120),
                ScreenAppUsage(app: "Safari", time: nil, minutes: 120)
            ]
        )
        let live = [
            session(app: "Xcode", minutes: 120, start: Date().addingTimeInterval(-3 * 3600)),
            session(app: "Safari", minutes: 120, start: Date().addingTimeInterval(-90 * 60))
        ]

        let dual = ActivityConfidenceEngine.day(entry: entry, liveSessions: live)
        let minute = ActivityConfidenceEngine.day(entry: entry, liveSessions: [session(app: "Xcode", minutes: 1)])

        XCTAssertGreaterThan(dual.score, minute.score + 12)
        XCTAssertLessThanOrEqual(dual.score, 100)
    }

    func testLiveDurationDoesNotDoubleAddWhenPipelineAppDetailIsComplete() {
        let entry = entry(
            screenHours: 2,
            apps: [ScreenAppUsage(app: "Xcode", time: nil, minutes: 120)]
        )
        let stats = ActivityFusionEngine.dayStats(
            dateKey: "2026-09-04",
            entry: entry,
            liveSessions: [session(app: "Xcode", minutes: 30)]
        )

        XCTAssertEqual(stats.appUsage.first?.duration ?? 0, 7200, accuracy: 1)
        XCTAssertEqual(stats.appUsage.reduce(0) { $0 + $1.duration }, 7200, accuracy: 1)
        XCTAssertEqual(stats.appUsage.first?.source, ActivitySourceKind.fused)
    }

    func testUnmatchedLiveFillsUnattributedPipelineTimeWithoutExceedingTotal() {
        let entry = entry(
            screenHours: 2,
            apps: [ScreenAppUsage(app: "Xcode", time: nil, minutes: 80)]
        )
        let stats = ActivityFusionEngine.dayStats(
            dateKey: "2026-09-04",
            entry: entry,
            liveSessions: [session(app: "Safari", minutes: 30)]
        )

        XCTAssertEqual(stats.appUsage.reduce(0) { $0 + $1.duration }, 6600, accuracy: 1)
    }

    func testRangeConfidencePenalizesSparseCoverage() {
        let empty = ActivityFusionEngine.dayStats(dateKey: "2026-09-01", entry: nil, liveSessions: [])
        let strong = ActivityFusionEngine.dayStats(
            dateKey: "2026-09-02",
            entry: entry(screenHours: 4),
            liveSessions: [session(app: "Xcode", minutes: 240)]
        )
        let range = ActivityFusionEngine.rangeStats(dayStats: [empty, strong], days: 2)

        XCTAssertGreaterThan(range.confidence, 0)
        XCTAssertLessThan(range.confidence, strong.confidence)
        XCTAssertEqual(range.confidenceFactors.count, 5)
    }
}
