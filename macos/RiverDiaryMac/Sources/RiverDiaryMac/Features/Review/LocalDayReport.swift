import Foundation

enum LocalDayReportKind: Equatable {
    case observedFacts
    case diaryArchive
    case sourceSnapshot
    case noEvidence

    var title: String {
        switch self {
        case .observedFacts: "事实摘要"
        case .diaryArchive: "日记档案"
        case .sourceSnapshot: "数据源摘要"
        case .noEvidence: "证据不足"
        }
    }

    var sourceLine: String {
        switch self {
        case .observedFacts: "本地事实整理 · 基于 macOS 实时片段与快记 · 未使用 AI"
        case .diaryArchive: "日记档案内容 · 来源文本，未由本页实时片段验证"
        case .sourceSnapshot: "数据源摘要 · 来自导入快照，未由本页实时片段验证"
        case .noEvidence: "当前没有足够的日记内容或实时片段；未知不代表未发生"
        }
    }

    static func fallbackKind(hasDiaryContent: Bool, hasSourceSnapshot: Bool) -> LocalDayReportKind {
        if hasDiaryContent { return .diaryArchive }
        if hasSourceSnapshot { return .sourceSnapshot }
        return .noEvidence
    }

    static func resolve(hasObservedActivities: Bool, fallbackKind: LocalDayReportKind) -> LocalDayReportKind {
        hasObservedActivities ? .observedFacts : fallbackKind
    }
}

struct LocalDayReport {
    let overview: String
    let kind: LocalDayReportKind
    let headline: String
    let highlights: [String]
    let insights: [TimelineAnalysisInsight]
    let sourceLine: String
}

/// A deterministic report fallback. It describes observed time and user notes;
/// it never infers a place, intention, or emotional cause.
enum LocalDayReportBuilder {
    static func make(
        timeline: ActivityTimeline,
        stats: FusedDayStats,
        fallback: String,
        fallbackKind: LocalDayReportKind,
        calendar: Calendar = .current
    ) -> LocalDayReport {
        let snapshot = TimelineAnalysisSnapshot.make(timeline: timeline, stats: stats, calendar: calendar)
        return make(snapshot: snapshot, fallback: fallback, fallbackKind: fallbackKind)
    }

    static func make(
        snapshot: TimelineAnalysisSnapshot,
        fallback: String,
        fallbackKind: LocalDayReportKind
    ) -> LocalDayReport {
        let timeline = snapshot.timeline
        let activities = timeline.items.filter { $0.kind == .activity && $0.duration > 0 }
        let captures = timeline.items.filter { $0.kind == .capture }

        guard !activities.isEmpty else {
            guard !captures.isEmpty else {
                return LocalDayReport(
                    overview: fallback,
                    kind: fallbackKind,
                    headline: fallback,
                    highlights: [],
                    insights: snapshot.insights,
                    sourceLine: fallbackKind.sourceLine
                )
            }

            let headline = "这一天留下了 \(captures.count) 条快记。"
            let highlights = snapshot.insights.prefix(3).map(\.title)
            return LocalDayReport(
                overview: ([headline] + highlights).joined(separator: " "),
                kind: .observedFacts,
                headline: headline,
                highlights: highlights,
                insights: snapshot.insights,
                sourceLine: observedSourceLine(liveCount: 0, captureCount: captures.count)
            )
        }

        let headline = "已记录 \(timeline.sessions.count) 段实时片段，共 \(ActivityFormatter.time(timeline.totalDuration))。"
        var highlights: [String] = []
        let apps = snapshot.appUsage.prefix(3).map { "\($0.name) \(ActivityFormatter.time($0.duration))" }
        if !apps.isEmpty { highlights.append("主要使用：\(apps.joined(separator: "、"))") }

        let categories = snapshot.categoryUsage.prefix(3).map { "\($0.name) \(ActivityFormatter.time($0.duration))" }
        if !categories.isEmpty { highlights.append("时间分类：\(categories.joined(separator: " · "))") }

        let buckets = snapshot.timeBuckets.map { "\($0.title) \(ActivityFormatter.time($0.duration))" }
        if !buckets.isEmpty { highlights.append("分时记录：" + buckets.joined(separator: " · ")) }

        if !snapshot.sourceConflicts.isEmpty {
            highlights.append(contentsOf: snapshot.sourceConflicts)
        }

        return LocalDayReport(
            overview: ([headline] + highlights.map { "\($0)。" }).joined(separator: " "),
            kind: .observedFacts,
            headline: headline,
            highlights: Array(highlights.prefix(3)),
            insights: snapshot.insights,
            sourceLine: observedSourceLine(liveCount: timeline.sessions.count, captureCount: captures.count)
        )
    }

    private static func observedSourceLine(liveCount: Int, captureCount: Int) -> String {
        var sources: [String] = []
        if liveCount > 0 { sources.append("macOS 实时片段") }
        if captureCount > 0 { sources.append("快记") }
        return "本地事实整理 · 基于 \(sources.joined(separator: "与")) · 未使用 AI"
    }
}
