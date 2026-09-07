import Foundation
@testable import RiverDiaryMac

enum ActivityFusionVerification {
    static func run() {
        verifySingleMinuteLiveSessionDoesNotInflateConfidence()
        verifyEmptySignalsHaveZeroConfidence()
        verifyDualSourcesGetHigherConfidenceThanSingleMinuteEvidence()
        verifyLiveDurationDoesNotDoubleAddWhenPipelineAppDetailIsComplete()
        verifyUnmatchedLiveFillsUnattributedPipelineTimeWithoutExceedingTotal()
        verifyRangeConfidencePenalizesSparseCoverage()
        print("Activity fusion verification passed.")
    }

    private static func session(
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

    private static func entry(
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

    private static func verifySingleMinuteLiveSessionDoesNotInflateConfidence() {
        let item = entry(
            screenHours: 6,
            apps: [
                ScreenAppUsage(app: "Xcode", time: nil, minutes: 200),
                ScreenAppUsage(app: "Safari", time: nil, minutes: 160)
            ]
        )
        let result = ActivityConfidenceEngine.day(entry: item, liveSessions: [session(app: "Xcode", minutes: 1)])

        precondition(result.score < 80, "一分钟实时片段不应撑起高置信度")
        precondition(result.factors.count == 5)
        precondition(result.factors.allSatisfy { $0.value <= $0.maximum })
    }

    private static func verifyEmptySignalsHaveZeroConfidence() {
        let result = ActivityConfidenceEngine.day(entry: nil, liveSessions: [])
        precondition(result.score == 0)
        precondition(result.factors.reduce(0) { $0 + $1.value } == 0)
    }

    private static func verifyDualSourcesGetHigherConfidenceThanSingleMinuteEvidence() {
        let item = entry(
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

        let dual = ActivityConfidenceEngine.day(entry: item, liveSessions: live)
        let minute = ActivityConfidenceEngine.day(entry: item, liveSessions: [session(app: "Xcode", minutes: 1)])

        precondition(dual.score > minute.score + 12)
        precondition(dual.score <= 100)
    }

    private static func verifyLiveDurationDoesNotDoubleAddWhenPipelineAppDetailIsComplete() {
        let item = entry(screenHours: 2, apps: [ScreenAppUsage(app: "Xcode", time: nil, minutes: 120)])
        let stats = ActivityFusionEngine.dayStats(
            dateKey: "2026-09-04",
            entry: item,
            liveSessions: [session(app: "Xcode", minutes: 30)]
        )

        precondition(abs((stats.appUsage.first?.duration ?? 0) - 7200) < 1)
        precondition(abs(stats.appUsage.reduce(0) { $0 + $1.duration } - 7200) < 1)
        precondition(stats.appUsage.first?.source == ActivitySourceKind.fused)
    }

    private static func verifyUnmatchedLiveFillsUnattributedPipelineTimeWithoutExceedingTotal() {
        let item = entry(screenHours: 2, apps: [ScreenAppUsage(app: "Xcode", time: nil, minutes: 80)])
        let stats = ActivityFusionEngine.dayStats(
            dateKey: "2026-09-04",
            entry: item,
            liveSessions: [session(app: "Safari", minutes: 30)]
        )

        precondition(abs(stats.appUsage.reduce(0) { $0 + $1.duration } - 6600) < 1)
    }

    private static func verifyRangeConfidencePenalizesSparseCoverage() {
        let empty = ActivityFusionEngine.dayStats(dateKey: "2026-09-01", entry: nil, liveSessions: [])
        let strong = ActivityFusionEngine.dayStats(
            dateKey: "2026-09-02",
            entry: entry(screenHours: 4),
            liveSessions: [session(app: "Xcode", minutes: 240)]
        )
        let range = ActivityFusionEngine.rangeStats(dayStats: [empty, strong], days: 2)

        precondition(range.confidence > 0)
        precondition(range.confidence < strong.confidence)
        precondition(range.confidenceFactors.count == 5)
    }
}

ActivityFusionVerification.run()
