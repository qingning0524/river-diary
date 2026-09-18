import Foundation

struct LocalReview {
    struct Day: Identifiable {
        var id: String
        var duration: TimeInterval
        var mood: Double?
    }
    var start: Date
    var end: Date
    var writingDays: Int
    var moodSamples: Int
    var averageMood: Double?
    var captureCount: Int
    var duration: TimeInterval
    var categories: [TimelineAppUsage]
    var days: [Day]

    static func make(start: Date, end: Date, entries: [DiaryEntry], sessions: [ActivitySession], captures: [String: [QuickCapture]], calendar: Calendar = .current) -> LocalReview {
        let lower = calendar.startOfDay(for: start)
        let upper = calendar.startOfDay(for: end)
        let startKey = ActivitySession.dayKey(for: lower)
        let endKey = ActivitySession.dayKey(for: upper)
        let byDate = entries.filter { $0.date >= startKey && $0.date <= endKey }
            .reduce(into: [String: DiaryEntry]()) { $0[$1.date] = $1 }
        let selected = byDate.values
        let moods = selected.compactMap { $0.metrics?.mood ?? $0.score }.filter { $0.isFinite && (0...100).contains($0) }
        var days: [Day] = []
        var categories: [String: Double] = [:]
        var cursor = lower
        while cursor <= upper {
            let timeline = ActivityTimelineEngine.build(for: cursor, sessions: sessions, calendar: calendar)
            let key = ActivitySession.dayKey(for: cursor)
            let mood = byDate[key]?.metrics?.mood ?? byDate[key]?.score
            days.append(Day(id: key, duration: timeline.totalDuration, mood: mood.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }))
            for usage in timeline.categoryUsage { categories[usage.name, default: 0] += usage.duration }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return LocalReview(start: lower, end: upper,
                           writingDays: selected.filter { !$0.displayOverview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count,
                           moodSamples: moods.count, averageMood: moods.isEmpty ? nil : moods.reduce(0, +) / Double(moods.count),
                           captureCount: captures.filter { $0.key >= startKey && $0.key <= endKey }.values.reduce(0) { $0 + $1.count },
                           duration: days.reduce(0) { $0 + $1.duration },
                           categories: categories.map { TimelineAppUsage(name: $0.key, duration: $0.value) }.sorted { $0.duration > $1.duration }, days: days)
    }

    var markdown: String {
        var lines = ["# 河流回顾 · \(ActivitySession.dayKey(for: start)) – \(ActivitySession.dayKey(for: end))", "", "- 写下日记：\(writingDays) 天", "- 快记：\(captureCount) 条", "- 实时足迹：\(duration > 0 ? ActivityFormatter.time(duration) : "0 分钟")"]
        lines.append(averageMood.map { "- 平均心情：\(Int($0.rounded())) / 100（\(moodSamples) 天评分）" } ?? "- 心情：暂无评分")
        lines += ["", "## 时间分布", ""]
        for category in categories { lines.append("- \(category.name)：\(ActivityFormatter.time(category.duration))") }
        lines += ["", "仅统计已有记录；缺失评分不按零计算，未记录时段不代表休息。"]
        return lines.joined(separator: "\n")
    }
}
