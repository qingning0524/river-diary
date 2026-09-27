import Foundation

struct MonthlyLetter: Codable, Identifiable, Equatable {
    var id: String { month }
    var month: String
    var title: String
    var body: String
    var evidence: String
    var createdAt: Date
    var updatedAt: Date
    var isFavorite = false

    var markdown: String {
        "# \(title)\n\n\(body)\n\n---\n\n依据：\(evidence)\n\n月份：\(month) · 本机生成，正文可由你编辑\n"
    }

    static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// Capture membership uses the journal's assigned day, including backdated notes.
    static func make(
        for date: Date,
        entries: [DiaryEntry],
        captures: [String: [QuickCapture]],
        sessions: [ActivitySession],
        now: Date = Date(),
        calendar: Calendar = .current,
        aiWeeklySummary: String? = nil
    ) -> MonthlyLetter? {
        guard let interval = calendar.dateInterval(of: .month, for: date), interval.start <= now else { return nil }
        let key = monthKey(for: date, calendar: calendar)
        let cutoff = min(interval.end, now)
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let todayKey = dayFormatter.string(from: now)
        let prefix = key + "-"
        let byDate = entries.filter { $0.date.hasPrefix(prefix) && $0.date <= todayKey }
            .reduce(into: [String: DiaryEntry]()) { $0[$1.date] = $1 }
        let days = byDate.values.sorted { $0.date < $1.date }
        let notes = captures.filter { $0.key.hasPrefix(prefix) && $0.key <= todayKey }.values.flatMap { $0 }
        let clipped = sessions.compactMap { session -> ActivitySession? in
            var result = session
            result.start = max(session.start, interval.start)
            result.end = min(session.end, cutoff)
            return result.end > result.start ? result : nil
        }
        guard !days.isEmpty || !notes.isEmpty || !clipped.isEmpty else { return nil }

        let scores = days.compactMap { entry -> (DiaryEntry, Double)? in
            guard let score = entry.metrics?.overall ?? entry.score,
                  score.isFinite, (0...100).contains(score) else { return nil }
            return (entry, score)
        }
        var paragraphs = ["我注意到，\(key) 留下了 \(days.count) 天日记、\(notes.count) 条快记。这些是生活的一部分，留白的日子也有自己的位置。"]
        if !scores.isEmpty {
            let average = scores.reduce(0) { $0 + $1.1 } / Double(scores.count)
            paragraphs.append("有评分的 \(scores.count) 天，整体状态平均为 \(Int(average.rounded()))。这个数字只描述记录里的感受，不评价这段日子。")
            if scores.count > 1,
               let warm = scores.max(by: { $0.1 < $1.1 }),
               let quiet = scores.min(by: { $0.1 < $1.1 }), warm.1 != quiet.1 {
                paragraphs.append("\(warm.0.shortDate) 的状态相对温暖，\(quiet.0.shortDate) 相对安静。它们都值得被记住，记录本身还不足以解释变化的原因。")
            }
        } else {
            paragraphs.append("这个月还没有可用的状态评分，我们先把字句和活动留下来。")
        }
        let sleep = days.compactMap { $0.health?.resolvedSleepHours }.filter { $0.isFinite && $0 > 0 && $0 <= 24 }
        if !sleep.isEmpty {
            paragraphs.append("\(sleep.count) 天留下了睡眠记录，平均 \(String(format: "%.1f", sleep.reduce(0, +) / Double(sleep.count))) 小时；未记录的日子没有参与计算。")
        }
        if !clipped.isEmpty {
            let minutes = Int(clipped.reduce(0) { $0 + $1.duration } / 60)
            paragraphs.append("Mac 实时足迹覆盖约 \(minutes) 分钟。这只是已采集的片段，没有与项目管道的屏幕总量相加。")
        }
        // 结果链（B2）：本周 AI 周报的结论作为参考段进入信件；
        // 它只是"已保存的 AI 阅读"，不与本地统计混算，也不改变信件的可编辑性。
        if let aiWeeklySummary, !aiWeeklySummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            paragraphs.append("AI 周读的一个观察：\(aiWeeklySummary.trimmingCharacters(in: .whitespacesAndNewlines))。它只基于已核对的记录，供你参考。")
        }
        paragraphs.append("如果你想，可以补上一个希望记住的瞬间；也可以让这封信先静静留在这里。")
        return MonthlyLetter(
            month: key, title: "\(key) · 写给自己的河流信",
            body: paragraphs.joined(separator: "\n\n"),
            evidence: "\(days.count) 天日记 · \(scores.count) 天评分 · \(sleep.count) 天睡眠 · \(notes.count) 条快记 · \(clipped.count) 段实时足迹",
            createdAt: now, updatedAt: now
        )
    }
}
