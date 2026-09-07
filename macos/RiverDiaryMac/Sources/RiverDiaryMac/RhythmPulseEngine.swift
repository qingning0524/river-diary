import Foundation

struct RhythmPulse: Identifiable, Equatable {
    var id: String { dateKey }
    var dateKey: String
    var score: Int
    var mood: Int
    var energy: Int
    var focus: Int
    var output: Int
    var focusMinutes: Int
    var activeMinutes: Int
    var fragmentation: Int
    var confidence: Int
    var topCategory: String
    var headline: String
    var narrative: String
    var tone: Tone

    enum Tone {
        case resting, steady, bright, peak

        var label: String {
            switch self {
            case .resting: "静流"
            case .steady: "平稳"
            case .bright: "明亮"
            case .peak: "高峰"
            }
        }

        var color: String {
            switch self {
            case .resting: "#7C5CFC"
            case .steady: "#4E8CFF"
            case .bright: "#2C8158"
            case .peak: "#E88A2D"
            }
        }
    }
}

@MainActor
enum RhythmPulseEngine {
    static func pulse(
        date: Date,
        entry: DiaryEntry,
        stats: FusedDayStats,
        quickCaptureCount: Int = 0
    ) -> RhythmPulse {
        let mood = clamp(entry.mood, min: 0, max: 100)
        let energy = clamp(entry.energy, min: 0, max: 100)
        let focus = clamp(entry.focus, min: 0, max: 100)
        let output = clamp(entry.output, min: 0, max: 100)

        let focusMinutes = Int(stats.focusTotal / 60)
        let activeMinutes = Int(max(stats.pipelineTotal, stats.liveTotal) / 60)
        let focusShare = activeMinutes > 0 ? Double(focusMinutes) / Double(activeMinutes) : 0
        let calmPenalty = Double(stats.fragmentation) / 100 * 0.14
        let rhythmScore = min(100, focusShare * 100 + Double(min(quickCaptureCount, 6)) * 1.5)

        let journalWeight = entry.metrics == nil ? 0.58 : 0.74
        let activityWeight = 1 - journalWeight
        var score = Double(mood) * 0.34 + Double(energy) * 0.18 + Double(focus) * 0.26 + Double(output) * 0.22
        score = score * journalWeight + rhythmScore * activityWeight * (1 - calmPenalty)

        if activeMinutes > 0 {
            score = score * 0.90 + Double(stats.confidence) * 0.10
        }

        let hasJournal = entry.daily?.isEmpty == false
            || entry.displayOverview.isEmpty == false
            || entry.metrics != nil
        if !hasJournal && activeMinutes == 0 {
            score = 38
        }

        let topCategory = stats.categoryUsage.first?.name ?? (activeMinutes > 0 ? "未分类时间" : "安静")
        let headline = makeHeadline(
            score: score,
            mood: mood,
            focusMinutes: focusMinutes,
            topCategory: topCategory
        )
        let narrative = makeNarrative(
            mood: mood,
            energy: energy,
            focus: focus,
            output: output,
            focusMinutes: focusMinutes,
            activeMinutes: activeMinutes,
            fragmentation: stats.fragmentation,
            topCategory: topCategory,
            confidence: stats.confidence
        )

        return RhythmPulse(
            dateKey: DiaryEntry.dateFormatter.string(from: date),
            score: Int(score.rounded()),
            mood: mood,
            energy: energy,
            focus: focus,
            output: output,
            focusMinutes: focusMinutes,
            activeMinutes: activeMinutes,
            fragmentation: stats.fragmentation,
            confidence: stats.confidence,
            topCategory: topCategory,
            headline: headline,
            narrative: narrative,
            tone: tone(for: score)
        )
    }

    static func pulse(date: Date, store: DiaryStore, activity: ActivityStore) -> RhythmPulse {
        pulse(
            date: date,
            entry: store.entry(for: date),
            stats: activity.dayStats(entries: store.entries, date: date),
            quickCaptureCount: store.captures(for: store.entry(for: date)).count
        )
    }

    static func trend(_ pulses: [RhythmPulse]) -> Int? {
        guard pulses.count >= 2 else { return nil }
        return pulses.last!.score - pulses.first!.score
    }

    private static func tone(for score: Double) -> RhythmPulse.Tone {
        switch score {
        case ..<46: .resting
        case ..<68: .steady
        case ..<84: .bright
        default: .peak
        }
    }

    private static func makeHeadline(score: Double, mood: Int, focusMinutes: Int, topCategory: String) -> String {
        if score < 46 {
            return "\(topCategory)偏多，先给自己一点恢复"
        } else if score < 68 {
            return "节奏还行，\(focusMinutes)分钟专注在托底"
        } else if score < 84 {
            return "今天流得很清楚，值得记下来"
        } else {
            return "高峰日：投入与状态同时在线"
        }
    }

    private static func makeNarrative(
        mood: Int,
        energy: Int,
        focus: Int,
        output: Int,
        focusMinutes: Int,
        activeMinutes: Int,
        fragmentation: Int,
        topCategory: String,
        confidence: Int
    ) -> String {
        let opening = mood >= 68 ? "情绪是打开的" : mood >= 45 ? "情绪还稳定" : "今天偏沉"
        let body = focusMinutes >= 90
            ? "\(focusMinutes) 分钟专注让这条河有了方向"
            : activeMinutes > 0 ? "\(topCategory)占去了大部分时间，长段专注还不多" : "还没有足够的活动信号"
        let recovery = energy < 45 || fragmentation > 65
            ? "身体信号提醒你：接下来先做一段低耗能的事。"
            : "保留这个节奏，挑一件最重要的继续。"
        return "\(opening)；\(body)。\(recovery) 证据可信度 \(confidence)%。"
    }

    private static func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
        Swift.min(maxValue, Swift.max(minValue, value))
    }
}
