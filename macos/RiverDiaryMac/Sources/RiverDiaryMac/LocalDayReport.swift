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

    var sourceLine: String { kind.sourceLine }
}

/// A deterministic report fallback. It only describes observed timeline data;
/// it never infers a place, intention, or emotional cause.
enum LocalDayReportBuilder {
    static func make(
        timeline: ActivityTimeline,
        stats: FusedDayStats,
        fallback: String,
        fallbackKind: LocalDayReportKind
    ) -> LocalDayReport {
        let activities = timeline.items.filter { $0.kind == .activity && $0.duration > 0 }
        guard !activities.isEmpty else {
            return LocalDayReport(
                overview: fallback,
                kind: fallbackKind,
                headline: fallback,
                highlights: []
            )
        }

        let appNames = activities
            .flatMap { $0.apps.map(\.name) }
            .reduce(into: [String: Int]()) { counts, name in counts[name, default: 0] += 1 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(3)
            .map(\.key)

        let headline = "已记录 \(timeline.sessions.count) 段实时片段，共 \(ActivityFormatter.time(timeline.totalDuration))。"
        let categories = stats.categoryUsage.prefix(3).map { "\($0.category) \(ActivityFormatter.time($0.duration))" }
        var highlights: [String] = []
        if !appNames.isEmpty { highlights.append("主要使用：\(appNames.joined(separator: "、"))") }
        if !categories.isEmpty { highlights.append("时间分类：\(categories.joined(separator: " · "))") }

        let buckets = [
            ("凌晨", 0..<5),
            ("上午", 5..<12),
            ("下午", 12..<18),
            ("晚上", 18..<24)
        ]
        var timeBuckets: [String] = []
        for (label, hours) in buckets {
            let items = activities.filter { hours.contains(Calendar.current.component(.hour, from: $0.start)) }
            guard !items.isEmpty else { continue }
            let duration = items.reduce(0) { $0 + $1.duration }
            timeBuckets.append("\(label) \(ActivityFormatter.time(duration))")
        }
        if !timeBuckets.isEmpty { highlights.append("分时记录：" + timeBuckets.joined(separator: " · ")) }

        let fullHighlights = highlights
        let displayHighlights = Array(fullHighlights.prefix(3))
        let overview = ([headline] + fullHighlights.map { "\($0)。" }).joined(separator: " ")

        return LocalDayReport(
            overview: overview,
            kind: .observedFacts,
            headline: headline,
            highlights: displayHighlights
        )
    }
}
